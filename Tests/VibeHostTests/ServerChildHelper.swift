import Foundation
import Testing
@testable import VibeCore

/// The test binary as the host's server child (the stage 2 plan's Task 8a): the stand-in for `vibeswitcher-server`,
/// chosen by its arguments (`vibeswitcher-server --host-connector N --host-socket PATH …`, what `ServerChild` starts
/// it with), not by an environment variable, which the host's base environment filters out. It runs before any test of
/// its own, from the test binary's load-time initializer, and never reaches one.
///
/// Its first statements are the server's (the engine's E1): it notes whether it is dumpable before anything else (the
/// sealed copy makes it non-dumpable from its exec), closes the image it was started from, marks the connector
/// close-on-exec, hardens, ignores SIGPIPE, and registers the connector for `--host-socket`
/// (`HostConnection.register(connector:for:)`), so every `HostCall` it makes goes through the connector. Then it does
/// what the file `server-helper-actions` beside the socket says, one line each, in order, and waits for more lines
/// appended there (or for the file it opened to grow), ending once the host's end of its connector has gone. Each
/// thing it does is a line in `server-helper-results` beside the socket, its pid first:
///
/// - (at its start) `started mark=server-helper dumpable-at-start=B image=FD socket=S root=R node-root=N connector=C
///   rest=A,B` (`rest`: the arguments after those, comma-separated).
/// - `call census`, `call vault-issue ROOT`, `call spawn CWD`: one `HostCall`, a connection of its own each:
///   "census ok", "vault-issue ok", "spawn ok", or "<what> refused <why>".
/// - `hold`: a connection kept, through the connector, its hello answered: "held", or "hold refused <why>".
/// - `held census`: a census on the kept connection: "held census ok", or "held census refused <why>".
/// - `fork-write census`: a child of its own (a shell) writes a census request on the kept connection, and ends:
///   "fork-wrote PID STATUS".
/// - `keep-held`: a child of its own (a shell) keeps the kept connection until the host ends it, then appends
///   "<this helper's pid> held-closed" to the results: "keeping PID". `keep-held connector`: the shell keeps the
///   helper's connector too, so the host's end of it doesn't see its other end go when the helper does.
/// - `child-call census BINARY`: BINARY (this test binary) started as its child, keeping every descriptor that isn't
///   close-on-exec, asks for a census as `childVariable` below says: "child-called STATUS".
/// - `dumpable`: makes itself dumpable again (`PR_SET_DUMPABLE 1`): "dumpable 0".
/// - `handover PATH`: asks the host to hand over to PATH: "handover <its answer>".
/// - `sleep`: nothing more: "sleeping".
enum ServerChildHelper {
    static let actionsName = "server-helper-actions"
    static let resultsName = "server-helper-results"
    static let mark = "server-helper"
    /// Starts this binary as a helper's child (`child-call`): "CONNECTOR SOCKET RESULTS". It says whether the
    /// connector's number is open in it, and asks for a census by the socket's path (through the connector instead,
    /// were it open): "child connector open|closed census ok|refused <why>".
    static let childVariable = "VIBE_SERVER_HELPER_CHILD"

