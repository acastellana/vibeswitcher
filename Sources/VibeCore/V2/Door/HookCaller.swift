import Foundation

/// Whose event a hook handles (the session sandbox plan's SB4). Today's hook is its agent's child and finds the agent,
/// and its terminal, among its own ancestors. A confined session's hook runs outside its box, as the porter's child,
/// so the porter tells it the relay's pid (`--for-pid P`, the pid `SO_PEERCRED` gave the porter for the door's
/// connection) and keeps the connection itself open in it (`--caller-socket N`), and the hook looks for the agent
/// among the relay's ancestors instead.
///
/// A pid alone names whichever process holds it when it is read, and a relay can leave while its connection stays
/// open in another process of its box: its pid, given out again to a process of another session, would make this hook
/// write that session's state and take its steered messages. And everything inside a box is the box's to make: a
/// terminal of its own devpts carries the same number as one of the machine's, and any process there can be named
/// `claude`. So the relay counts only when all of this holds:
///
/// - the socket proves its pid: `N` is a socket whose peer is `P`, as the kernel recorded when the relay connected;
/// - the process is held: `--caller-held H` is a descriptor of the process the porter took as the connection reached
///   it (`Platform.ProcessExit.hold`), which still names `P` and hasn't exited once its ancestors have been read, so
///   they were read of that process and no other;
/// - the process is of this session's box: its ancestors include `--box-init I`, the box's init as the kernel named
///   it to the porter on the door line (the sender of the message that carried the connection). A process of another
///   session, or of none, has no such ancestor, whatever its pid;
/// - the terminal is the session's: the box's init is on the terminal its keeper leads, the one the host gave the
///   session, and nothing inside can change that. The ancestors the hook is given end below init, and the nearest
///   agent among them must be on that terminal: an agent on a terminal made inside the box (a nested one, or a
///   process named for one on a pty whose number is another session's) is nobody's.
///
/// Anything else (a plain process that runs the hook with another session's pid, a relay that left, a process outside
/// the box, an agent on a terminal of the box's making) gets this process's own, as without the arguments: the
/// porter's child has no agent above it, and writes nothing.
public enum HookCaller {
    public static let pidFlag = "--for-pid"
    public static let socketFlag = "--caller-socket"
    public static let heldFlag = "--caller-held"
    public static let boxFlag = "--box-init"

    /// The process a hook's event is of, with what was read of it while it was held.
    public struct Caller {
        public var pid: pid_t
        /// Its ancestors, nearest first (`ProcessTable.ancestors`).
        public var ancestors: [ProcInfo]
        /// Its own terminal.
        public var tty: String?
    }

    /// The process whose ancestors the hook reads, with them: the relay the arguments name when everything in the
    /// type's comment holds; else this process. `info` reads a process (tests give a table).
    public static func read(_ arguments: [String], info: (Int32) -> ProcInfo? = { ProcessTable.info(pid: $0) }) -> Caller {
        func read(_ pid: pid_t) -> Caller { Caller(pid: pid, ancestors: ProcessTable.ancestors(of: pid, info: info), tty: info(pid)?.tty) }
        guard let claimed = value(after: pidFlag, in: arguments).flatMap(pid_t.init), claimed > 1,
              let socket = value(after: socketFlag, in: arguments).flatMap(Int32.init), socket > STDERR_FILENO,
              Platform.Sockets.peerPID(socket) == claimed,
              let held = value(after: heldFlag, in: arguments).flatMap(Int32.init), held > STDERR_FILENO,
              let box = value(after: boxFlag, in: arguments).flatMap(pid_t.init), box > 1 else { return read(getpid()) }
        let relay = read(claimed)
        // Held to the end of the read, and under this box's init: else nobody's.
        guard let at = relay.ancestors.firstIndex(where: { $0.pid == box }), Platform.ProcessExit.stillRuns(held: held, pid: claimed) else {
            return read(getpid())
        }
        // The session's terminal is its box's init's. What is above init is the node's, not the session's.
        guard let terminal = relay.ancestors[at].tty else { return read(getpid()) }
        let inside = Array(relay.ancestors[..<at])
        if let nearest = inside.first(where: { $0.agent != nil }), nearest.tty != terminal { return read(getpid()) }
        return Caller(pid: claimed, ancestors: inside, tty: relay.tty == terminal ? terminal : nil)
    }

    /// The process `read` settles on.
    public static func pid(_ arguments: [String]) -> pid_t { read(arguments).pid }

    /// The word after `flag` in `arguments`; nil when there is none.
    static func value(after flag: String, in arguments: [String]) -> String? {
        guard let at = arguments.firstIndex(of: flag), at + 1 < arguments.count else { return nil }
        return arguments[at + 1]
    }
}
