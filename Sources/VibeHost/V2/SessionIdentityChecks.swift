import Foundation
import VibeCore

/// Who a session is, on Linux (the stage 2 plan's Task 6b, the security architecture document's S4, T14 and T42).
///
/// A process is the innermost live session whose program is in its ancestry, or else the session whose terminal is
/// its controlling terminal, as on the Mac. On Linux three things more hold:
///
/// - **A session's terminal is its own from the start.** The launcher opens its terminal `O_NOCTTY`
///   (`Platform.Terminals.launcherOpenFlags`), so nothing makes it its controlling terminal before the launcher's own
///   `makeControlling`; it then checks that call worked and that the terminal's session is its own, and otherwise says
///   why on the terminal and exits 127, its program never run (`takeTerminal`). The host counts a session live only
///   while the session of its terminal (`TIOCGSID` on the master) is its program's (`holdsIdentity`). Otherwise a
///   process that left its session (`setsid`) and spins opening the next `/dev/pts/N` would take a new session's
///   terminal first and be that session by the terminal rule.
/// - **A session's program is matched by its token** (pid and start ticks, `HostedSession.programToken`), not its pid
///   alone, and the ancestry is read link by link (`chain`): an ancestor started after its child isn't its parent (the
///   number was given again), and a child's parent is read again after its parent was, so a reparenting between the
///   two reads breaks the chain. A chain that fails is no session's.
/// - **A program reaped is no session's**, also when `HostedSession.reap(_:until:)`, on a queue of its own, reaped it
///   before the session's queue heard (`noteReaped`).
///
/// The Mac's paths are today's: its launcher ignores `makeControlling`'s answer, and `HostServer.session(of:)` keeps
/// its body there.
enum SessionIdentityChecks {
    // MARK: The launcher

    /// Before the program in the launcher's arguments, with seconds after it: the launcher waits that long before it
    /// takes its terminal (`HostServer.Config.launcherTestDelay`), so a test can take the terminal first. A scratch
    /// host's tests only: the user's host never passes it.
    static let launcherTestDelayFlag = "--pty-test-delay"

    /// What the launcher is given before the program: the test delay's flag and value, or nothing.
    static func launcherFlags(testDelay: TimeInterval?) -> [String] {
        guard let testDelay, testDelay > 0 else { return [] }
        return [launcherTestDelayFlag, String(testDelay)]
    }

    /// The launcher's first act, `given` its arguments after `--pty-exec`: it makes its terminal (descriptor 0) its
    /// controlling terminal, and gives back the program to run. On Linux, unless that worked and the terminal's
    /// session is now the launcher's own, it says why on the terminal and exits 127, running nothing. On the Mac,
    /// `makeControlling`'s answer is ignored, as always.
    static func takeTerminal(_ given: [String]) -> [String] {
        var program = given
        if program.count > 2, program[0] == launcherTestDelayFlag {
            let seconds = TimeInterval(program[1]) ?? 0
            program.removeFirst(2)
            if seconds > 0 { Thread.sleep(forTimeInterval: seconds) }
        }
        let made = Platform.Terminals.makeControlling(0)
        guard !Platform.CodeIdentity.isAvailable else { return program }
        let session = Platform.Terminals.controllingSession(0)
        guard made != 0 || session != getpid() else { return program }
        let why = made != 0 ? "it couldn't take it (\(String(cString: strerror(made))))"
            : "its session is \(session.map { "pid \($0)'s" } ?? "none")"
        let said = "VibeSwitcher: this session's terminal isn't its own: \(why). \(program.first ?? "Its program") wasn't started.\r\n"
        _ = said.withCString { write(2, $0, strlen($0)) }
        _exit(127)
    }

    // MARK: A session's program

    /// The token of a program just started (a child of this process, not reaped yet, so its pid is still its own).
    /// Linux only; nil on the Mac.
    static func programStarted(_ pid: pid_t) -> Platform.PeerToken? {
        guard !Platform.CodeIdentity.isAvailable else { return nil }
        // Its number, reaped once before as another session's program, is this program's now.
        reaped.remove(pid)
        return Platform.Processes.token(pid)
    }

