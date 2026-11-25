import Foundation
import Testing

/// The soak bench's script states how long a run of it may take (`--bound`), and SandboxSoakBenchTests guards the run
/// past that, not at a fixed time. The app's first daily memory-bench run (2026-11-19) ended "the soak bench hung" at a
/// 900 s guard while the soak, healthy at ~7 cycles a minute, still needed its last minute or so of 15: the guard was
/// under the soak's own minutes. Not a bench: `--bound` runs nothing.
struct SandboxSoakBoundTests {
    private let scratch = Scratch()
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let script = repo.appendingPathComponent("scripts/sandbox-soak-bench.sh").path

    struct NoBound: Error, CustomStringConvertible {
        var description: String
    }

    /// The seconds a run of the script with `arguments` (the script's path first, as the bench runs it) takes at most:
    /// the same run with `--bound`, which prints it and runs nothing.
    static func bound(_ arguments: [String]) throws -> Int {
        guard arguments.first == script else { throw NoBound(description: "not the soak bench's script: \(arguments)") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script, "--bound"] + arguments.dropFirst()
        process.currentDirectoryURL = repo
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Read to its end (the script's end closes it), then the exit: one short line.
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard waitForEnd(process) else { throw NoBound(description: "--bound never ended") }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, let seconds = Int(text) else {
            throw NoBound(description: "--bound said \(text) (exit \(process.terminationStatus))")
        }
        return seconds
    }

    @Test func theBoundCoversTheSoaksOwnMinutesAndItsWaits() throws {
        let dir = scratch.url("soak-dir")
        // As SandboxSoakBenchTests runs it: 18 minutes at most for 5 simulated hours.
        let bound = try Self.bound([Self.script, "--binary", "/nonexistent/VibeSwitcher", "--dir", dir.path, "--max-minutes", "18", "5"])
        // The soak's 18 minutes, the script's 2 past them and its minute for the soak's end after a stop, and the
        // sandbox's start: a guard at the bound or past it never ends a healthy run.
        #expect(bound >= 18 * 60 + 120 + 60 + 120, "the bound \(bound) s is under the soak's own minutes and waits")
        // And it isn't a guard that never fires: under the app's 90-minute timeout with room for the build.
        #expect(bound < 45 * 60)
        // Fewer minutes, a smaller bound by as much: the soak's minutes are in it.
        let shorter = try Self.bound([Self.script, "--binary", "/nonexistent/VibeSwitcher", "--dir", dir.path, "--max-minutes", "8", "5"])
        #expect(bound - shorter == 10 * 60)
        // It ran nothing: no sandbox folder made.
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    /// The bench guards its run past that bound: its arguments name the soak's minutes, its guard is the bound the
    /// script gives for those very arguments, and the wait on the script's end is that guard, not a fixed time (the
    /// 900 s of `3 * hangGuard` that ended the 2026-11-19 runs).
    @Test func theBenchGuardsItsRunPastTheScriptsBound() throws {
        let bench = try String(contentsOf: Self.repo.appendingPathComponent("Tests/VibeSwitcherTests/SandboxSoakBenchTests.swift"), encoding: .utf8)
        #expect(bench.contains(#""--max-minutes", "\(Self.maxMinutes)""#), "the bench doesn't pass its soak's minutes to the script")
        #expect(bench.contains("SandboxSoakBoundTests.bound(arguments)"), "the bench doesn't ask the script for its bound")
        #expect(bench.contains("process.arguments = arguments"), "the bench runs other arguments than those it took the bound for")
        let waits = bench.components(separatedBy: "\n").filter { $0.contains("ended.wait(timeout:") }
        #expect(waits.count == 1 && waits.allSatisfy { $0.contains("guardTime") && !$0.contains("hangGuard") },
                "the wait on the script's end isn't the bound's guard: \(waits)")
        #expect(bench.contains("let guardTime = TimeInterval(bound) + hangGuard"), "the guard isn't past the script's bound")
    }
}
