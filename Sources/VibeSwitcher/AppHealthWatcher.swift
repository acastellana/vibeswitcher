import Foundation
import VibeCore

/// Watches VibeSwitcher's own logs for news (see `AppHealth`), with file events, not polling: the debug folder (a new
/// hang report; app.log replaced when it rotates), DiagnosticReports (a new crash report of one of its programs) and
/// app.log itself (lines added). It only reads them: it never moves, deletes or rewrites one. What's news goes to `send`
/// as a digest, on the main thread, which hands it to the leads whose project has watch_app_logs on; one no lead took is
/// tried again at the next look. What it took in and told is kept in `stateFile`, so a relaunch neither tells a report
/// again nor misses one written while the app was down (its own crash, mostly).
final class AppHealthWatcher: @unchecked Sendable {
    private let folders: AppHealth.Folders
    private let appLog: URL
    private let stateFile: URL
    private let now: () -> Date
    private let memory: () -> AppHealth.Memory?
    private let send: (String) -> Bool
    /// Whether it sets a timer for its next look (tests look themselves, with a clock of their own).
    private let timed: Bool
    private let queue = DispatchQueue(label: "vibeswitcher.app-health", qos: .utility)
    private var watch = AppHealth.Watch()
    private var folderSources: [DispatchSourceFileSystemObject] = []
    private var log: (handle: FileHandle, source: DispatchSourceFileSystemObject, inode: UInt64)?
    private var logOffset: UInt64 = 0
    private var partial = Data()
    private var timer: DispatchSourceTimer?
    private var sending = false
    /// Called on its queue after it took in something new (tests wait on it).
    var tookIn: (() -> Void)?

    init(folders: AppHealth.Folders = .app, appLog: URL = Breadcrumbs.appLog,
         stateFile: URL = VibePaths.root.appendingPathComponent("app-health.json"),
         now: @escaping () -> Date = Date.init, memory: @escaping () -> AppHealth.Memory? = AppHealthWatcher.memoryReader(),
         timed: Bool = true, send: @escaping (String) -> Bool) {
        self.folders = folders
        self.appLog = appLog
        self.stateFile = stateFile
        self.now = now
        self.memory = memory
        self.timed = timed
        self.send = send
    }

    deinit { stopWatching() }

    func start() {
        queue.async { self.begin() }
    }

    /// Stops watching (what it took in is saved as it goes).
    func stop() {
        queue.sync { stopWatching() }
    }

    /// Looks now for what's due (the timer does at `AppHealth.Watch.nextLook`).
    func look() {
        queue.sync { lookNow() }
    }

    /// What it has taken in and told, and whether digests are on their way to `send` (tests).
    var state: AppHealth.Watch { queue.sync { watch } }
    var isSending: Bool { queue.sync { sending } }

    private func begin() {
        if let data = try? Data(contentsOf: stateFile), let saved = try? JSONDecoder().decode(AppHealth.Watch.self, from: data) {
            watch = saved
        } else {
            // The first run: the reports there already are history.
            watch.baseline(hangs: folders.hangNames(), crashes: folders.crashFiles())
            save()
        }
        watchFolders()
        openLog(fromEnd: true)
        scan()
        lookNow()
    }

    private func stopWatching() {
        folderSources.forEach { $0.cancel() }
        folderSources = []
        log?.source.cancel()
        log = nil
        timer?.cancel()
        timer = nil
    }

