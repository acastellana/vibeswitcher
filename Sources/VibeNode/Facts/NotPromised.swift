import Foundation

/// The security architecture document's S11, "What plain mode doesn't promise on Linux", in short: what `start`
/// prints once (until a `not-promised-ack` journal entry the voice rule passes exists) and `status`'s plain-mode line
/// names. The document is the list; these lines are its items' first words, in its order, numbered as it numbers them.
public enum NotPromised {
    /// The list's heading as printed.
    public static let heading = "What plain mode doesn't promise on Linux (the security architecture document's S11), until the sandbox:"

    /// Each item, numbered as S11 numbers it.
    public static let items: [String] = [
        "While WSL interop is on, any process can reach root, and every lock is void.",
        "While /mnt/c is mounted, a worker can change what the next WSL boot or Windows login runs.",
        "A worker can restart the host into files it edited (the unit, environment.d, the install, build-info).",
        "The host's start by systemd runs a readable file: a worker can ptrace it before its first statement.",
        "A worker can put its own socket at the host's path until the host binds it again.",
        "A worker can act as any session, the lead and the verifiers included (ptrace, same uid).",
        "Routes into a role without ptrace: prompt files, the lead's accepted messages, its launch files.",
        "A worker can replace what every agent runs: the hook, the agents' settings, claude's versions.",
        "A worker can move the lead's base branch through the shared .git of the worktrees.",
        "Branch code (merges' tests, audits, init_command) runs as the user, unconfined.",
        "A terminal query written to a session's terminal makes the host type its reply there.",
        "A worker turns the lead or a verifier with text it writes.",
        "The user's voice passes for anything that drives the user's own shell, command line or Claude Code.",
        "The user's own processes can act for a worker: PATH, aliases, startup files.",
        "A worker can replace the command line's binary in the install folder.",
        "Another session's terminal is the user's to open, read and write; with WSLg on, the display too.",
        "Text the user reads (questions, reports, commit messages) is the workers' and the lead's to word.",
        "Every file of the user is readable: the agents' logins, gh's token, the keys.",
        "Sockets under /run/user/<uid>: gpg-agent, the session bus, WSLg.",
        "The environment and command line of the user's dumpable processes are readable.",
        "Whoever holds a connection's descriptor reads its replies.",
        "With mirrored networking, every Windows-side localhost service is reachable.",
        "A worker can make code run later as the user: crontab, user units, autostart, startup files.",
        "A session can run its own scratch host, with no allow-list and the test flags.",
        "A worker can stop or kill the host, the server and the parsers.",
        "A worker can fill the host's client slots.",
        "A host restart erases the team's state and asks for config accept and base accept again.",
        "The host's and the tool servers' logs aren't yet checked for tokens and terminal text.",
        "Steer delivery records are outside the seal: a copied .user seal is delivered once within 15 minutes.",
        "A stale handover state file of an older build may be left.",
        "A paired browser's key isn't yet kept from being read out of it.",
    ]

    /// The list as `start` prints it: the heading, then `N. item` a line.
    public static var text: String {
        ([heading] + items.enumerated().map { "\($0.offset + 1). \($0.element)" }).joined(separator: "\n")
    }

    /// The journal event that records the user's acknowledgment of the list.
    public static let ackEvent = "not-promised-ack"
}
