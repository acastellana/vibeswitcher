import Darwin
import Foundation
import Testing
@testable import VibeCore

/// The built `vibeswitcher-mcp --status-line`, as Claude Code runs it for a session VibeSwitcher started (see
/// `UsageStatusLine`), on a scratch home: a reader that has gone (your status line not reading its input, Claude Code
/// closing the output) never ends it with SIGPIPE before your status line's output is printed and the usage kept.
struct StatusLineBinaryTests {
    let temp = Scratch()

    /// The binary run with `input` on its stdin (from a file) and `home` as HOME, its output to `output` (nil: a pipe
    /// whose reader is closed before it starts); its exit status, once it has exited.
    func run(input: Data, home: String, output: URL?) throws -> (status: Int32, reason: Process.TerminationReason) {
        let mcp = URL(fileURLWithPath: hostLauncher).deletingLastPathComponent().appendingPathComponent("vibeswitcher-mcp").path
        try #require(FileManager.default.isExecutableFile(atPath: mcp), "vibeswitcher-mcp isn't built beside the host: run swift build first")
        let inputFile = temp.url("status-input")
        try input.write(to: inputFile)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: mcp)
        process.arguments = [UsageStatusLine.argument]
        process.environment = ["HOME": home, "CFFIXED_USER_HOME": home, "VIBESWITCHER_HOME": home + "/.vibeswitcher", "PATH": "/usr/bin:/bin"]
        process.currentDirectoryURL = URL(fileURLWithPath: home)
        process.standardInput = try FileHandle(forReadingFrom: inputFile)
        process.standardError = FileHandle.nullDevice
        let gone = Pipe()
        if let output {
            FileManager.default.createFile(atPath: output.path, contents: nil)
            process.standardOutput = try FileHandle(forWritingTo: output)
        } else {
            process.standardOutput = gone
        }
        try process.run()
        if output == nil { try gone.fileHandleForReading.close() }
        waitForEnd(process)
        return (process.terminationStatus, process.terminationReason)
    }

    func home(statusLine command: String) throws -> String {
        let home = temp.url("status-home").resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        let settings: [String: Any] = ["statusLine": ["type": "command", "command": command]]
        try JSONSerialization.data(withJSONObject: settings).write(to: URL(fileURLWithPath: home + "/.claude/settings.json"))
        return home
    }

    /// A status line's input with a weekly window, padded to `size` bytes.
    func input(size: Int) -> Data {
        let head = #"{"rate_limits":{"seven_day":{"used_percentage":55,"resets_at":\#(Int(Date().timeIntervalSince1970) + 86_400)}},"pad":""#
        return Data((head + String(repeating: "a", count: max(0, size - head.utf8.count - 2)) + #""}"#).utf8)
    }

    @Test func aBigInputToAStatusLineThatDoesntReadItStillShowsItsOutput() async throws {
        let home = try home(statusLine: "echo mine")
        let output = temp.url("status-output")
        let ran = try await run(input: input(size: 100_000), home: home, output: output)
        #expect(ran.reason == .exit && ran.status == 0, "\(ran)")
        #expect(try Data(contentsOf: output) == Data("mine\n".utf8))
        #expect(AccountUsageStore(file: URL(fileURLWithPath: home + "/.vibeswitcher/account-usage.json")).load().limits.map(\.usedPercent) == [55])
    }

    /// The binary started with `home`'s status line (whose shell writes its pid to `started`) and stopped as Claude Code
    /// gives up on one, once that pid is written: TERM, to its process alone (as Node's child.kill sends it). The shell's
    /// pid (0: never written), once the binary has ended (killed past the hang guard).
    func startThenStop(home: String, started: URL) async throws -> (process: Process, shell: pid_t) {
        let mcp = URL(fileURLWithPath: hostLauncher).deletingLastPathComponent().appendingPathComponent("vibeswitcher-mcp").path
        try #require(FileManager.default.isExecutableFile(atPath: mcp), "vibeswitcher-mcp isn't built beside the host: run swift build first")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: mcp)
        process.arguments = [UsageStatusLine.argument]
        process.environment = ["HOME": home, "CFFIXED_USER_HOME": home, "VIBESWITCHER_HOME": home + "/.vibeswitcher", "PATH": "/usr/bin:/bin"]
        let inputFile = temp.url("status-input")
        try input(size: 1000).write(to: inputFile)
        process.standardInput = try FileHandle(forReadingFrom: inputFile)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        var pid: pid_t = 0
        #expect(await eventually { pid = (try? String(contentsOf: started, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0; return pid > 0 })
        if pid > 0 { kill(process.processIdentifier, SIGTERM) }
        #expect(await exited(process), "pid \(process.processIdentifier) still running")
        return (process, pid)
    }

    /// Whether `target` (a pid, or a group as its negative) is gone: ESRCH. EPERM isn't gone: XNU says it for a group
    /// whose one member left is a child still being made.
    func gone(_ target: pid_t) -> Bool { kill(target, 0) == -1 && errno == ESRCH }

    /// What is left of process group `group`, for a failure's message: each member (pid, parent, name) and what a
    /// signal 0 to the group says. A program alive there with launchd (1) as its parent is one the stop passed over.
    func left(in group: pid_t) -> String {
        var pids = [pid_t](repeating: 0, count: 256)
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let members = pids.prefix(max(0, Int(bytes)) / MemoryLayout<pid_t>.size).filter { $0 > 0 }.map { pid -> String in
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return "\(pid) (gone)" }
            let name = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return "\(pid) parent \(info.pbi_ppid) \(name)\(info.pbi_status == SZOMB ? " (zombie)" : "")"
        }
        let signalled = kill(-group, 0)
        let probe = signalled == 0 ? "signal 0 reaches it" : "signal 0: \(String(cString: strerror(errno)))"
        return "shell \(group) \(gone(group) ? "gone" : "alive"); its group: \(members.isEmpty ? "no member listed" : members.joined(separator: ", ")) (\(probe))"
    }

    /// Kills what is left of `group` (a program left running would run for an hour), whatever the test found.
    func sweep(_ group: pid_t) {
        guard group > 0 else { return }
        _ = eventuallyBlocking { kill(-group, SIGKILL) == -1 && errno == ESRCH }
    }

    @Test func claudeCodeStoppingTheStatusLineStopsYourCommandToo() async throws {
        let started = temp.url("status-started")
        // Yours hangs (a pipeline of two programs under its shell), as a network call or a git waiting on a lock does.
        let home = try home(statusLine: "echo $$ > '\(started.path)'; \(keepRunning) | cat")
        let (process, pid) = try await startThenStop(home: home, started: started)
        defer { sweep(pid) }
        try #require(pid > 0)
        #expect(process.terminationReason == .exit && process.terminationStatus == 0, "\(process.terminationReason) \(process.terminationStatus)")
        // Your command (its shell) and its whole process group are gone, not left running.
        #expect(await eventually { gone(pid) && gone(-pid) }, "\(left(in: pid))")
        #expect(AccountUsageStore(file: URL(fileURLWithPath: home + "/.vibeswitcher/account-usage.json")).load().limits.map(\.usedPercent) == [55])
    }

    /// Stopped while its shell is starting a program (a pipeline's or a `&`'s fork under way), your command leaves none
    /// of it running: XNU's kill of a group passes over a child still being made, which then runs on in the group with
    /// launchd as its parent. One stop lands in that window now and then (the test above failed so about 1 run in 10
    /// of a loaded full suite, 2026-11-18); a command starting one program after another is in it most of the time.
    @Test func stoppedWhileYourCommandStartsAProgramNoneOfItIsLeftRunning() async throws {
        for attempt in 1...12 {
            let started = temp.url("status-started-\(attempt)")
            // Each program stopped by the shell at once; the loop ends by itself (1000 of them) if nothing stops it.
            let home = try home(statusLine: "echo $$ > '\(started.path)'; i=0; while [ $i -lt 1000 ]; do \(keepRunning) & kill $!; i=$((i + 1)); done")
            let (process, pid) = try await startThenStop(home: home, started: started)
            defer { sweep(pid) }
            try #require(pid > 0)
            #expect(process.terminationReason == .exit && process.terminationStatus == 0, "\(process.terminationReason) \(process.terminationStatus)")
            let ended = await eventually { gone(pid) && gone(-pid) }
            #expect(ended, "stop \(attempt): \(left(in: pid))")
            if !ended { break }
        }
    }

    @Test func anOutputWhoseReaderHasGoneStillKeepsTheUsage() async throws {
        let home = try home(statusLine: "head -c 10 >/dev/null; echo mine")
        let ran = try await run(input: input(size: 100_000), home: home, output: nil)
        #expect(ran.reason == .exit && ran.status == 0, "\(ran)")
        #expect(AccountUsageStore(file: URL(fileURLWithPath: home + "/.vibeswitcher/account-usage.json")).load().limits.map(\.usedPercent) == [55])
    }
}
