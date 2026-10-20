import Darwin
import Foundation
import Testing

/// scripts/test.sh fails a run that leaves a process of its own running (a scratch session host, a parser, a bench's
/// app): one whose environment or arguments hold the run's scratch folder. On 2026-10-20 hosts and parsers from a run a
/// day before still ran (one of them a test's counter loop, 8 CPU-minutes so far). Here `--leftovers MARK` runs the
/// check alone, for a made-up mark: a process carrying it is named, ended and fails the check; none passes.
struct LeftoverCheckTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// `scripts/test.sh --leftovers mark`: its exit status and output.
    static func check(_ mark: String) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.repo.appendingPathComponent("scripts/test.sh").path, "--leftovers", mark]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    /// A stand-in for a test's leftover host and the program it runs: a shell naming `mark` in its arguments (as a host
    /// names its socket; ps shows the environment of the app's own binaries, not of Apple's /bin/sh), in a process group
    /// of its own as a host is, waiting on a pipe that never closes, with a `sleep` under it.
    static func leftover(_ mark: String) throws -> (shell: Process, input: Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 600 & read line", "/tmp/\(mark)/vibeswitcher-host"]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        setpgid(process.processIdentifier, process.processIdentifier)
        return (process, input)
    }

    /// The pids under `pid`.
    static func children(of pid: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 64)
        let count = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(0, count))))
    }

    @Test func aProcessOfTheRunLeftRunningIsEndedAndFailsTheRun() throws {
        let mark = "vs-test-leftover.\(UUID().uuidString.prefix(8))"
        let (shell, input) = try Self.leftover(mark)
        defer { if shell.isRunning { kill(shell.processIdentifier, SIGKILL) } }
        _ = input
        #expect(eventually(timeout: 30) { !Self.children(of: shell.processIdentifier).isEmpty })
        let sleeper = Self.children(of: shell.processIdentifier).first ?? 0
        let (status, output) = try Self.check(mark)
        #expect(status == 1, "\(output)")
        #expect(output.contains("LEFTOVER PROCESSES") && output.contains("\(shell.processIdentifier) /bin/sh -c sleep 600"), "\(output)")
        // What it ran goes too, though only the shell names the mark.
        #expect(output.contains("\(sleeper) sleep 600"), "\(output)")
        shell.waitUntilExit()
        #expect(shell.terminationReason == .uncaughtSignal && shell.terminationStatus == SIGTERM)
        #expect(eventually(timeout: 30) { kill(sleeper, 0) != 0 })
    }

    @Test func aRunThatLeftNothingPasses() throws {
        let (status, output) = try Self.check("vs-test-leftover.\(UUID().uuidString.prefix(8))")
        #expect(status == 0 && output.isEmpty, "\(output)")
    }

    /// The run's own processes aren't judged: only one carrying this run's mark (another run's, on the same Mac, is
    /// theirs).
    @Test func anotherMarkIsLeftAlone() throws {
        let (shell, input) = try Self.leftover("vs-test-other.\(UUID().uuidString.prefix(8))")
        defer {
            for pid in Self.children(of: shell.processIdentifier) { kill(pid, SIGKILL) }
            kill(shell.processIdentifier, SIGKILL)
        }
        _ = input
        let (status, _) = try Self.check("vs-test-leftover.\(UUID().uuidString.prefix(8))")
        #expect(status == 0)
        #expect(shell.isRunning)
    }
}