    /// The token of a restored session's program, read again after a handover: only while this process is still its
    /// parent (a program reaped and its number given again is someone else). Linux only; nil on the Mac.
    static func programRestored(_ pid: pid_t) -> Platform.PeerToken? {
        guard !Platform.CodeIdentity.isAvailable, let link = Platform.Processes.link(pid), link.parent == getpid(),
              let token = Platform.Processes.token(pid), link.isProcess(of: token) else { return nil }
        return token
    }

    /// `HostedSession.reap(_:until:)` reaped `pid`, a closed session's program: it is no session's from now on, before
    /// any session's queue hears of it. Linux only.
    static func noteReaped(_ pid: pid_t) {
        guard !Platform.CodeIdentity.isAvailable else { return }
        reaped.insert(pid)
    }

    /// Whether a session still counts as live to who a process is (Linux): it hasn't ended, isn't closed, its program
    /// wasn't reaped, and its terminal's session is its program's (the launcher took it, and the program, which is
    /// the launcher after its exec, still leads it: a session leader that ended has lost its terminal).
    static func holdsIdentity(isLive: Bool, closed: Bool, master: Int32, program: pid_t) -> Bool {
        guard isLive, !closed, master >= 0, !reaped.contains(program) else { return false }
        return Platform.Terminals.session(ofMaster: master) == program
    }

    private static let reaped = ReapedPrograms()

    /// The programs `HostedSession.reap(_:until:)` reaped, by pid, until their number is a new program's.
    private final class ReapedPrograms: @unchecked Sendable {
        private let lock = NSLock()
        private var pids: Set<pid_t> = []

        func insert(_ pid: pid_t) { lock.lock(); pids.insert(pid); lock.unlock() }
        func remove(_ pid: pid_t) { lock.lock(); pids.remove(pid); lock.unlock() }
        func contains(_ pid: pid_t) -> Bool { lock.lock(); defer { lock.unlock() }; return pids.contains(pid) }
    }

    // MARK: Who a process is

    /// `pid` and its ancestors up to pid 1, nearest first, each read once by `read`; nil when the chain can't be
    /// followed there (a process in it ended, or it loops), when an ancestor started after its child, or when a
    /// child, read again after its parent, is another process or has another parent.
    static func chain(of pid: pid_t, reading read: (pid_t) -> Platform.Processes.Link?) -> [Platform.Processes.Link]? {
        guard let first = read(pid) else { return nil }
        var chain = [first]
        var seen: Set<pid_t> = [pid]
        var child = first
        while child.parent > 1 {
            guard seen.insert(child.parent).inserted, let parent = read(child.parent),
                  // Started after its child: not its parent, but a process given the parent's number since.
                  parent.startTicks <= child.startTicks,
                  // Still the same child under the same parent: not reparented between the two reads.
                  let again = read(child.pid), again.startTicks == child.startTicks, again.parent == child.parent else { return nil }
            chain.append(parent)
            child = parent
        }
        return child.parent == 1 ? chain : nil
    }

    /// Linux's `HostServer.session(of:)`: the live session (`holdsIdentity`) `pid` runs in, by id, its program matched
    /// in the chain by token, or else by its controlling terminal; nil for none. Branch code (see `BranchCode`) runs
    /// in none, as on the Mac. `read`: how a link is read (tests give a table); `note`: a line for the host's log.
    static func session(of pid: pid_t, among sessions: [HostedSession], reading read: (pid_t) -> Platform.Processes.Link?,
                        note: (String) -> Void) -> String? {
        guard pid > 1, let chain = chain(of: pid, reading: read) else { return nil }
        let live = sessions.filter(\.holdsIdentity)
        // Nearest first: the session found is the innermost one it runs in.
        for (index, link) in chain.enumerated() {
            guard let session = live.first(where: { $0.programToken.map(link.isProcess(of:)) == true }) else { continue }
            guard let runner = chain[..<index].first(where: { BranchCode.isRunner(pid: $0.pid) }) else { return session.id.uuidString }
            note("pid \(pid) runs branch code (under pid \(runner.pid), a merge's, audit's or init's command in session \(HostServer.short(session.id))): it's no session's")
            return nil
        }
        if let tty = chain[0].terminal, let session = live.first(where: { $0.info.tty == tty }) {
            guard let runner = chain.first(where: { BranchCode.isRunner(pid: $0.pid) }) else { return session.id.uuidString }
            note("pid \(pid) runs branch code (under pid \(runner.pid)) on session \(HostServer.short(session.id))'s terminal: it's no session's")
            return nil
        }
        return nil
    }
}
