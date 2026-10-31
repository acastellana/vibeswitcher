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
        // The 1-minute load when it got stuck, in the header and in words.
        #expect(lines[0].contains(" load=") && lines[0].contains(" cpus=\(ProcessInfo.processInfo.activeProcessorCount)"), "\(lines[0])")
        #expect(lines.contains { $0.hasPrefix("Main thread stuck since ") && $0.contains("; 1-minute load ") }, "\(log)")
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

    /// A finished sample is read at utility QoS, whatever thread its end was told on: 2026-10-31, read on the
    /// user-interactive thread `sample`'s termination handler ran on, it took CPU from an app the Mac was starving.
    @Test func aSampleIsReadAtUtilityQoS() throws {
        let file = temp.url("hang-x.txt")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        Analysis of sampling VibeSwitcher (pid 4242) every 1 millisecond
        Date/Time:       2026-10-31 00:39:12.345 +0100

        Call graph:
            300 Thread_100   DispatchQueue_1: com.apple.main-thread  (serial)
            + 300 start  (in dyld) + 6076  [0x18e0b0274]
            +   300 mach_msg2_trap  (in libsystem_kernel.dylib) + 8  [0x19b1beb80]
            300 Thread_101
        """.write(to: file, atomically: true, encoding: .utf8)
        final class Read: @unchecked Sendable {
            var qos: qos_class_t?
            var start: Date?
            var spread: AppHealth.Spread?
        }
        let read = Read(), done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
            HangWatchdog.read(sample: file) { start, spread in
                (read.qos, read.start, read.spread) = (qos_class_self(), start, spread)
                done.signal()
            }
        }
        #expect(done.wait(timeout: .now() + 60) == .success)
        #expect(read.qos == QOS_CLASS_UTILITY, "\(String(describing: read.qos?.rawValue))")
        #expect(read.start == Date(timeIntervalSince1970: 1_793_403_552.345))
        #expect(read.spread == AppHealth.Spread(samples: 300, pcs: 1, top: "mach_msg2_trap", topShare: 1, waiting: 1))
    }

    /// Reports are kept a week, up to a total size, the oldest going first: 2026-10-28, the ten newest were all that
    /// was kept, and a burst of freezes pushed out the reports a fix task named within hours.
    @Test func pruningKeepsAWeekUpToTheSizeCap() throws {
        let folder = temp.url("debug")
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_761_393_730)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        // 30 hangs, one every 8 hours back from an hour ago (the 22nd, 169 hours ago, and on are older than a week); every third has a
        // sample (.txt) too: 3500 bytes for those, 500 for the others.
        var names: [String] = []
        for index in 0..<30 {
            let name = "hang-" + formatter.string(from: now.addingTimeInterval(-3600 - Double(index) * 8 * 3600))
            names.append(name)
            try Data(count: 500).write(to: folder.appendingPathComponent(name + ".log"))
            if index % 3 == 0 { try Data(count: 3000).write(to: folder.appendingPathComponent(name + ".txt")) }
        }
        try Data(count: 10_000).write(to: folder.appendingPathComponent("app.log"))
        func kept() -> [String] { AppHealth.Folders(debug: folder, reports: folder).hangNames() }
        func files(_ range: Range<Int>) -> [String] {
            range.flatMap { [names[$0] + ".log"] + ($0 % 3 == 0 ? [names[$0] + ".txt"] : []) }
        }

        // By age: the week's 21 are kept, sample and all, under a cap they don't reach (14 * 500 + 7 * 3500 bytes).
        HangWatchdog.prune(folder, now: now, keepBytes: 50_000)
        #expect(kept() == Array(names[0..<21]).sorted())
        #expect(Set(try fm.contentsOfDirectory(atPath: folder.path)) == Set(files(0..<21) + ["app.log"]))
        // By size: the newest 12 are 18000 bytes, the 13th (with its sample) would take them past 20000.
        HangWatchdog.prune(folder, now: now, keepBytes: 20_000)
        #expect(kept() == Array(names[0..<12]).sorted())
        #expect(Set(try fm.contentsOfDirectory(atPath: folder.path)) == Set(files(0..<12) + ["app.log"]))
        // The newest is kept even past the cap on its own.
        HangWatchdog.prune(folder, now: now, keepBytes: 1)
        #expect(kept() == [names[0]])
        // A week on, it's old too, but still the newest.
        HangWatchdog.prune(folder, now: now.addingTimeInterval(8 * 86_400))
        #expect(kept() == [names[0]])
    }
}
