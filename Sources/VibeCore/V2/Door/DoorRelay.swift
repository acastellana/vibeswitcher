import Foundation

/// The relay (the session sandbox plan's SB4): what `vibeswitcher-mcp` and `vibeswitcher-hook` become inside a confined
/// session's box. Their first statement is `runIfConfined`: with no door in the environment it returns, and the
/// program runs as it always has (a plain session, the Mac, the user's own sessions). With one, it never returns: it
/// connects to the door, sends its one line (`DoorProtocol.Hello`) with its stdin, stdout and stderr, waits for the
/// porter's answer and exits with the status the helper outside ended with; 69, with the reason on stderr, when the
/// door isn't there or the porter refused. It reads no path but the door's and no host socket, so a box needs neither
/// `~/.vibeswitcher` nor the node's sockets for its agent's tools and hooks to work.
///
/// A helper the porter started outside comes through here too, first thing: it finds its session's connector in the
/// environment (`DoorProtocol.connectorVariable` and `hostSocketVariable`), registers it for the host's socket
/// (`HostConnection.register(connector:for:)`), so that every call it makes to the host goes through the connector and
/// never by the socket's path, takes both variables and its image's out of its environment, closes the sealed copy it
/// was started from, and returns.
public enum DoorRelay {
    /// The status a relay exits with when the door isn't there or refused (`EX_UNAVAILABLE`).
    public static let unavailable: Int32 = 69
    /// The longest answer line a relay reads.
    static let maxAnswer = 4_096
    /// How long a hook's relay waits for its answer before it leaves quietly (exit 0, the hook's contract with the
    /// agent): the hook outside leaves past its own 3 s (`vibeswitcher-hook`'s alarm), and this is that with room for
    /// the door's two crossings.
    public static let hookPatience: UInt32 = 4

    /// The door named by `environment` (`DoorProtocol.variable`): an absolute path. nil when there is none, and always
    /// on the Mac, which has no session sandbox (`theMacsToolServerNeverRelays`).
    public static func door(environment: [String: String]) -> String? {
        guard !Platform.CodeIdentity.isAvailable, let door = environment[DoorProtocol.variable], door.hasPrefix("/") else { return nil }
        return door
    }

    /// The tool server's modes (`vibeswitcher-mcp`'s `arguments`, its program's name first): the server itself (started
    /// bare, through `--keeper`, or with `--role`, `--root` or `--task`), its status line and its permission hook.
    /// nil for its other modes (a verifier's shell prefix, the wallet's and the shell's requests, the test helpers),
    /// which then run in the box as they are.
    public static func toolServerMode(_ arguments: [String]) -> DoorProtocol.Mode? {
        guard arguments.count >= 2 else { return .mcp }
        switch arguments[1] {
        case MCPKeeper.flag, "--role", "--root", "--task": return .mcp
        case UsageStatusLine.argument: return .statusLine
        case ReadOnlyCommand.hookArgument: return .permission
        default: return nil
        }
    }

    /// The hook's mode (`vibeswitcher-hook`): always the hook.
    public static func hookMode(_ arguments: [String]) -> DoorProtocol.Mode? { .hook }

    /// See the type's comment. `mode` tells the relay's mode from its `arguments` (`CommandLine.arguments`), nil for
    /// one that isn't relayed.
    public static func runIfConfined(_ mode: (_ arguments: [String]) -> DoorProtocol.Mode?, arguments: [String],
                                     environment: [String: String]) {
        guard !Platform.CodeIdentity.isAvailable else { return }
        if environment[DoorProtocol.variable] == nil, let given = environment[DoorProtocol.connectorVariable] {
            takeConnector(given, socket: environment[DoorProtocol.hostSocketVariable])
            return
        }
        guard let door = door(environment: environment), let mode = mode(arguments) else { return }
        relay(DoorProtocol.Hello(mode: mode, args: Array(arguments.dropFirst())), door: door)
    }

    /// A helper's connector, registered for the host's socket; the variables gone from its environment and its image
    /// closed, so nothing it starts inherits either.
    private static func takeConnector(_ given: String, socket: String?) {
        unsetenv(DoorProtocol.connectorVariable)
        unsetenv(DoorProtocol.hostSocketVariable)
        Platform.ProcessSelf.closeInheritedImage()
        guard let connector = Int32(given), connector > STDERR_FILENO, let socket, socket.hasPrefix("/") else { return }
        let flags = fcntl(connector, F_GETFD)
        guard flags >= 0, fcntl(connector, F_SETFD, flags | FD_CLOEXEC) == 0 else { return }
        HostConnection.register(connector: connector, for: socket)
    }

    /// The relay itself: never returns.
    private static func relay(_ hello: DoorProtocol.Hello, door: String) -> Never {
        // A reader gone (the agent closing its pipes) makes a write fail, never ends the relay unseen.
        signal(SIGPIPE, SIG_IGN)
        if hello.mode == .hook {
            signal(SIGALRM) { _ in _exit(0) }
            alarm(hookPatience)
        }
        func fail(_ why: String) -> Never {
            FileHandle.standardError.write(Data("vibeswitcher: \(why)\n".utf8))
            exit(unavailable)
        }
        guard let line = DoorProtocol.line(hello) else { fail("this helper's arguments are too long for the session's door") }
        let socket: Int32
        do {
            socket = try UnixSocket.connect(path: door, patience: 1)
        } catch {
            fail("this session's door (\(door)) can't be reached: \(error)")
        }
        _ = fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) & ~O_NONBLOCK)
        // The three descriptors ride on the first bytes; the rest of a line a stream took only in part follows alone.
        var sent = 0
        while sent < line.count {
            let count = sent == 0
                ? Platform.Sockets.send(line, with: [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO], over: socket)
                : line[sent...].withUnsafeBytes { Platform.Sockets.send(socket, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { fail("this session's door closed before it took the request (errno \(errno))") }
            sent += count
        }
        var answer: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 512)
        while !answer.contains(UInt8(ascii: "\n")) {
            let count = Sys.read(socket, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { fail("this session's door closed without an answer") }
            answer += buffer[0..<count]
            guard answer.count <= maxAnswer else { fail("this session's door answered too long a line") }
        }
        let text = String(decoding: answer.prefix { $0 != UInt8(ascii: "\n") }, as: UTF8.self)
        switch DoorProtocol.answer(text) {
        case .exit(let status)?: exit(status)
        case .refused(let why)?: fail("this session's door refused: \(why)")
        case nil: fail("this session's door answered something else")
        }
    }
}
