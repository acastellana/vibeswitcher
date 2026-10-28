import Foundation

/// One variable of the user's login-shell environment, as a session sees it: the host starts sessions as
/// `$SHELL -l -i` (`HostedSession.arguments`), which reads `.zprofile` and `.zshrc`, so a variable exported there (the
/// ElevenLabs key) is in every session but not in an app launched from Finder. Read the same way: `$SHELL -l -i -c`,
/// its stdin /dev/null, `printenv NAME` with the name an argument of its own (never in the command's text), and only
/// that name's value kept: no other variable of the shell reaches the app. Blocks; never on the main thread.
public enum LoginShellVariable {
    public enum Outcome: Equatable, Sendable {
        case found(String)
        /// The shell ran and the variable isn't set (or is empty).
        case unset
        /// The shell didn't finish in time (a .zshrc that waits on something): stopped with what it started.
        case timedOut
        /// The shell couldn't start, or printed nothing after the marker (a .zshrc that exits early).
        case failed
    }

    /// Printed just before the value: whatever the shell's startup files print (a banner, a prompt) comes before it.
    static let marker = "VIBESWITCHER-LOGIN-SHELL-VALUE:"
    /// The command the shell runs; the name is `$1`.
    static let command = "printf '%s' '\(marker)'; exec /usr/bin/printenv \"$1\""

    public static var userShell: String {
        ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    }

    /// `$SHELL -l -i -c <command> <shell> NAME`: the session's arguments, then `$0` and `$1`.
    public static func arguments(shell: String, name: String) -> [String] {
        [shell, "-l", "-i", "-c", command, (shell as NSString).lastPathComponent, name]
    }

    public static func read(_ name: String, shell: String = userShell, timeout: TimeInterval = 5) -> Outcome {
        guard LaunchPlan.validEnvName(name) else { return .unset }
        let argv = arguments(shell: shell, name: name)
        let run = Shell.run(executable: argv[0], args: Array(argv.dropFirst()), in: NSHomeDirectory(), timeout: timeout, grace: 1,
                            ownSession: true)
        if run.timedOut || run.cancelled { return .timedOut }
        return outcome(status: run.status, output: run.output)
    }

    /// What follows the marker: printenv's value (exit 0), unset (exit 1 after the marker), else failed.
    static func outcome(status: Int32, output: String) -> Outcome {
        guard let range = output.range(of: marker) else { return .failed }
        let value = output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0 else { return status == 1 ? .unset : .failed }
        return value.isEmpty ? .unset : .found(value)
    }
}

/// Where the login shell finds a command, as a session's would: `$SHELL -l -i -c`, its stdin /dev/null, `command -v NAME`
/// with the name an argument of its own (never in the command's text). An alias or a function a .zshrc defines counts as
/// found, as the session's shell would run it. Blocks; never on the main thread.
public enum LoginShellCommand {
    public enum Outcome: Equatable, Sendable {
        /// What `command -v` printed: a path, or an alias's or a function's name.
        case found(String)
        /// The shell ran and has no such command.
        case missing
        /// The shell didn't finish in time, couldn't start, or printed nothing after the marker: not known.
        case unknown
    }

    static let marker = "VIBESWITCHER-LOGIN-SHELL-COMMAND:"
    static let command = "printf '%s' '\(marker)'; command -v \"$1\""

    /// `$SHELL -l -i -c <command> <shell> NAME`.
    public static func arguments(shell: String, name: String) -> [String] {
        [shell, "-l", "-i", "-c", command, (shell as NSString).lastPathComponent, name]
    }

    /// A program's name as a command line has it: no space, quote or control character, and not an option.
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-")
            && !name.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) || "'\"`$\\;&|<>()".unicodeScalars.contains($0) }
    }

    public static func resolve(_ name: String, shell: String = LoginShellVariable.userShell, timeout: TimeInterval = 10) -> Outcome {
        guard validName(name) else { return .missing }
        let argv = arguments(shell: shell, name: name)
        // In a session of its own: an interactive shell would take the caller's terminal, and the tool server has the
        // lead's (`Shell.run`'s ownSession).
        let run = Shell.run(executable: argv[0], args: Array(argv.dropFirst()), in: NSHomeDirectory(), timeout: timeout, grace: 1,
                            ownSession: true)
        if run.timedOut || run.cancelled { return .unknown }
        return outcome(status: run.status, output: run.output)
    }

    /// What follows the marker: `command -v`'s answer (exit 0), missing (exit 1 after the marker), else unknown (a shell
    /// with no `command -v` says nothing of the program).
    static func outcome(status: Int32, output: String) -> Outcome {
        guard let range = output.range(of: marker, options: .backwards) else { return .unknown }
        let found = output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0 else { return status == 1 ? .missing : .unknown }
        guard !found.isEmpty else { return .missing }
        return .found(found.components(separatedBy: .newlines).first ?? found)
    }
}
