import Foundation
import Testing

/// A big board refreshed by the window never blocks its main thread, nor is read there, nor are the team's transcripts
/// the witness reads with it: the app's `--board-bench` (see
/// `BoardBench`), in a process of its own on a scratch home, so no other test's work on this process's main thread is
/// counted. A bench (its 50 ms is wall-clock time), run only by `scripts/test.sh --perf` (`Tag.perf`).
struct BoardBenchTests {
    private let scratch = Scratch()

    @Test(.tags(.perf), .enabled(if: perfRun, perfOnly)) func aBigBoardRefreshedBlocksTheMainThreadUnder50ms() throws {
        let app = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("VibeSwitcher")
        #expect(FileManager.default.isExecutableFile(atPath: app.path))
        let home = scratch.url("board-bench")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let output = scratch.url("board-bench-output")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let process = Process()
        process.executableURL = app
        process.arguments = ["--board-bench", "8"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["VIBESWITCHER_HOME"] = nil  // the run's own (scripts/test.sh) would come before this home
        process.environment = environment
        process.standardOutput = try FileHandle(forWritingTo: output)
        process.standardError = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        if ended.wait(timeout: .now() + hangGuard) == .timedOut {
            process.terminate()
            Issue.record("the bench hung")
            return
        }
        let text = try String(contentsOf: output, encoding: .utf8)
        print(text)
        #expect(process.terminationStatus == 0, "\(text)")
        // The board is as big as the one that froze the window: 844 KB and more.
        let size = text.firstMatch(of: #/a board of (\d+) KB/#).flatMap { Int($0.1) } ?? 0
        #expect(size >= 844)
        let block = text.firstMatch(of: #/longest main-thread block: (\d+) ms/#).flatMap { Int($0.1) }
        #expect(block != nil && block! < 50, "longest main-thread block: \(block.map(String.init) ?? "none") ms")
        // The witness reading a team of 30 with transcripts of a few MB each: no transcript read on the main thread,
        // and the refresh still under 50 ms.
        let team = text.firstMatch(of: #/with the team: longest main-thread block: (\d+) ms/#).flatMap { Int($0.1) }
        #expect(team != nil && team! < 50, "with the team: longest main-thread block: \(team.map(String.init) ?? "none") ms")
        let transcripts = text.firstMatch(of: #/transcripts read: (\d+), on the main thread: (\d+)/#).map { (Int($0.1) ?? 0, Int($0.2) ?? -1) }
        #expect((transcripts?.0 ?? 0) >= 30 * 8, "transcripts read: \(transcripts.map { "\($0.0)" } ?? "none")")
        #expect(transcripts?.1 == 0, "transcripts read on the main thread: \(transcripts.map { "\($0.1)" } ?? "none")")
        // Not one board read on the main thread, with the lead's views off screen and on.
        let reads = text.matches(of: #/boards read on the main thread: (\d+)/#).compactMap { Int($0.1) }
        #expect(reads == [0, 0], "boards read on the main thread: \(reads)")
        // The lead's views got each board from the main thread.
        #expect(text.contains("publishing faults: 0"))
    }
}

private final class Anchor {}
