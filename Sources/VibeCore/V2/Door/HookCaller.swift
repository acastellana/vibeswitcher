import Foundation

/// Whose event a hook handles (the session sandbox plan's SB4). Today's hook is its agent's child and finds the agent,
/// and its terminal, among its own ancestors. A confined session's hook runs outside its box, as the porter's child,
/// so the porter tells it the relay's pid (`--for-pid P`, the pid `SO_PEERCRED` gave the porter for the door's
/// connection) and keeps the connection itself open in it (`--caller-socket N`), and the hook looks for the agent
/// among the relay's ancestors instead.
///
/// The pid counts only when the socket proves it: `N` is a socket whose peer is `P`, as the kernel recorded when the
/// relay connected. Anything else (a plain process that runs the hook with another session's pid, to take that
/// session's state or its steered messages) gets its own pid, as without the arguments.
public enum HookCaller {
    public static let pidFlag = "--for-pid"
    public static let socketFlag = "--caller-socket"

    /// The process whose ancestors the hook reads: `--for-pid P` when `--caller-socket N` is a socket whose peer is
    /// `P`; else this process.
    public static func pid(_ arguments: [String]) -> pid_t {
        guard let claimed = value(after: pidFlag, in: arguments).flatMap(pid_t.init), claimed > 1,
              let socket = value(after: socketFlag, in: arguments).flatMap(Int32.init), socket > STDERR_FILENO,
              Platform.Sockets.peerPID(socket) == claimed else { return getpid() }
        return claimed
    }

    /// The word after `flag` in `arguments`; nil when there is none.
    static func value(after flag: String, in arguments: [String]) -> String? {
        guard let at = arguments.firstIndex(of: flag), at + 1 < arguments.count else { return nil }
        return arguments[at + 1]
    }
}
