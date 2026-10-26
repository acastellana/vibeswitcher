import AppKit
import VibeCore

/// Watches the main thread from another one. When it's stuck for more than 2 s, it writes
/// `~/.vibeswitcher/debug/hang-<time>.txt` (a `sample` of the app: every thread's stack) and `hang-<time>.log` (the
/// app's state, the main thread's stacks caught while it was stuck, and its latest breadcrumbs), and notes how long
/// the stall lasted. The .log starts with a machine-readable line (`AppHealth.hangHeader`): when it got stuck, once it
/// answered again how long it was, and how much of the sample was taken while still stuck.
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
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "hang-\(formatter.string(from: since))"
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        Breadcrumbs.shared.note("main thread stuck since \(since); \(caught.count) stacks caught so far, \(samples ? "sampling into \(name).txt" : "no sample")")
        lock.lock()
        report = Report(name: name, since: since, text: "Main thread stuck since \(since)\n\nState:\n\(state)\n")
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
            guard let self else { return }
            let start = (try? String(contentsOf: file, encoding: .utf8)).flatMap(AppHealth.sampleStart)
            self.lock.lock()
            if self.report?.name == name {
                self.report?.sampleStart = start
                self.report?.sampleDone = true
            }
            self.lock.unlock()
            self.prune()
        }
        do { try sample.run() } catch { prune() }
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
                    + (share == 0 ? " (all of it after: the stacks below are the stall's)" : "") + "\n"
            } else {
                overlap = "Sample (.txt): no start time read from it\n"
            }
        }
        let stacks = report.stacks.isEmpty ? "No stacks caught while stuck.\n" : report.stacks + "\n"
        let text = Redaction.secrets(in: report.text + "\n" + overlap + stacks + "\nLatest events:\n"
            + Breadcrumbs.shared.lines.joined(separator: "\n") + "\n")
        let header = AppHealth.hangHeader(since: report.since, duration: duration, sampleInside: inside)
        try? (header + "\n" + text).write(to: folder.appendingPathComponent(report.name + ".log"), atomically: true, encoding: .utf8)
        onWrite?(report.name)
    }

    /// The ten newest hangs are kept.
    private func prune() {
        let fm = FileManager.default
        let hangs = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("hang-") }.sorted()
        let names = Set(hangs.map { ($0 as NSString).deletingPathExtension })
        for old in names.sorted().dropLast(10) {
            for ext in ["txt", "log"] { try? fm.removeItem(at: folder.appendingPathComponent("\(old).\(ext)")) }
        }
    }
}
