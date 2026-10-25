import AppKit
import VibeCore

/// Watches the main thread from another one. When it's stuck for more than 2 s, it writes
/// `~/.vibeswitcher/debug/hang-<time>.txt` (a `sample` of the app: every thread's stack while stuck) and
/// `hang-<time>.log` (the app's state and its latest breadcrumbs), and notes how long the stall lasted. The .log starts
/// with a machine-readable line (`AppHealth.hangHeader`): when it got stuck, and once it answered again, how long it was.
final class HangWatchdog: @unchecked Sendable {
    static let shared = HangWatchdog()

    private let lock = NSLock()
    private var detector = StallDetector(threshold: 2)
    /// The app's state as last seen on the main thread (it can't be asked while it's stuck).
    private var state = ""
    var describeState: () -> String = { "" }
    private var started = false
    /// The last hang's report, and its .log as written: its header gets the stall's length once it's over.
    private var lastReport: (name: String, since: Date, text: String)?

    static var folder: URL { VibePaths.root.appendingPathComponent("debug", isDirectory: true) }

    func start() {
        guard !started else { return }
        started = true
        let beat = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.detector.beat()
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
            while let self {
                usleep(250_000)
                self.lock.lock()
                let event = self.detector.check()
                let state = self.state
                self.lock.unlock()
                switch event {
                case .stalled(let since)?: self.record(since: since, state: state)
                case .recovered(let length)?:
                    Breadcrumbs.shared.note("main thread answered again after \(String(format: "%.1f", length)) s")
                    if let last = self.lastReport {
                        self.writeLog(last.name, header: AppHealth.hangHeader(since: last.since, duration: length), text: last.text)
                        self.lastReport = nil
                    }
                    Breadcrumbs.shared.flush()
                case nil: break
                }
            }
        }
    }

    private func record(since: Date, state: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "hang-\(formatter.string(from: since))"
        let folder = Self.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        Breadcrumbs.shared.note("main thread stuck since \(since); sampling into \(name).txt")
        let report = Redaction.secrets(in: "Main thread stuck since \(since)\n\nState:\n\(state)\n\nLatest events:\n"
            + Breadcrumbs.shared.lines.joined(separator: "\n") + "\n")
        lastReport = (name, since, report)
        writeLog(name, header: AppHealth.hangHeader(since: since, duration: nil), text: report)
        Breadcrumbs.shared.flush()
        let sample = Process()
        sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sample.arguments = ["\(getpid())", "3", "-file", folder.appendingPathComponent(name + ".txt").path]
        sample.standardOutput = FileHandle.nullDevice
        sample.standardError = FileHandle.nullDevice
        try? sample.run()
        sample.waitUntilExit()
        prune(folder)
    }

    private func writeLog(_ name: String, header: String, text: String) {
        try? (header + "\n" + text).write(to: Self.folder.appendingPathComponent(name + ".log"), atomically: true, encoding: .utf8)
    }

    /// The ten newest hangs are kept.
    private func prune(_ folder: URL) {
        let fm = FileManager.default
        let hangs = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("hang-") }.sorted()
        let names = Set(hangs.map { ($0 as NSString).deletingPathExtension })
        for old in names.sorted().dropLast(10) {
            for ext in ["txt", "log"] { try? fm.removeItem(at: folder.appendingPathComponent("\(old).\(ext)")) }
        }
    }
}
