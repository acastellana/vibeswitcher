import Foundation
import Testing
@testable import VibeCore

/// The test binary's connector helper mode (the stage 2 plan's Task 4b2): the far end of an app connector, in a
/// process of its own, as the server child will be. Started again with `AppConnectorHelper.variable` set to the
/// number of the connector it inherited, this binary takes commands on its stdin before any test of its own, one a
/// line, answers each in one line on its stdout, and ends (0) at its stdin's end.
///
/// - `ask`: a connection asked for over the connector (`HostConnector.connect`), kept as its connection: "connected",
///   or "refused <why>".
/// - `child-ask`: a child of its own (a shell, the connector its stdout) writes the byte on it and stays, waiting on
///   its stdin, so the host reads a live sender: "sent <child's pid>".
/// - `child-end`: that child's stdin closed, which ends it, and the child reaped: "ended <wait status>".
/// - `pending`: whether a message waits on the connector, without reading it: "message" or "none".
/// - `empty`: a message of no bytes sent on the connector: "sent", or "unsent <errno>".
/// - `shut`: the connector shut for writing (`shutdown(SHUT_WR)`), kept open: "shut", or "unshut <errno>".
/// - `send <base64>`: a control frame with that payload (an encoded `HostRequestEnvelope`) written on its connection:
///   "sent", or "unsent <errno>".
/// - `event`: the next control frame on its connection: "event <base64 payload>", or "ended".
enum AppConnectorHelper {
    static let variable = "VIBE_APP_CONNECTOR_TEST_HELPER"

    static func serveIfAsked() {
        guard let value = getenv(variable), let connector = Int32(String(cString: value)) else { return }
        func say(_ text: String) {
            let line = text + "\n"
            _ = write(STDOUT_FILENO, line, line.utf8.count)
        }
        /// Waits until `fd` is ready for `events`, a hang guard at most.
        func ready(_ fd: Int32, for events: Int32, within seconds: TimeInterval = hangGuard) -> Bool {
            var waiting = pollfd(fd: fd, events: Int16(events), revents: 0)
            var result: Int32
            repeat { result = poll(&waiting, 1, Int32(seconds * 1_000)) } while result < 0 && errno == EINTR
            return result > 0
        }
        var connection: Int32 = -1
        // The `child-ask` child and the write end of its stdin, which keeps it alive until `child-end` closes it.
        var child: (pid: pid_t, stdin: Int32)?
        func endChild() -> Int32 {
            guard let running = child else { return -1 }
            child = nil
            close(running.stdin)
            var status: Int32 = 0
            while waitpid(running.pid, &status, 0) < 0, errno == EINTR {}
            return status
        }
        var decoder = HostFrameDecoder()
        var pending: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = read(STDIN_FILENO, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { break }
            guard byte == UInt8(ascii: "\n") else {
                pending.append(byte)
                continue
            }
            let words = String(decoding: pending, as: UTF8.self).split(separator: " ", maxSplits: 1).map(String.init)
            pending = []
            switch words.first {
            case "ask":
                do {
                    let fd = try HostConnector.connect(over: connector, timeout: hangGuard)
                    if connection >= 0 { close(connection) }
                    connection = fd
                    decoder = HostFrameDecoder()
                    say("connected")
                } catch {
                    say("refused \(error)")
                }
            case "child-ask":
                // The connector as its stdout: a shell's redirections reach descriptors 0 to 9 only. It stays until
                // its stdin ends: one that ended before the host read its byte would be no sender at all.
                guard child == nil else {
                    say("unstarted \(EBUSY)")
                    continue
                }
                var stdin: [Int32] = [-1, -1]
                guard Sys.pipeClosedOnExec(&stdin) == 0 else {
                    say("unstarted \(errno)")
                    continue
                }
                var spawn = Platform.Spawn(executable: "/bin/sh", arguments: ["/bin/sh", "-c", "printf c; read line; exit 0"])
                spawn.stdin = .descriptor(stdin[0])
                spawn.stdout = .descriptor(connector)
                spawn.stderr = .path("/dev/null", flags: O_WRONLY)
                spawn.keep = []
                let started = spawn.start()
                close(stdin[0])
                switch started {
                case .success(let pid):
                    child = (pid, stdin[1])
                    say("sent \(pid)")
                case .failure(let failure):
                    close(stdin[1])
                    say("unstarted \(failure.code)")
                }
            case "child-end":
                say(child == nil ? "unended" : "ended \(endChild())")
            case "pending":
                say(ready(connector, for: POLLIN, within: 0) ? "message" : "none")
            case "empty":
                say(Platform.Sockets.send(connector, nil, 0) == 0 ? "sent" : "unsent \(errno)")
            case "shut":
                say(shutdown(connector, Int32(SHUT_WR)) == 0 ? "shut" : "unshut \(errno)")
            case "send":
                guard words.count == 2, let payload = Data(base64Encoded: words[1]), connection >= 0 else {
                    say("unsent \(EINVAL)")
                    continue
                }
                let frame = [UInt8](HostFrame.encode(.control, payload))
                var written = 0
                while written < frame.count {
                    let count = frame[written...].withUnsafeBytes { Platform.Sockets.send(connection, $0.baseAddress, $0.count) }
                    if count > 0 {
                        written += count
                    } else if count < 0, errno == EINTR || errno == EAGAIN, ready(connection, for: POLLOUT) {
                        continue
                    } else {
                        break
                    }
                }
                say(written == frame.count ? "sent" : "unsent \(errno)")
            case "event":
                var said = false
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while !said, connection >= 0 {
                    if let frame = try? decoder.next() {
                        guard frame.kind == .control else { continue }
                        say("event " + frame.payload.base64EncodedString())
                        said = true
                        break
                    }
                    guard ready(connection, for: POLLIN) else { break }
                    let count = read(connection, &buffer, buffer.count)
                    if count > 0 {
                        decoder.append(Data(buffer[0..<count]))
                    } else if count < 0, errno == EINTR || errno == EAGAIN {
                        continue
                    } else {
                        break
                    }
                }
                if !said { say("ended") }
            default:
                say("unknown \(words.first ?? "")")
            }
        }
        if connection >= 0 { close(connection) }
        _ = endChild()
        _exit(0)
    }

