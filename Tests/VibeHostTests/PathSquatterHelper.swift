import Foundation
import Testing
@testable import VibeCore

/// The test binary as a squatter on a host's path (the stage 2 plan's Task 8b): a process other than the host (and
/// than this test process, in which a scratch host runs) listening on a socket of its own. Started again with
/// `PathSquatterHelper.variable` set to a path, it listens there before any test of its own, says "listening" on its
/// stdout, and ends (0) at its stdin's end.
enum PathSquatterHelper {
    static let variable = "VIBE_PATH_SQUATTER_HELPER"

    static func listenIfAsked() {
        guard let value = getenv(variable) else { return }
        let path = String(cString: value)
        guard (try? UnixSocket.listen(path: path)) != nil else { _exit(1) }
        let line = "listening\n"
        _ = write(STDOUT_FILENO, line, line.utf8.count)
        var byte: UInt8 = 0
        while true {
            let count = read(STDIN_FILENO, &byte, 1)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
        }
        _exit(0)
    }

    /// A squatter listening at `path`, its own process: ended (its stdin closed) and reaped by `end()`, and when it goes.
    final class Running {
        let pid: pid_t
        private var stdin: Int32

        struct Failure: Error { var what: String }

        private init(pid: pid_t, stdin: Int32) {
            self.pid = pid
            self.stdin = stdin
        }

        /// The test binary, started again in its squatter mode at `path`, once it listens there.
        static func start(at path: String) throws -> Running {
            try #require(getenv(variable) == nil)
            let binary = try #require(Bundle.main.executablePath)
            var input: [Int32] = [-1, -1]
            var output: [Int32] = [-1, -1]
            guard Sys.pipeClosedOnExec(&input) == 0 else { throw Failure(what: "no pipe: errno \(errno)") }
            guard Sys.pipeClosedOnExec(&output) == 0 else {
                input.forEach { Sys.close($0) }
                throw Failure(what: "no pipe: errno \(errno)")
            }
            var spawn = Platform.Spawn(executable: binary, arguments: ProcessInfo.processInfo.arguments)
            spawn.environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" } + ["\(variable)=\(path)"]
            spawn.stdin = .descriptor(input[0])
            spawn.stdout = .descriptor(output[1])
            spawn.keep = []
            let started = spawn.start()
            Sys.close(input[0])
            Sys.close(output[1])
            defer { Sys.close(output[0]) }
            guard case .success(let pid) = started else {
                Sys.close(input[1])
                throw Failure(what: "the squatter didn't start")
            }
            let running = Running(pid: pid, stdin: input[1])
            // Its one line, or its end: what it says is waited for, a hang guard at most.
            var said: [UInt8] = []
            var byte: UInt8 = 0
            while said.last != UInt8(ascii: "\n") {
                var waiting = pollfd(fd: output[0], events: Int16(POLLIN), revents: 0)
                guard poll(&waiting, 1, Int32(hangGuard * 1_000)) > 0, read(output[0], &byte, 1) == 1 else { break }
                said.append(byte)
            }
            guard String(decoding: said, as: UTF8.self) == "listening\n" else {
                running.end()
                throw Failure(what: "the squatter didn't listen at \(path)")
            }
            return running
        }

        func end() {
            guard stdin >= 0 else { return }
            Sys.close(stdin)
            stdin = -1
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        }

        deinit { end() }
    }
}

// Runs as the test bundle loads, as the home guard does (TestSupport.swift).
#if os(Linux)
@_used @_section(".init_array")
private let listenAsASquatter: @convention(c) () -> Void = { PathSquatterHelper.listenIfAsked() }
#else
@_used @_section("__DATA,__mod_init_func")
private let listenAsASquatter: @convention(c) () -> Void = { PathSquatterHelper.listenIfAsked() }
#endif
