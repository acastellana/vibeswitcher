import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// Each message's sender (the stage 2 plan's Task 7, the security architecture document's S5): a connection whose
/// bytes come from anyone but the process the host accepted (or, for the app's connections on Linux, the process it
/// made them for) is nobody's from then on. On the Mac the kernel's token already names the last sender
/// (`LOCAL_PEERTOKEN`); on Linux the host reads each message's sender (`SCM_CREDENTIALS`, `Platform.Sockets.receive`),
/// where `SO_PEERCRED` alone names the process that connected for good.
///
/// The lead here is this binary in its helper mode (`LeadConnectionHelper`), run as a session's program by a scratch
/// host, connected by the socket's path, so the host takes it for that session, which the vault binds to a team's
/// lead. The test drives it through two FIFOs.
@Suite(hostTestLimit) struct PeerPerMessageTests {
    let temp = Scratch()
    /// The team's repository, as the vault names it: never made.
    let root: String
    init() { root = temp.url("peer-repo").path }

    /// A frame of `request`, numbered `seq`.
    static func frame(_ seq: Int, _ request: HostRequest) throws -> Data {
        HostFrame.encode(.control, try HostCoding.encode(HostRequestEnvelope(seq: seq, request: request)))
    }

    /// A request only the repository's lead may make: a worker's grant.
    func leadOnly(_ task: String) -> HostRequest { .vault(.issue(role: .worker, root: root, task: task, auditing: nil)) }

    static func granted(_ event: HostEvent) -> Bool {
        if case .vault(.grant) = event { return true }
        return false
    }

    static func refused(_ event: HostEvent) -> Bool {
        if case .vault(.refused) = event { return true }
        return false
    }

