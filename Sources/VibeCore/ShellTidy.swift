import Foundation

/// Which shell sessions tidy themselves away. A shell an agent's Run card opened (`ShellAsk.spawnRequest`) stays open
/// as an interactive shell when its command ends, so every request left a session in the sidebar (2026-11-10: 11 idle
/// ones in 3 projects, up to a day old). Its launch line now says how the command ended (`report`, over OSC 7501: the
/// host keeps it as the session's `programStatus`, with when), and from that:
///
/// - the command exited 0, nobody typed into the shell since (`used`, the app's record), and the shell is back at its
///   prompt (`idle`) with nothing of the command's still running (`leftRunning`): the session is ended `idleFor` after
///   the command finished (`due`), and shows under Ended, its output still there to read;
/// - the command failed (non-zero, or killed): it stays until the user closes it, its row saying "command failed";
/// - the user typed into it after the command ended: it's theirs, and stays.
///
/// Only a session started by a Run card is ever looked at (`opened`): a shell from File › New Shell, a preset's, an
/// agent's session never are. The sidebar's Close Finished Shells… ends, after one confirmation, every Run-card shell
/// of a project that is back at its prompt (`finished`), failed, typed into or started before this record existed.
public enum ShellTidy {
    /// A finished shell nobody touched is ended this long after its command exited 0.
    public static let idleFor: TimeInterval = 10 * 60
    /// The `app` of the launch line's own reports: another program's status in the same shell isn't the command's end.
    public static let app = "vs-shell"

    /// How every Run-card shell's launch line starts: the command, given in a variable (`ShellAsk.spawnRequest`).
    static let launchLine = "eval \"$\(ShellAsk.commandVariable)\""

    /// What the launch line runs after the command: tells the terminal how it ended (OSC 7501, ended by BEL, which
    /// zsh's, bash's and fish's printf all write from this one spelling). `&&` and `||`, not `$?`: fish has none.
    static let report = "&& printf '\\033]7501;state=done:app=\(app)\\007' || printf '\\033]7501;state=error:app=\(app)\\007'"

    /// Started by a Run card: its launch line is `ShellAsk.spawnRequest`'s, this build's or an earlier one's (which
    /// said nothing of how the command ended).
    public static func opened(_ session: HostSession) -> Bool {
        session.agent == nil && session.command?.hasPrefix(launchLine) == true
    }

    public struct Ending: Equatable, Sendable {
        /// The command exited 0.
        public var ok: Bool
        public var at: Date
    }

    /// How a Run-card shell's command ended, and when; nil while it runs, when the session has ended, for a shell
    /// started before launch lines said so, and once another program in the shell reported a status of its own.
    public static func ending(of session: HostSession) -> Ending? {
        guard opened(session), let status = session.liveProgramStatus, status.app == app else { return nil }
        switch status.state {
        case .done: return Ending(ok: true, at: status.since)
        case .error: return Ending(ok: false, at: status.since)
        case .idle, .working, .blocked: return nil
        }
    }

    /// The sessions to end now: Run-card shells whose command exited 0 at least `after` ago, that nobody typed into
    /// since (`used`), that are back at their prompt (`idle`) and whose command left nothing running (`leftRunning`);
    /// the last two are asked only of those the rest holds for.
    public static func due(_ sessions: [HostSession], used: Set<UUID>, now: Date, after: TimeInterval = idleFor,
                           idle: (HostSession) -> Bool = ShellTidy.idle,
                           leftRunning: (HostSession, Ending) -> Bool = ShellTidy.leftRunning) -> [HostSession] {
        sessions.filter { session in
            guard let ending = ending(of: session), ending.ok, !used.contains(session.id) else { return false }
            return now.timeIntervalSince(ending.at) >= after && idle(session) && !leftRunning(session, ending)
        }
    }

    /// What Close Finished Shells… ends: the live Run-card shells that are back at their prompt, however their command
    /// ended and whether or not they were typed into (the confirmation lists them, and says that what they left
    /// running ends too). Never one whose command still runs: a launch line that says how the command ended hasn't
    /// yet (the shell holds its terminal meanwhile too, in a `wait` or a `read` of its own). A shell from before
    /// launch lines said so is taken by its prompt alone.
    public static func finished(_ sessions: [HostSession], idle: (HostSession) -> Bool = ShellTidy.idle) -> [HostSession] {
        sessions.filter { session in
            guard session.isLive, opened(session) else { return false }
            if session.command?.contains(report) == true, ending(of: session) == nil { return false }
            return idle(session)
        }
    }

    /// The command left something running that ending the session would end with it (a server put in the background, a
    /// tunnel or daemon that detached): a process of the session other than its shell (`SessionStrays`), started before
    /// the command ended. Such a shell is never ended by itself; Close Finished Shells… takes it, after asking. What
    /// started after the command's end in a shell nobody typed into is the shell's own (a prompt's helper).
    public static func leftRunning(_ session: HostSession, _ ending: Ending) -> Bool {
        let ended = UInt64(max(0, ending.at.timeIntervalSince1970) * 1_000_000)
        return SessionStrays.of(session: session.id, started: SessionStrays.descendants(of: session.childPID))
            .contains { $0.pid != session.childPID && $0.start < ended }
    }

    /// The session's shell is at its prompt: it holds its terminal's foreground (a program it runs in the foreground
    /// has a group of its own, which holds the terminal meanwhile). False when that can't be told.
    public static func idle(_ session: HostSession) -> Bool {
        session.isLive && ProcessTable.holdsForeground(pid: session.childPID) == true
    }

    /// The row's words for a Run-card shell whose command ended; nil for any other status.
    public static func words(for status: ProgramStatus) -> String? {
        guard status.app == app else { return nil }
        switch status.state {
        case .done: return "command finished"
        case .error: return "command failed"
        case .idle, .working, .blocked: return nil
        }
    }
}
