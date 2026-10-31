import AppKit
import VibeCore

/// Watches the main thread from another one. When it's stuck for more than 2 s, it writes
/// `~/.vibeswitcher/debug/hang-<time>.txt` (a `sample` of the app: every thread's stack) and `hang-<time>.log` (the
/// app's state, the main thread's stacks caught while it was stuck, and its latest breadcrumbs), and notes how long
/// the stall lasted. The .log starts with a machine-readable line (`AppHealth.hangHeader`): when it got stuck, once it
/// answered again how long it was, how much of the sample was taken while still stuck, the 1-minute load when it got
/// stuck, and what the sample's main thread says it was (`AppHealth.Verdict`: starvation, real work or a wait).
/// The stacks are caught from the moment a beat is `early` late, every `catchEvery`, and kept only if it turns into a
/// stall: 2026-10-26, `sample` took 3 to 6 s to begin, and both reports that day sampled only the idle main thread
/// after its stall had ended.
final class HangWatchdog: @unchecked Sendable {
    static let shared = HangWatchdog()

    private let lock = NSLock()
    private var detector: StallDetector
    /// The app's state as last seen on the main thread (it can't be asked while it's stuck).
    private var state = ""
    var describeState: () -> String = { "" }
    private var started = false
    let folder: URL
    /// Whether a hang also gets a `sample` (.txt); tests leave it off.
    private let samples: Bool
    private let catchEvery: TimeInterval
    /// At most this many stacks a stall (then the first ones are what's kept).
    static let maxCaught = 300
    private var beats = 0
    private var lastBeat: Date?
    private var longest: (gap: TimeInterval, at: Date)?
    /// The longest time between two beats (0.25 s apart when the main thread is free) since the last reset, and when
    /// it ended: for the sandbox's measurements.
    func longestGap(reset: Bool = false) -> (gap: TimeInterval, at: Date)? {
        lock.lock()
        defer {
            if reset { longest = nil }
            lock.unlock()
        }
        return longest
    }
    /// How many times the main thread beat (for tests: it's being watched once it has).
    var beatCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return beats
    }
    /// Called on the watchdog's thread with a report's name each time its .log is written.
    var onWrite: ((String) -> Void)?

    /// The main thread's stack reader (made on the main thread by `start`).
    private var stack: ThreadStack?
    /// Stacks caught since the main thread was late, with how far into it each was taken: the stall's if it becomes
    /// one, dropped if it answers first.
    private var caught: [(at: TimeInterval, frames: [AppHealth.StackFrame])] = []
    /// The stall under way or last reported (the watchdog thread's, and the sample's end, under `lock`).
    private var report: Report?

    private struct Report {
        var name: String
        var since: Date
        var text: String
        var end: Date?
        var sampleStart: Date?
        /// How the sample's main-thread samples spread over its PCs.
        var spread: AppHealth.Spread?
        /// The 1-minute load average when it got stuck (one `getloadavg`), and the cores.
        var load: Double?
        var cpus = ProcessInfo.processInfo.activeProcessorCount
        var sampleDone = false
        var sampleWritten = false
        /// The caught stacks' call graph, as last written.
        var stacks = ""
    }

    init(folder: URL = VibePaths.root.appendingPathComponent("debug", isDirectory: true), threshold: TimeInterval = 2,
         early: TimeInterval = 0.5, catchEvery: TimeInterval = 0.1, samples: Bool = true) {
        self.folder = folder
        self.samples = samples
        self.catchEvery = catchEvery
        detector = StallDetector(threshold: threshold, early: early)
    }

    func start() {
        guard !started else { return }
        started = true
        stack = ThreadStack()
        let beat = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let now = Date()
            self.detector.beat(at: now)
            self.beats += 1
            if let last = self.lastBeat, now.timeIntervalSince(last) > (self.longest?.gap ?? 0) { self.longest = (now.timeIntervalSince(last), now) }
            self.lastBeat = now
            self.lock.unlock()
        }
        RunLoop.main.add(beat, forMode: .common)
        // The state (and the log file) once a second, while the main thread runs.
        let snapshot = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let text = self.describeState()
            self.lock.lock()
            self.state = text
            self.lock.unlock()
            Breadcrumbs.shared.flush()
        }
        RunLoop.main.add(snapshot, forMode: .common)
        Thread.detachNewThread { [weak self] in
            // Four looks a second while it answers (the wakes cost power); every `catchEvery` while it's late.
            var late = false
            while let self {
                usleep(useconds_t((late ? self.catchEvery : max(self.catchEvery, 0.25)) * 1_000_000))
                late = self.tick()
            }
        }
    }

    /// One look from the watchdog's thread (the caught stacks and every .log write are its own); whether the main
    /// thread is late.
    private func tick() -> Bool {
        lock.lock()
        let event = detector.check()
        let late = detector.lateSince
        let state = self.state
        let stuck = report.map { $0.end == nil } ?? false
        let sampled = report?.sampleDone == true && report?.sampleWritten == false
        lock.unlock()
        if let late, caught.count < Self.maxCaught, let stack {
            let frames = stack.frames()
            if !frames.isEmpty { caught.append((Date().timeIntervalSince(late), frames)) }
        } else if late == nil, !stuck {
            // Late, but it answered before it was a stall: nothing to keep.
            caught = []
        }
        switch event {
        case .stalled(let since)?: record(since: since, state: state)
        case .recovered(let length)?:
            Breadcrumbs.shared.note("main thread answered again after \(String(format: "%.1f", length)) s")
            lock.lock()
            if let since = report?.since { report?.end = since.addingTimeInterval(length) }
            lock.unlock()
            writeReport()
            caught = []
            Breadcrumbs.shared.flush()
        case nil:
            if sampled { writeReport(withStacks: false) }
        }
        return late != nil
    }

    private func record(since: Date, state: String) {
        let formatter = DateFormatter()
        // As `AppHealth.nameDate` reads it back (another calendar's year would make every report look old).
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "hang-\(formatter.string(from: since))"
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        Breadcrumbs.shared.note("main thread stuck since \(since); \(caught.count) stacks caught so far, \(samples ? "sampling into \(name).txt" : "no sample")")
        var averages = [0.0]
        let load = getloadavg(&averages, 1) == 1 ? averages[0] : nil
        var report = Report(name: name, since: since, text: "")
        report.load = load
        report.text = "Main thread stuck since \(since)" + (load.map { "; " + AppHealth.describeLoad($0, cpus: report.cpus) } ?? "") + "\n\nState:\n\(state)\n"
        lock.lock()
        self.report = report
        lock.unlock()
        writeReport()
        Breadcrumbs.shared.flush()
        guard samples else { return }
        let file = folder.appendingPathComponent(name + ".txt")
        let sample = Process()
        sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sample.arguments = ["\(getpid())", "\(Int(AppHealth.sampleSeconds))", "-file", file.path]
        sample.standardOutput = FileHandle.nullDevice
        sample.standardError = FileHandle.nullDevice
        // Not waited for: the stacks go on being caught while it runs. Its end is written by the next tick.
        sample.terminationHandler = { [weak self] _ in
            Self.read(sample: file) { start, spread in
                guard let self else { return }
                self.lock.lock()
                if self.report?.name == name {
                    self.report?.sampleStart = start
                    self.report?.spread = spread
                    self.report?.sampleDone = true
                }
                self.lock.unlock()
                self.prune()
            }
        }
        do { try sample.run() } catch { prune() }
    }

    /// Where a finished sample is read. 2026-10-31: read on the termination handler's thread, a user-interactive one,
    /// it took the CPU from an app the Mac was already starving (hang-20261031-003909).
    static let reading = DispatchQueue(label: "vibeswitcher.hang-sample", qos: .utility)

    /// A finished sample's start and main-thread spread, read on `reading`, then `done` there.
    static func read(sample file: URL, done: @escaping @Sendable (Date?, AppHealth.Spread?) -> Void) {
        reading.async {
            let text = try? String(contentsOf: file, encoding: .utf8)
            done(text.flatMap(AppHealth.sampleStart), text.flatMap { AppHealth.spread(sample: $0) })
        }
    }

    /// The report's .log as known now: the stacks caught so far; once the stall's over, its length; once the sample's
    /// done, how much of it was inside the stall. `withStacks`: the caught stacks are this stall's (not once it's over:
    /// the next late beat's would be).
    private func writeReport(withStacks: Bool = true) {
        lock.lock()
        if withStacks, !caught.isEmpty { report?.stacks = AppHealth.caughtGraph(caught) }
        if report?.sampleDone == true { report?.sampleWritten = true }
        let report = self.report
        lock.unlock()
        guard let report else { return }
        let duration = report.end.map { $0.timeIntervalSince(report.since) }
        var overlap = ""
        var inside: Double?
        if report.sampleDone {
            if let start = report.sampleStart {
                let share = AppHealth.sampleInside(start: start, end: report.end)
                inside = share
                overlap = String(format: "Sample (.txt): began %.1f s into the stall, %.0f s long; %.0f%% of it inside the stall", start.timeIntervalSince(report.since),
                                 AppHealth.sampleSeconds, share * 100)
                    + (share == 0 ? " (all of it after: the stacks below are the stall's)" : "")
            } else {
                overlap = "Sample (.txt): no start time read from it"
            }
            if let spread = report.spread { overlap += "; " + AppHealth.describe(spread, verdict: AppHealth.verdict(spread, sampleInside: inside)) }
            overlap += "\n"
        }
        let stacks = report.stacks.isEmpty ? "No stacks caught while stuck.\n" : report.stacks + "\n"
        let text = Redaction.secrets(in: report.text + "\n" + overlap + stacks + "\nLatest events:\n"
            + Breadcrumbs.shared.lines.joined(separator: "\n") + "\n")
        let header = AppHealth.hangHeader(since: report.since, duration: duration, sampleInside: inside, load: report.load, cpus: report.cpus,
                                          spread: report.spread, verdict: AppHealth.verdict(report.spread, sampleInside: inside))
        try? (header + "\n" + text).write(to: folder.appendingPathComponent(report.name + ".log"), atomically: true, encoding: .utf8)
        onWrite?(report.name)
    }

    /// Hangs are kept a week, and at most `keepBytes` of them (the oldest go first; the newest is always kept): a fix
    /// task reads the reports it names. 2026-10-28, two workers and a verifier couldn't read theirs (hang-20261027-19xx
    /// to 21xx): the ten newest were all that was kept, and the evening's 100+ freezes had pushed them out within hours.
    /// A hang is about 0.8 MB (a .log of 20-300 KB, a sample of 0.2-2 MB): 500 MB holds six such evenings.
    static let keepFor: TimeInterval = 7 * 86_400
    static let keepBytes = 500 << 20

    private func prune() { Self.prune(folder, now: Date()) }

    /// A hang's age is from its name (when it began; its files' last change if the name doesn't say), its size its
    /// .log's and .txt's.
    static func prune(_ folder: URL, now: Date, keepFor: TimeInterval = keepFor, keepBytes: Int = keepBytes) {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("hang-") && ($0.hasSuffix(".txt") || $0.hasSuffix(".log")) }
        var hangs: [String: (began: Date, bytes: Int)] = [:]
        for file in files {
            let name = (file as NSString).deletingPathExtension
            let attributes = try? fm.attributesOfItem(atPath: folder.appendingPathComponent(file).path)
            let began = AppHealth.nameDate(name) ?? (attributes?[.modificationDate] as? Date) ?? now
            let bytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            let known = hangs[name]
            hangs[name] = (max(known?.began ?? began, began), (known?.bytes ?? 0) + bytes)
        }
        // Newest first: once the total is past `keepBytes`, every older one goes too.
        let newest = hangs.sorted { ($0.value.began, $0.key) > ($1.value.began, $1.key) }
        var total = 0
        for (index, (name, hang)) in newest.enumerated() {
            total += hang.bytes
            guard index > 0, now.timeIntervalSince(hang.began) >= keepFor || total > keepBytes else { continue }
            for ext in ["txt", "log"] { try? fm.removeItem(at: folder.appendingPathComponent("\(name).\(ext)")) }
        }
    }
}