    /// A scratch host with a vault, the app's client, and a lead: a session the app started and the vault binds to
    /// the lead role of `root`, whose program is connected to the host by its socket's path.
    func leadsConnection() async throws -> (host: TestHost, app: TestClient, lead: LeadConnectionHelper.Running) {
        let book = LeadVault.Book()
        let host = try TestHost(vault: book)
        let app = try TestClient(host)
        let folder = temp.url("peer").path
        let lead = try await LeadConnectionHelper.Running.start(host: host, app: app, folder: folder)
        guard case .grant(let grant) = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app) else {
            throw LeadConnectionHelper.Failure(what: "no lead's grant")
        }
        _ = book.answer(.bind(grant: grant, root: root, session: lead.session.id.uuidString), from: .app)
        try lead.connect()
        // The control: the lead's own request is the lead's.
        try lead.write(Self.frame(1, leadOnly("first")))
        let first = try lead.reply(to: 1)
        try #require(Self.granted(first), "the lead's own request: \(first)")
        return (host, app, lead)
    }

    /// A child of the lead's process, given the lead's connection, writes a request on it: the connection is no one's
    /// from then on, and the lead's next request is refused.
    @Test func aForkedChildWritingOnALeadsConnectionMakesItNobodys() async throws {
        let (host, app, lead) = try await leadsConnection()
        defer { lead.end() }
        _ = (host, app)

        try lead.childWrite(Self.frame(2, .hello(protocolVersion: HostProtocol.version, app: "child")))
        _ = try lead.reply(to: 2)
        #expect(try lead.childEnd() == "ended 0")
        try lead.write(Self.frame(3, leadOnly("after")))
        let after = try lead.reply(to: 3)
        #expect(Self.refused(after), "after a child wrote on the lead's connection: \(after)")
    }

    /// Half a frame from the lead, the rest from its child: the frame is handled as an unknown caller's request
    /// (refused, not dropped: a reply comes), as the Mac does, and the connection is no one's from then on.
    @Test func aFrameSplitAcrossTwoSendersIsHandledAsNobodys() async throws {
        let (host, app, lead) = try await leadsConnection()
        defer { lead.end() }
        _ = (host, app)

        let frame = try Self.frame(2, leadOnly("split"))
        let half = frame.count / 2
        try lead.write(frame.prefix(half))
        try lead.childWrite(frame.dropFirst(half))
        let split = try lead.reply(to: 2)
        #expect(Self.refused(split), "a frame of two senders' bytes: \(split)")
        #expect(try lead.childEnd() == "ended 0")
        try lead.write(Self.frame(3, leadOnly("after")))
        let after = try lead.reply(to: 3)
        #expect(Self.refused(after), "after a frame of two senders' bytes: \(after)")
    }

    /// The process accepted keeps its identity however many times it writes: a thousand writes, each a request a
    /// session may make (a census), each answered as the lead's; then a request only the lead may make, granted.
    @Test func theAcceptedProcessKeepsItsIdentityOverAThousandWrites() async throws {
        let (host, app, lead) = try await leadsConnection()
        defer { lead.end() }
        _ = (host, app)

        let writes = 1_000
        for seq in 2..<(2 + writes) { try lead.write(Self.frame(seq, .census)) }
        var answered = 0
        for seq in 2..<(2 + writes) {
            let reply = try lead.reply(to: seq)
            guard case .census = reply else {
                Issue.record("write \(seq - 1) of \(writes): \(reply)")
                break
            }
            answered += 1
        }
        #expect(answered == writes)
        try lead.write(Self.frame(2 + writes, leadOnly("last")))
        let last = try lead.reply(to: 2 + writes)
        #expect(Self.granted(last), "after \(writes) writes: \(last)")
    }

    /// The Mac's re-read when the host sends kept (`checkPeer` at `broadcast`, which names whoever last used the peer's
    /// socket, even with bytes the host hasn't read yet): a child writes the start of a frame on the lead's connection,
    /// a broadcast follows (a session the app starts), and the lead's next request is refused.
    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's LOCAL_PEERTOKEN re-read at broadcast; Linux reads each message's sender"))
    func aForkedWriterIsStillCaughtWhenTheHostBroadcasts() async throws {
        let (host, app, lead) = try await leadsConnection()
        defer { lead.end() }
        _ = host

        let frame = try Self.frame(2, leadOnly("after"))
        try lead.childWrite(frame.prefix(2))
        _ = try await app.spawn("sleep 30")
        #expect(try lead.childEnd() == "ended 0")
        try lead.write(frame.dropFirst(2))
        let after = try lead.reply(to: 2)
        #expect(Self.refused(after), "after a child wrote on the lead's connection: \(after)")
    }

    /// The rule itself (`SenderCheck.keepsIdentity`): only the process accepted keeps a connection's identity. A
    /// missing sender (no credentials, or gone) is never it, nor is another process, nor anyone when none was accepted.
    @Test func aMissingSenderMakesTheConnectionNobodys() throws {
        var ends: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, Platform.Sockets.stream, 0, &ends) == 0)
        defer { ends.forEach { Sys.close($0) } }
        for end in ends { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        Platform.Sockets.enableCredentials(ends[0])
        // This process: on both systems the pair names its maker, and its own write comes as itself.
        let accepted = try #require(Platform.Sockets.peerToken(ends[0]))
        #expect(Sys.write(ends[1], "s", 1) == 1)
        var buffer = [UInt8](repeating: 0, count: 16)
        let own = buffer.withUnsafeMutableBytes { Platform.Sockets.receive(ends[0], into: $0) }
        let itself = try #require(own.sender)

        // Another process: a child writing on the pair, held until the test reads.
        var stdin: [Int32] = [-1, -1]
        try #require(Sys.pipeClosedOnExec(&stdin) == 0)
        var spawn = Platform.Spawn(executable: "/bin/sh", arguments: ["/bin/sh", "-c", "printf c; read line; exit 0"])
        spawn.stdin = .descriptor(stdin[0])
        spawn.stdout = .descriptor(ends[1])
        spawn.keep = []
        let started = spawn.start()
        Sys.close(stdin[0])
        let child = try started.get()
        var reaped = false
        defer {
            if !reaped {
                Sys.close(stdin[1])
                reap(child)
            }
        }
        var waiting = pollfd(fd: ends[0], events: Int16(POLLIN), revents: 0)
        try #require(poll(&waiting, 1, Int32(hangGuard * 1_000)) == 1, "the child wrote nothing")
        let theirs = buffer.withUnsafeMutableBytes { Platform.Sockets.receive(ends[0], into: $0) }
        let other = try #require(theirs.sender)
        Sys.close(stdin[1])
        reap(child)
        reaped = true

        #expect(SenderCheck.keepsIdentity(accepted: accepted, sender: itself))
        #expect(!SenderCheck.keepsIdentity(accepted: accepted, sender: nil))
        #expect(!SenderCheck.keepsIdentity(accepted: accepted, sender: other))
        #expect(!SenderCheck.keepsIdentity(accepted: nil, sender: itself))
        #expect(!SenderCheck.keepsIdentity(accepted: nil, sender: nil))

        // The decoder's note of who sent a frame's bytes (`FrameSenders`): one sender over several reads is one; a
        // frame that crosses from one sender's bytes to another's, or between two reads of no known sender, is two.
        var senders = FrameSenders()
        senders.append(3, from: itself)
        senders.append(4, from: itself)
        senders.append(5, from: other)
        senders.append(2, from: nil)
        senders.append(2, from: nil)
        let taken = [6, 3, 3, 4, 1].map { senders.take($0) }
        // One sender's bytes, read twice; the end of one sender's bytes and the start of another's; the rest of the
        // other's; two reads of no known sender; nothing left.
        #expect(taken == [false, true, false, true, false])
    }
}

