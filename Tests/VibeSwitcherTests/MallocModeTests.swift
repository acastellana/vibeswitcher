import Foundation
import Testing
@testable import VibeSwitcher

/// The app gives freed memory back to the system (`MallocMode`): on macOS 27.2 malloc kept the pages of every peak and
/// `malloc_zone_pressure_relief` gave none back, so the footprint climbed all day (+74 MB an hour, 2026-11-16).
@Suite struct MallocModeTests {
    private final class Anchor {}

    /// The real app binary, started as a launcher starts it (no setting in its environment), frees 200 MB of 40 KB
    /// blocks: its footprint comes back down, and nothing it starts would inherit the setting.
    @Test func theAppGivesFreedMemoryBack() async throws {
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
        let output = await offPool { String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }
        process.waitUntilExit()
        let match = try #require(output.firstMatch(of: #/in use ([0-9.]+) MB, freed ([0-9.]+) MB, passed on (\S+)/#), "\(output)")
        let inUse = try #require(Double(match.1)), freed = try #require(Double(match.2))
        #expect(inUse > 200, "\(output)")
        // Before: 248 MB stayed (the pages kept for reuse); with the setting a few MB do.
        #expect(freed < 50, "\(output)")
        #expect(match.3 == "none", "\(output)")
    }
}