    static func serveIfAsked() {
        if let asked = getenv(childVariable).map({ String(cString: $0) }) { serveAsChild(asked) }
        // Read before anything else: whether the exec itself left it non-dumpable.
        let dumpableAtStart = Platform.ProcessSelf.isDumpable()
        let arguments = Platform.Processes.arguments(getpid())
        guard arguments.first == "vibeswitcher-server", let at = arguments.firstIndex(of: "--host-connector"),
              arguments.indices.contains(at + 1), let connector = Int32(arguments[at + 1]) else { return }
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        let image = Platform.ProcessSelf.closeInheritedImage()
        _ = fcntl(connector, F_SETFD, FD_CLOEXEC)
        _ = Platform.ProcessSelf.harden()
        signal(SIGPIPE, SIG_IGN)
        guard let socket = value(after: "--host-socket") else { _exit(64) }
        HostConnection.register(connector: connector, for: socket)
        let dir = URL(fileURLWithPath: socket).deletingLastPathComponent().path
        let results = dir + "/" + resultsName
        func report(_ line: String) { append("\(getpid()) \(line)\n", to: results) }
        let named: Set<String> = ["--host-connector", "--host-socket", "--root", "--node-root"]
        var rest: [String] = []
        var index = 1
        while index < arguments.count {
            if named.contains(arguments[index]) { index += 2 } else { rest.append(arguments[index]); index += 1 }
        }
        report("started mark=\(mark) dumpable-at-start=\(dumpableAtStart.map(String.init) ?? "unknown") image=\(image.map(String.init) ?? "none")"
               + " socket=\(socket) root=\(value(after: "--root") ?? "") node-root=\(value(after: "--node-root") ?? "")"
               + " connector=\(connector) rest=\(rest.joined(separator: ","))")

        var held = Held()
        func act(_ line: String) {
            let words = line.split(separator: " ").map(String.init)
            switch (words.first ?? "", words.count) {
            case ("call", 2) where words[1] == "census":
                do {
                    _ = try HostCall.census(socket: socket, timeout: 60)
                    report("census ok")
                } catch {
                    report("census refused \(error)")
                }
            case ("call", 3) where words[1] == "vault-issue":
                do {
                    switch try HostCall.vault(.issue(role: .lead, root: words[2], task: nil, auditing: nil), socket: socket, timeout: 60) {
                    case .grant: report("vault-issue ok")
                    case .refused(let why): report("vault-issue refused \(why)")
                    case let other: report("vault-issue refused \(other)")
                    }
                } catch {
                    report("vault-issue refused \(error)")
                }
            case ("call", 3) where words[1] == "spawn":
                let request = SpawnRequest(cwd: words[2], command: "sleep 3600", env: [:], cols: 80, rows: 24, keepShell: false,
                                           label: "Server helper", agent: nil)
                do {
                    switch try HostCall.request(.spawn(request), socket: socket, timeout: 60) {
                    case .spawned: report("spawn ok")
                    case .error(let why): report("spawn refused \(why)")
                    case let other: report("spawn refused \(other)")
                    }
                } catch {
                    report("spawn refused \(error)")
                }
            case ("hold", 1):
                do {
                    try held.open(over: connector)
                    report("held")
                } catch {
                    report("hold refused \(error)")
                }
            case ("held", 2) where words[1] == "census":
                switch held.exchange(.census) {
                case .census?: report("held census ok")
                case .error(let why)?: report("held census refused \(why)")
                case let other: report("held census refused \(String(describing: other))")
                }
            case ("fork-write", 2) where words[1] == "census":
                let frame = dir + "/frame-\(getpid())"
                guard let payload = try? HostCoding.encode(HostRequestEnvelope(seq: 900, request: .census)),
                      FileManager.default.createFile(atPath: frame, contents: HostFrame.encode(.control, payload)) else {
                    return report("fork-wrote none")
                }
                var spawn = Platform.Spawn(executable: "/bin/sh", arguments: ["/bin/sh", "-c", "cat \"$0\"", frame])
                spawn.stdin = .path("/dev/null", flags: O_RDONLY)
                spawn.stdout = .descriptor(held.fd)
                spawn.keep = []
                guard case .success(let pid) = spawn.start() else { return report("fork-wrote none") }
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0, errno == EINTR {}
                report("fork-wrote \(pid) \(status)")
            case ("keep-held", 1), ("keep-held", 2) where words[1] == "connector":
                // Blocking, for the shell's `cat` (the descriptor's flags are its file's, shared with the shell's copy):
                // nonblocking, it reads EAGAIN at once and goes, before anything has ended the connection.
                _ = fcntl(held.fd, F_SETFL, fcntl(held.fd, F_GETFL) & ~O_NONBLOCK)
                var spawn = Platform.Spawn(executable: "/bin/sh", arguments: ["/bin/sh", "-c", "cat >/dev/null; echo \"$0 held-closed\" >>\"$1\"",
                                                                             String(getpid()), results])
                spawn.stdin = .descriptor(held.fd)
                spawn.stdout = .path("/dev/null", flags: O_WRONLY)
                spawn.keep = words.count == 2 ? [connector] : []
                guard case .success(let pid) = spawn.start() else { return report("keeping none") }
                report("keeping \(pid)")
            case ("child-call", 3) where words[1] == "census":
                var spawn = Platform.Spawn(executable: words[2], arguments: [words[2]])
                spawn.environment = environment() + ["\(childVariable)=\(connector) \(socket) \(results)"]
                spawn.stdin = .path("/dev/null", flags: O_RDONLY)
                spawn.keep = nil
                guard case .success(let pid) = spawn.start() else { return report("child-called none") }
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0, errno == EINTR {}
                report("child-called \(status)")
            case ("dumpable", 1):
                report("dumpable \(makeDumpable())")
            case ("handover", 2):
                do {
                    report("handover \(try HostCall.request(.handover(executable: words[1]), socket: socket, timeout: 60))")
                } catch {
                    report("handover refused \(error)")
                }
            case ("sleep", 1):
                report("sleeping")
            default:
                report("unknown \(line)")
            }
        }

        // The actions, read from one descriptor of the file as it was at the start: a test that puts another file in
        // its place gives that one to the next helper the host starts, not to this one.
        var actions: Int32 = -1
        var unread: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4_096)
        while !Platform.Sockets.peerHasGone(connector) {
            if actions < 0 { actions = open(dir + "/" + actionsName, O_RDONLY | O_CLOEXEC) }
            let count = actions < 0 ? 0 : read(actions, &chunk, chunk.count)
            if count > 0 {
                unread += chunk.prefix(count)
                while let end = unread.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: unread[..<end], as: UTF8.self)
                    unread.removeFirst(end + 1)
                    if !line.isEmpty { act(line) }
                }
                continue
            }
            // Nothing more yet: the test appends, or the host goes.
            usleep(20_000)
        }
        _exit(0)
    }

    /// The `child-call` child: what it holds of its parent's connector, and what a census gets it.
    private static func serveAsChild(_ asked: String) -> Never {
        let words = asked.split(separator: " ").map(String.init)
        guard words.count == 3, let connector = Int32(words[0]) else { _exit(64) }
        let open = fcntl(connector, F_GETFD) >= 0
        if open { HostConnection.register(connector: connector, for: words[1]) }
        var census: String
        do {
            _ = try HostCall.census(socket: words[1], timeout: 30)
            census = "ok"
        } catch {
            census = "refused \(error)"
        }
        append("\(getpid()) child connector \(open ? "open" : "closed") census \(census)\n", to: words[2])
        _exit(0)
    }

    /// `line` appended to the file at `path`, made 0600 if new.
    private static func append(_ line: String, to path: String) {
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        let bytes = Array(line.utf8)
        _ = write(fd, bytes, bytes.count)
        close(fd)
    }

    /// This process's environment, as "NAME=value" each, the child's variable left out.
    private static func environment() -> [String] {
        ProcessInfo.processInfo.environment.filter { $0.key != childVariable }.map { "\($0.key)=\($0.value)" }
    }

    /// `PR_SET_DUMPABLE 1`: 0, or the errno. Linux only (the Mac never starts a server child).
    private static func makeDumpable() -> Int32 {
        #if os(Linux)
        return vibe_set_dumpable(1) == 0 ? 0 : errno
        #else
        return ENOTSUP
        #endif
    }

    /// A connection the helper keeps (`hold`), its frames read as `AppConnectorHelper` reads them.
    struct Held {
        private(set) var fd: Int32 = -1
        private var decoder = HostFrameDecoder()
        private var seq = 1

        /// A connection asked for over `connector`, and its hello answered.
        mutating func open(over connector: Int32) throws {
            fd = try HostConnector.connect(over: connector, timeout: 60)
            guard case .welcome? = exchange(.hello(protocolVersion: HostProtocol.version, app: "server-helper")) else {
                throw HostCall.Failure(description: "no welcome")
            }
        }

        /// `request` sent, and the event that answers it (the others passed over); nil when none came.
        mutating func exchange(_ request: HostRequest) -> HostEvent? {
            seq += 1
            let mine = seq
            guard fd >= 0, let payload = try? HostCoding.encode(HostRequestEnvelope(seq: mine, request: request)) else { return nil }
            let frame = [UInt8](HostFrame.encode(.control, payload))
            var written = 0
            while written < frame.count {
                let count = frame[written...].withUnsafeBytes { Platform.Sockets.send(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    written += count
                } else if count < 0, errno == EINTR || errno == EAGAIN, Self.ready(fd, for: POLLOUT) {
                    continue
                } else {
                    return nil
                }
            }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                while let next = try? decoder.next() {
                    guard next.kind == .control, let envelope = try? HostCoding.decode(HostEventEnvelope.self, from: next.payload) else { continue }
                    if envelope.replyTo == mine { return envelope.event }
                }
                guard Self.ready(fd, for: POLLIN) else { return nil }
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    decoder.append(Data(buffer[0..<count]))
                } else if count < 0, errno == EINTR || errno == EAGAIN {
                    continue
                } else {
                    return nil
                }
            }
        }

        private static func ready(_ fd: Int32, for events: Int32) -> Bool {
            var waiting = pollfd(fd: fd, events: Int16(events), revents: 0)
            var result: Int32
            repeat { result = poll(&waiting, 1, 60_000) } while result < 0 && errno == EINTR
            return result > 0
        }
    }
}

// Runs as the test bundle loads, as the home guard does (TestSupport.swift).
#if os(Linux)
@_used @_section(".init_array")
private let serveAsTheServerChild: @convention(c) () -> Void = { ServerChildHelper.serveIfAsked() }
#else
@_used @_section("__DATA,__mod_init_func")
private let serveAsTheServerChild: @convention(c) () -> Void = { ServerChildHelper.serveIfAsked() }
#endif
