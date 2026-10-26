import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// The watchdog catches the main thread's stack while it's stuck, not after: 2026-10-26, two 3 s freezes were
/// reported with a sample begun after the main thread had answered (1799 of 1812 samples idle in the run loop).
struct HangWatchdogTests {
    let temp = Scratch()

    /// Stands for whatever blocks the main thread: its name is what the report must show.
    @inline(never)
    static func blockTheMainThreadInjected(for seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { usleep(20_000) }
    }

    /// The .log's text each time the watchdog writes it.
    final class Writes: @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String] = []
        func add(_ text: String) { lock.lock(); texts.append(text); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return texts }
    }

    @Test @MainActor func aThreeSecondBlockShowsItsFrameInTheReport() throws {
        let folder = temp.url("hangs")
        let watchdog = HangWatchdog(folder: folder, samples: false)
        let writes = Writes()
        watchdog.onWrite = { name in
            writes.add((try? String(contentsOf: folder.appendingPathComponent(name + ".log"), encoding: .utf8)) ?? "")
        }
        watchdog.start()
        // Watched once it has beaten.
        let deadline = Date().addingTimeInterval(30)
        while watchdog.beatCount == 0, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        #expect(watchdog.beatCount > 0)
        Self.blockTheMainThreadInjected(for: 3)
        // The report once the main thread has answered: it has the stall's length.
        func recovered() -> String? { writes.all.last { $0.hasPrefix("vibeswitcher-hang:") && $0.contains(" duration=") } }
        while recovered() == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let log = try #require(recovered(), "no report with the stall's length; writes: \(writes.all.count)")
        let lines = log.components(separatedBy: "\n")
        let caught = try #require(lines.first { $0.hasPrefix(AppHealth.caughtTitle) }, "\(log)")
        // Caught from about 0.5 s into it (well before the 2 s it takes to be a stall), on to its end.
        let range = try #require(caught.firstMatch(of: #/from ([\d.]+) s to ([\d.]+) s/#))
        #expect(Double(range.1)! < 2 && Double(range.2)! >= 2, "\(caught)")
        let line = try #require(lines.first { $0.contains("blockTheMainThreadInjected") }, "the blocking frame isn't in:\n\(log)")
        // As the app's health digest reads it: the blocking frame on top of the app's frames.
        let image = try #require(line.firstMatch(of: #/\(in ([^)]+)\)/#)).1
        let frames = AppHealth.appFrames(sample: log, image: String(image))
        #expect(frames.first?.contains("blockTheMainThreadInjected") == true, "\(frames)")
        let hang = AppHealth.hang(name: "hang-x", log: log, sample: nil)
        #expect(hang.caught && (hang.duration ?? 0) >= 2.5, "\(hang)")
    }
}
