import Foundation
import Testing
@testable import VibeCore

/// A verifier's command in a session of its own, on Linux (the stage 2 plan's Task 10c; the security architecture
/// document's S4). `BranchCode.runPrefix` is called here from this test binary started as a verifier session's shell
/// prefix (`BranchCodePrefixHelper`), in a process group it leads, as a Bash tool's process may: `setsid()` there would
/// fail with `EPERM`, so the command is started as a child in a session of its own, waited for, its status and a
/// SIGTERM passed on.
struct BranchCodeTests {
    /// The test binary as a prefix: `[binary, command]`, in a process group of its own, its output into a pipe.
    static func prefix(_ command: String) throws -> (pid: pid_t, output: Int32) {
        let binary = try #require(Platform.Processes.executable(getpid()))
        var ends: [Int32] = [-1, -1]
        try #require(Sys.pipeClosedOnExec(&ends) == 0)
        var spawn = Platform.Spawn(executable: binary, arguments: [binary, command])
        spawn.environment = ProcessInfo.processInfo.environment.merging(
            [BranchCodePrefixHelper.variable: "1", BranchCode.prefixVariable: "1", "SHELL": "/bin/bash"]) { $1 }
            .map { "\($0.key)=\($0.value)" }
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.stdout = .descriptor(ends[1])
        spawn.group = .ownGroup
        let started = spawn.start()
        close(ends[1])
        guard case .success(let pid) = started else {
            close(ends[0])
            throw Failure(description: "the prefix didn't start: \(started)")
        }
        return (pid, ends[0])
    }

    struct Failure: Error, CustomStringConvertible { var description: String }

    /// What `descriptor` gives until `done` holds of it or its output ends, waiting for each part 60 s at most (a guard
    /// against a hang, never a measure).
    static func read(_ descriptor: Int32, until done: (String) -> Bool = { _ in false }) -> String {
        var bytes = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 1_024)
        while !done(String(decoding: bytes, as: UTF8.self)) {
            var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            var ready: Int32
            repeat { ready = poll(&waiting, 1, 60_000) } while ready < 0 && errno == EINTR
            guard ready > 0 else { break }
            let got = Foundation.read(descriptor, &chunk, chunk.count)
            if got < 0, errno == EINTR { continue }
            guard got > 0 else { break }
            bytes += chunk[0..<got]
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// How `pid` ended: its exit status, or 128 and the signal that ended it.
    static func ended(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        let signalled = status & 0x7f
        return signalled == 0 ? (status >> 8) & 0xff : 128 + signalled
    }

    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's form; the Mac's prefix becomes the command in place"))
    func aCommandGetsItsOwnSessionWhenItsCallerLeadsAGroup() throws {
        // Its session, then its parent (the wrapper), then its exit status.
        let said = try Self.prefix("echo \"$(cut -d' ' -f6 /proc/self/stat) $PPID\"; exit 7")
        let output = Self.read(said.output)
        close(said.output)
        let status = Self.ended(said.pid)
        let words = output.split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
        #expect(words.count == 2, "\(output)")
        let (session, wrapper) = (words.first ?? 0, words.last ?? 0)
        #expect(session != getsid(0) && session != said.pid, "the command's session \(session) is its caller's (\(getsid(0)), prefix \(said.pid))")
        #expect(session == wrapper, "the command's session \(session) isn't the wrapper's \(wrapper)")
        #expect(status == 7)

        // A SIGTERM to the prefix reaches the command, and the prefix ends by it. The command says its process group
        // (the wrapper's, in a session of its own), so it can be ended when it never hears: the prefix, catching the
        // SIGTERM to send it on, would otherwise wait for it forever.
        let waiting = try Self.prefix("trap 'echo got-term; exit 3' TERM; echo \"ready $(cut -d' ' -f5 /proc/self/stat)\"; while :; do sleep 0.05; done")
        let ready = Self.read(waiting.output) { $0.hasPrefix("ready ") && $0.hasSuffix("\n") }
        let group = pid_t(ready.dropFirst("ready ".count).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        // Only a group that is neither none nor this test's own.
        let commandGroup = group > 1 && group != getpgrp() ? group : 0
        #expect(commandGroup != 0, "the command didn't say its process group: \(ready)")
        #expect(commandGroup != waiting.pid, "the command is in its caller's process group")
        kill(waiting.pid, SIGTERM)
        let rest = Self.read(waiting.output) { $0.contains("got-term\n") }
        if !rest.contains("got-term\n") {
            // It never heard: ended, the command first, so the prefix's wait ends and this test fails rather than hangs.
            if commandGroup != 0 { kill(-commandGroup, SIGKILL) }
            kill(-waiting.pid, SIGKILL)
        }
        let stopped = Self.ended(waiting.pid)
        // Whatever is left in either group, ended.
        if commandGroup != 0 { kill(-commandGroup, SIGKILL) }
        kill(-waiting.pid, SIGKILL)
        close(waiting.output)
        #expect(rest == "got-term\n", "the command never heard the SIGTERM: \(rest)")
        #expect(stopped == 128 + SIGTERM)
    }
}

/// This test binary as a verifier session's shell prefix: started with `variable` and `BranchCode.prefixVariable` set
/// and one command line, it is `vibeswitcher-mcp`'s first statement (`BranchCode.runPrefix`), and never reaches a test.
enum BranchCodePrefixHelper {
    static let variable = "VIBE_BRANCH_CODE_PREFIX_HELPER"

    static func serveIfAsked() {
        guard getenv(variable) != nil else { return }
        let arguments = Platform.Processes.arguments(getpid())
        var environment: [String: String] = [:]
        var entry = environ
        while let pointer = entry.pointee {
            let pair = String(cString: pointer)
            if let equals = pair.firstIndex(of: "=") { environment[String(pair[..<equals])] = String(pair[pair.index(after: equals)...]) }
            entry += 1
        }
        guard BranchCode.isPrefix(arguments, environment: environment) else { _exit(64) }
        let executable = Platform.Processes.executable(getpid()) ?? arguments[0]
        _exit(BranchCode.runPrefix(arguments, environment: environment, executable: executable))
    }
}

// Runs as the test bundle loads, as the home guard does (TestSupport.swift).
#if os(Linux)
@_used @_section(".init_array")
private let serveAsAPrefix: @convention(c) () -> Void = { BranchCodePrefixHelper.serveIfAsked() }
#else
@_used @_section("__DATA,__mod_init_func")
private let serveAsAPrefix: @convention(c) () -> Void = { BranchCodePrefixHelper.serveIfAsked() }
#endif