/// Reaps `pid`, waiting for its end.
private func reap(_ pid: pid_t) {
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0, errno == EINTR {}
}

/// The test binary's lead helper mode: a team's lead, connected to a scratch host by the socket's path from inside a
/// session (so the host takes it for that session). Started again, as a session's program, with
/// `LeadConnectionHelper.variable` set to the host's socket path, this binary takes commands on its stdin before any
/// test of its own, one a line, answers each in one line on its stdout, and ends (0) at its stdin's end.
///
/// - `connect`: connects by the socket's path: "connected", or "refused <why>".
/// - `write <base64>`: these bytes written on its connection by itself, in one write where the socket takes them:
///   "written", or "unwritten <errno>".
/// - `child-write <base64>`: these bytes written on its connection by a child of its own, `cat` (its stdin a pipe from
///   here, its stdout the connection), started at the first such command and staying until `child-end`, so the host
///   reads a live sender: "given <child's pid>".
/// - `child-end`: the child's stdin closed, which ends it, and the child reaped: "ended <wait status>".
/// - `event`: the next control frame on its connection: "event <base64 payload>", or "ended".
enum LeadConnectionHelper {
    static let variable = "VIBE_PEER_PER_MESSAGE_TEST_HELPER"

    struct Failure: Error { var what: String }