    /// A helper the test talks to: its commands go to its stdin, its answers come from its stdout.
    final class Running {
        let pid: pid_t
        private var commands: Int32
        private let answers: Int32
        private var unread: [UInt8] = []
        private var reaped = false

        struct Failure: Error { var what: String }

        private init(pid: pid_t, commands: Int32, answers: Int32) {
            self.pid = pid
            self.commands = commands
            self.answers = answers
        }

        /// The test binary, started again in its helper mode, keeping `connector` under its number.
        static func start(connector: Int32) throws -> Running {
            // The helper never gets as far as a test; one that did would not start another.
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
            spawn.environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" } + ["\(variable)=\(connector)"]
            spawn.stdin = .descriptor(input[0])
            spawn.stdout = .descriptor(output[1])
            spawn.keep = [connector]
            let started = spawn.start()
            Sys.close(input[0])
            Sys.close(output[1])
            switch started {
            case .success(let pid): return Running(pid: pid, commands: input[1], answers: output[0])
            case .failure(let failure):
                Sys.close(input[1])
                Sys.close(output[0])
                throw Failure(what: "the helper didn't start: errno \(failure.code)")
            }
        }

        /// Sends `command` without waiting for its answer (one that may never come: `end(killing:)` then).
        func tell(_ command: String) throws {
            let line = Array((command + "\n").utf8)
            guard commands >= 0, write(commands, line, line.count) == line.count else {
                throw Failure(what: "\(command): the helper takes no more commands (errno \(errno))")
            }
        }

        /// Sends `command` and gives its answer, the helper's next line, within the hang guard.
        func ask(_ command: String) throws -> String {
            try tell(command)
            while true {
                if let end = unread.firstIndex(of: UInt8(ascii: "\n")) {
                    defer { unread.removeFirst(end + 1) }
                    return String(decoding: unread[..<end], as: UTF8.self)
                }
                var waiting = pollfd(fd: answers, events: Int16(POLLIN), revents: 0)
                var ready: Int32
                repeat { ready = poll(&waiting, 1, Int32(hangGuard * 1_000)) } while ready < 0 && errno == EINTR
                guard ready == 1 else { throw Failure(what: "\(command): no answer (poll \(ready))") }
                var chunk = [UInt8](repeating: 0, count: 4_096)
                let count = read(answers, &chunk, chunk.count)
                guard count > 0 else { throw Failure(what: "\(command): the helper ended without an answer") }
                unread += chunk.prefix(count)
            }
        }

        /// `request`, numbered `seq`, written on its connection.
        func send(_ seq: Int, _ request: HostRequest) throws {
            let payload = try HostCoding.encode(HostRequestEnvelope(seq: seq, request: request))
            let answer = try ask("send " + payload.base64EncodedString())
            guard answer == "sent" else { throw Failure(what: "\(request): \(answer)") }
        }

        /// The next event on its connection.
        func event() throws -> HostEventEnvelope {
            let answer = try ask("event")
            guard answer.hasPrefix("event "), let payload = Data(base64Encoded: String(answer.dropFirst("event ".count))) else {
                throw Failure(what: "no event: \(answer)")
            }
            return try HostCoding.decode(HostEventEnvelope.self, from: payload)
        }

        /// The event that answers `seq`, the ones before it passed over.
        func reply(to seq: Int) throws -> HostEvent {
            while true {
                let next = try event()
                if next.replyTo == seq { return next.event }
            }
        }

        /// Closes its stdin, which ends it (`killing`: SIGKILL first, for one held in a command), and reaps it.
        func end(killing: Bool = false) {
            guard !reaped else { return }
            reaped = true
            if killing { kill(pid, SIGKILL) }
            if commands >= 0 {
                Sys.close(commands)
                commands = -1
            }
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            Sys.close(answers)
        }

        deinit { end(killing: true) }
    }
}

// Runs as the test bundle loads, as the home guard does (TestSupport.swift).
#if os(Linux)
@_used @_section(".init_array")
private let serveTheConnectorTest: @convention(c) () -> Void = { AppConnectorHelper.serveIfAsked() }
#else
@_used @_section("__DATA,__mod_init_func")
private let serveTheConnectorTest: @convention(c) () -> Void = { AppConnectorHelper.serveIfAsked() }
#endif
