import AppKit
import VibeCore

/// Watches the main thread from another one. When it's stuck for more than 2 s, it writes
/// `~/.vibeswitcher/debug/hang-<time>.txt` (a `sample` of the app: every thread's stack while stuck) and
/// `hang-<time>.log` (the app's state and its latest breadcrumbs), and notes how long the stall lasted.
final class HangWatchdog: @unchecked Sendable {
    static let shared = HangWatchdog()

    private let lock = NSLock()
    private var detector = StallDetector(threshold: 2)
    /// The app's state as last seen on the main thread (it can't be asked while it's stuck).
    private var state = ""
    var describeState: () -> String = { "" }
    private var started = false

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
        let report = "Main thread stuck since \(since)\n\nState:\n\(state)\n\nLatest events:\n"
            + Breadcrumbs.shared.lines.joined(separator: "\n") + "\n"
        try? Redaction.secrets(in: report).write(to: folder.appendingPathComponent(name + ".log"), atomically: true, encoding: .utf8)
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
