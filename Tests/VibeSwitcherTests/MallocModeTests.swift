import Foundation
import Testing
@testable import VibeSwitcher

/// The app gives freed memory back to the system (`MallocMode`): on macOS 27.2 malloc kept the pages of every peak and
/// `malloc_zone_pressure_relief` gave none back, so the footprint climbed all day (+74 MB an hour, 2026-11-16).
@Suite struct MallocModeTests {
    private final class Anchor {}

    /// The real app binary, started as a launcher starts it (no setting in its environment), frees 200 MB of 40 KB
    /// blocks: its footprint comes back down, and nothing it starts would inherit the setting.
    @Test(hostTestLimit) func theAppGivesFreedMemoryBack() async throws {
        let app = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("VibeSwitcher")
        #expect(FileManager.default.isExecutableFile(atPath: app.path))
        let process = Process()
        process.executableURL = app
        process.arguments = ["--malloc-check"]
        var environment = ProcessInfo.processInfo.environment
        environment[MallocMode.variable] = nil
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Read as it writes, on a thread of its own, so that neither the read nor the wait below can hold the run: the
        // wait is bounded (`exited` kills the child past the hang guard), and a killed child's pipe ends, so the read does.
        let read = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var data = Data()
        Thread.detachNewThread {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        let ended = await exited(process)
        let readDone = await offPool { read.wait(timeout: .now() + 10) == .success }
        try #require(ended, "the app's --malloc-check never ended within \(Int(hangGuard)) s")
        try #require(readDone, "the app's output never ended after it did")
        let output = String(decoding: data, as: UTF8.self)
        let match = try #require(output.firstMatch(of: #/in use ([0-9.]+) MB, freed ([0-9.]+) MB, passed on (\S+)/#), "\(output)")
        let inUse = try #require(Double(match.1)), freed = try #require(Double(match.2))
        #expect(inUse > 200, "\(output)")
        // Before: 248 MB stayed (the pages kept for reuse); with the setting a few MB do.
        #expect(freed < 50, "\(output)")
        #expect(match.3 == "none", "\(output)")
    }
}