    static func serveIfAsked() {
        guard let value = getenv(variable) else { return }
        let path = String(cString: value)
        func say(_ text: String) {
            let line = text + "\n"
            _ = write(STDOUT_FILENO, line, line.utf8.count)
        }
        func ready(_ fd: Int32, for events: Int32) -> Bool {
            var waiting = pollfd(fd: fd, events: Int16(events), revents: 0)
            var result: Int32
            repeat { result = poll(&waiting, 1, Int32(hangGuard * 1_000)) } while result < 0 && errno == EINTR
            return result > 0
        }
        /// All of `bytes` written to `fd`: 0, or the errno that stopped it.
        func writeAll(_ bytes: [UInt8], to fd: Int32) -> Int32 {
            var written = 0
            while written < bytes.count {
                let count = bytes[written...].withUnsafeBytes { Sys.write(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    written += count
                } else if count < 0, errno == EINTR || errno == EAGAIN, ready(fd, for: POLLOUT) {
                    continue
                } else {
                    return errno == 0 ? EIO : errno
                }
            }
            return 0
        }
        var connection: Int32 = -1
        var child: (pid: pid_t, stdin: Int32)?
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
            let bytes = words.count == 2 ? Data(base64Encoded: words[1]).map { [UInt8]($0) } : nil
            switch words.first {
            case "connect":
                do {
                    connection = try UnixSocket.connect(path: path)
                    say("connected")
                } catch {
                    say("refused \(error)")
                }
            case "write":
                guard let bytes, connection >= 0 else {
                    say("unwritten \(EINVAL)")
                    continue
                }
                let code = writeAll(bytes, to: connection)
                say(code == 0 ? "written" : "unwritten \(code)")
            case "child-write":
                guard let bytes, connection >= 0 else {
                    say("ungiven \(EINVAL)")
                    continue
                }
                if child == nil {
                    var stdin: [Int32] = [-1, -1]
                    guard Sys.pipeClosedOnExec(&stdin) == 0 else {
                        say("ungiven \(errno)")
                        continue
                    }
                    var spawn = Platform.Spawn(executable: "/bin/cat", arguments: ["cat"])
                    spawn.stdin = .descriptor(stdin[0])
                    spawn.stdout = .descriptor(connection)
                    spawn.stderr = .path("/dev/null", flags: O_WRONLY)
                    spawn.keep = []
                    let started = spawn.start()
                    Sys.close(stdin[0])
                    guard case .success(let pid) = started else {
                        Sys.close(stdin[1])
                        say("ungiven \(errno)")
                        continue
                    }
                    child = (pid, stdin[1])
                }
                let code = writeAll(bytes, to: child!.stdin)
                say(code == 0 ? "given \(child!.pid)" : "ungiven \(code)")
            case "child-end":
                guard let running = child else {
                    say("unended")
                    continue
                }
                child = nil
                Sys.close(running.stdin)
                var status: Int32 = 0
                while waitpid(running.pid, &status, 0) < 0, errno == EINTR {}
                say("ended \(status)")
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
        if let running = child {
            Sys.close(running.stdin)
            var status: Int32 = 0
            while waitpid(running.pid, &status, 0) < 0, errno == EINTR {}
        }
        if connection >= 0 { Sys.close(connection) }
        _exit(0)
    }

    /// The helper as a session's program, driven through two FIFOs in a folder of the test's: its commands go to one,
    /// its answers come from the other.
    final class Running {
        let session: HostSession
        private var commands: Int32
        private let answers: Int32
        private var unread: [UInt8] = []

        private init(session: HostSession, commands: Int32, answers: Int32) {
            self.session = session
            self.commands = commands
            self.answers = answers
        }

        /// The test binary, started again in its helper mode as the program of a session `app` asks `host` for, in
        /// `folder` (made here).
        static func start(host: TestHost, app: TestClient, folder: String) async throws -> Running {
            // The helper never gets as far as a test; one that did would not start another.
            try #require(getenv(variable) == nil)
            let binary = try #require(Bundle.main.executablePath)
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let input = folder + "/commands", output = folder + "/answers"
            for fifo in [input, output] { try #require(mkfifo(fifo, 0o600) == 0, "no FIFO at \(fifo): errno \(errno)") }
            // Each opened both ways here, so neither open waits for the helper's, and the helper's doesn't either.
            let commands = open(input, O_RDWR | O_CLOEXEC), answers = open(output, O_RDWR | O_CLOEXEC)
            guard commands >= 0, answers >= 0 else {
                let code = errno
                for fd in [commands, answers] where fd >= 0 { Sys.close(fd) }
                throw Failure(what: "the FIFOs didn't open: errno \(code)")
            }
            let program = ([binary] + ProcessInfo.processInfo.arguments.dropFirst()).map(RecentProjects.shellQuote).joined(separator: " ")
            let line = "\(program) < \(RecentProjects.shellQuote(input)) > \(RecentProjects.shellQuote(output)) 2> \(RecentProjects.shellQuote(folder + "/errors"))"
            var environment = ProcessInfo.processInfo.environment
            environment[variable] = host.socket
            let seq = app.send(.spawn(SpawnRequest(cwd: folder, command: line, env: environment, cols: 80, rows: 24, keepShell: false,
                                                   label: "Lead", agent: nil)))
            _ = await eventually { app.reply(to: seq) != nil }
            guard case .spawned(let session)? = app.reply(to: seq) else {
                for fd in [commands, answers] { Sys.close(fd) }
                throw Failure(what: "the lead's session didn't start: \(String(describing: app.reply(to: seq)))")
            }
            return Running(session: session, commands: commands, answers: answers)
        }

        /// Sends `command` and gives its answer, the helper's next line, within the hang guard.
        func ask(_ command: String) throws -> String {
            let line = Array((command + "\n").utf8)
            guard commands >= 0, Sys.write(commands, line, line.count) == line.count else {
                throw Failure(what: "\(command.prefix(40)): the helper takes no more commands (errno \(errno))")
            }
            while true {
                if let end = unread.firstIndex(of: UInt8(ascii: "\n")) {
                    defer { unread.removeFirst(end + 1) }
                    return String(decoding: unread[..<end], as: UTF8.self)
                }
                var waiting = pollfd(fd: answers, events: Int16(POLLIN), revents: 0)
                var ready: Int32
                repeat { ready = poll(&waiting, 1, Int32(hangGuard * 1_000)) } while ready < 0 && errno == EINTR
                guard ready == 1 else { throw Failure(what: "\(command.prefix(40)): no answer (poll \(ready))") }
                var chunk = [UInt8](repeating: 0, count: 4_096)
                let count = read(answers, &chunk, chunk.count)
                guard count > 0 else { throw Failure(what: "\(command.prefix(40)): the helper ended without an answer") }
                unread += chunk.prefix(count)
            }
        }

        func connect() throws {
            let answer = try ask("connect")
            guard answer == "connected" else { throw Failure(what: "connect: \(answer)") }
        }

        /// `bytes` written on its connection by the lead itself.
        func write(_ bytes: Data) throws {
            let answer = try ask("write " + bytes.base64EncodedString())
            guard answer == "written" else { throw Failure(what: "write: \(answer)") }
        }

        /// `bytes` written on its connection by its child.
        func childWrite(_ bytes: Data) throws {
            let answer = try ask("child-write " + bytes.base64EncodedString())
            guard answer.hasPrefix("given ") else { throw Failure(what: "child-write: \(answer)") }
        }

        /// Its child ended and reaped: "ended <wait status>".
        func childEnd() throws -> String { try ask("child-end") }

        /// The event that answers `seq`, the ones before it passed over.
        func reply(to seq: Int) throws -> HostEvent {
            while true {
                let answer = try ask("event")
                guard answer.hasPrefix("event "), let payload = Data(base64Encoded: String(answer.dropFirst("event ".count))) else {
                    throw Failure(what: "no reply to \(seq): \(answer)")
                }
                let next = try HostCoding.decode(HostEventEnvelope.self, from: payload)
                if next.replyTo == seq { return next.event }
            }
        }

        /// Its stdin closed, which ends it (its session ends with the host).
        func end() {
            guard commands >= 0 else { return }
            Sys.close(commands)
            commands = -1
            Sys.close(answers)
        }
    }
}

#if os(Linux)
@_used @_section(".init_array")
private let serveTheLeadConnectionTest: @convention(c) () -> Void = { LeadConnectionHelper.serveIfAsked() }
#else
@_used @_section("__DATA,__mod_init_func")
private let serveTheLeadConnectionTest: @convention(c) () -> Void = { LeadConnectionHelper.serveIfAsked() }
#endif