    /// A source on each folder: its entries changed (a file written, renamed into it, removed).
    private func watchFolders() {
        guard folderSources.isEmpty else { return }
        for folder in [folders.debug, folders.reports] {
            let fd = open(folder.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
            source.setEventHandler { [weak self] in
                self?.scan()
                self?.checkLog()
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            folderSources.append(source)
        }
    }

    /// New reports in the folders go into the digest under way.
    private func scan() {
        guard watch.saw(hangs: folders.hangNames(), crashes: folders.crashFiles(), now: now()) else { return }
        save()
        schedule()
        tookIn?()
    }

    // MARK: app.log

    private func openLog(fromEnd: Bool) {
        guard log == nil, let handle = try? FileHandle(forReadingFrom: appLog) else { return }
        let fd = handle.fileDescriptor
        var info = stat()
        guard fstat(fd, &info) == 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.extend, .write, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            self.readLog()
            if !source.data.intersection([.rename, .delete]).isEmpty { self.reopenLog() }
        }
        source.resume()
        log = (handle, source, UInt64(info.st_ino))
        logOffset = fromEnd ? UInt64(info.st_size) : 0
        partial = Data()
        if !fromEnd { readLog() }
    }

    /// app.log rotated (moved to app.log.1, a new one begun): the rest of the old one, then the new one from its start.
    private func reopenLog() {
        readLog()
        log?.source.cancel()
        try? log?.handle.close()
        log = nil
        openLog(fromEnd: false)
    }

    /// The folder changed: app.log may be a new file (or there at last).
    private func checkLog() {
        guard let current = log else { return openLog(fromEnd: false) }
        var info = stat()
        if stat(appLog.path, &info) == 0, UInt64(info.st_ino) != current.inode { reopenLog() }
    }

    /// The lines added since the last read.
    private func readLog() {
        guard let handle = log?.handle else { return }
        var info = stat()
        if fstat(handle.fileDescriptor, &info) == 0, UInt64(info.st_size) < logOffset { logOffset = 0 }
        guard (try? handle.seek(toOffset: logOffset)) != nil, let data = try? handle.read(upToCount: 4 << 20), !data.isEmpty else { return }
        logOffset += UInt64(data.count)
        partial += data
        guard let end = partial.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let lines = String(decoding: partial[partial.startIndex..<end], as: UTF8.self).components(separatedBy: "\n")
        partial = Data(partial[partial.index(after: end)...])
        let before = watch
        watch.saw(lines: lines, now: now())
        guard watch != before else { return }
        save()
        schedule()
        tookIn?()
    }

    // MARK: Looking and telling

    private func lookNow() {
        if folderSources.count < 2 {
            // A folder that wasn't there yet (the debug folder before the app's first log line).
            stopFolders()
            watchFolders()
            scan()
        }
        if log == nil { openLog(fromEnd: false) }
        watch.look(now: now(), folders: folders, memory: memory())
        save()
        deliver()
        schedule()
    }

    private func stopFolders() {
        folderSources.forEach { $0.cancel() }
        folderSources = []
    }

    /// The pending digests, to `send` on the main thread; those it took leave `pending`.
    private func deliver() {
        guard !sending, !watch.pending.isEmpty else { return }
        sending = true
        let out = watch.pending
        DispatchQueue.main.async { [self] in
            let taken = out.filter { send($0) }
            queue.async { [self] in
                for text in taken { if let index = watch.pending.firstIndex(of: text) { watch.pending.remove(at: index) } }
                sending = false
                if !taken.isEmpty { Breadcrumbs.shared.note("app health: told the lead \(taken.count == 1 ? "a digest" : "\(taken.count) digests")") }
                save()
                schedule()
            }
        }
    }

    private func schedule() {
        guard timed else { return }
        if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.lookNow() }
            timer.resume()
            self.timer = timer
        }
        // Folders not watched yet are looked for again a minute on.
        var next = watch.nextLook(now: now())
        if folderSources.count < 2 { next = min(next, now().addingTimeInterval(60)) }
        timer?.schedule(wallDeadline: .now() + max(1, next.timeIntervalSince(now())), leeway: .seconds(30))
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(watch) else { return }
        try? VibePaths.ensurePrivate(stateFile.deletingLastPathComponent())
        try? VibePaths.writePrivate(data, to: stateFile)
    }

    // MARK: Memory

    /// The app's own footprint now and its peak (`task_vm_info` of this process), against the footprint it settled at
    /// (`AppHealth.Settling`: read once a minute, off the main thread, in the hour after this reader was made at launch).
    static func memoryReader(footprint: @escaping @Sendable () -> (now: Double, peak: Double)? = { ownFootprint() }) -> () -> AppHealth.Memory? {
        let settling = Settling(launched: Date(), footprint: footprint)
        settling.start()
        return {
            guard let reading = footprint() else { return nil }
            return AppHealth.Memory(footprint: reading.now, peak: reading.peak, settled: settling.settled, launched: settling.launched)
        }
    }

    /// `AppHealth.Settling`'s readings, once a minute on a queue of its own until it's done.
    final class Settling: @unchecked Sendable {
        let launched: Date
        private let footprint: @Sendable () -> (now: Double, peak: Double)?
        private let queue = DispatchQueue(label: "vibeswitcher.memory-settling", qos: .utility)
        private var settling: AppHealth.Settling
        private var timer: DispatchSourceTimer?

        init(launched: Date, footprint: @escaping @Sendable () -> (now: Double, peak: Double)?) {
            self.launched = launched
            self.footprint = footprint
            settling = AppHealth.Settling(launched: launched)
        }

        var settled: AppHealth.Memory.Settled? { queue.sync { settling.settled } }

        func start() {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(wallDeadline: .now() + AppHealth.Settling.from, repeating: 60, leeway: .seconds(10))
            timer.setEventHandler { [weak self] in self?.read(now: Date()) }
            timer.resume()
            self.timer = timer
        }

        /// A reading (on its queue; tests call it with their own clock); the timer ends once no more are wanted.
        func read(now: Date) {
            if let reading = footprint() { settling.read(reading.now, now: now) }
            if !settling.wants(now: now) {
                timer?.cancel()
                timer = nil
            }
        }

        deinit { timer?.cancel() }
    }

    /// This process's footprint and its peak, in MB.
    static func ownFootprint() -> (now: Double, peak: Double)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        } == KERN_SUCCESS
        guard ok else { return nil }
        return (Double(info.phys_footprint) / 1_048_576, Double(max(info.ledger_phys_footprint_peak, Int64(info.phys_footprint))) / 1_048_576)
    }
}
