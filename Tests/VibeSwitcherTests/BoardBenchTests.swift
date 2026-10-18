import Foundation
import Testing

/// A big board refreshed by the window never blocks its main thread, nor is read there: the app's `--board-bench` (see
/// `BoardBench`), in a process of its own on a scratch home, so no other test's work on this process's main thread is
/// counted.
struct BoardBenchTests {
    private let scratch = Scratch()

    @Test func aBigBoardRefreshedBlocksTheMainThreadUnder50ms() throws {
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
        // Not one board read on the main thread, with the lead's views off screen and on.
        let reads = text.matches(of: #/boards read on the main thread: (\d+)/#).compactMap { Int($0.1) }
        #expect(reads == [0, 0], "boards read on the main thread: \(reads)")
        // The lead's views got each board from the main thread.
        #expect(text.contains("publishing faults: 0"))
    }
}

private final class Anchor {}
