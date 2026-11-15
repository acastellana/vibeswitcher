import Foundation

/// How `LaunchPreflight` looks for an agent's program on Linux (the engine plan's E4; the security document's S10): as
/// sessions now start (stage 2's Task 10a: `bash --noprofile --norc`, `Platform.Tools.sessionShellArguments`, with the
/// session's PATH, which is this process's in the tool server), never through a login shell. A login shell runs the
/// user's startup files (`~/.bashrc`, which any worker can edit), and a program found only through them would pass
/// the look and then fail in its session. Two hooks in `LaunchPreflight`: its default shell (`shell`), and its look
/// (`resolve`). The Mac: the login shell, as today (`resolve` answers nil and `LoginShellCommand.resolve` looks).
public enum SessionShellProbe {
    /// The shell `LaunchPreflight` looks through by default: the session's on Linux (`/bin/bash`, which every session
    /// starts in), the user's login shell on the Mac.
    public static var shell: String { enabled ? "/bin/bash" : LoginShellVariable.userShell }

    /// Linux: a session's shell is never a login shell.
    static var enabled: Bool { !Platform.CodeIdentity.isAvailable }

    /// Linux (`enabled`): whether `name` is a command for `shell` started as a session's is (`--noprofile --norc -c`,
    /// no startup file read, this process's environment), in a session of its own. Nil on the Mac.
    static func resolve(_ name: String, shell: String, timeout: TimeInterval, enabled: Bool = SessionShellProbe.enabled) -> LoginShellCommand.Outcome? {
        guard enabled else { return nil }
        guard LoginShellCommand.validName(name) else { return .missing }
        let argv = [shell, "--noprofile", "--norc", "-c", LoginShellCommand.command, "bash", name]
        let run = Shell.run(executable: argv[0], args: Array(argv.dropFirst()), in: NSHomeDirectory(), timeout: timeout, grace: 1,
                            ownSession: true)
        if run.timedOut || run.cancelled { return .unknown }
        return LoginShellCommand.outcome(status: run.status, output: run.output)
    }
}
