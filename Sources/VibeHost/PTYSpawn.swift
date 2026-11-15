import Foundation
import VibeCore

/// Starts a program on a new pseudo-terminal that is its controlling terminal, handing it nothing of ours.
///
/// The host never forks: a child forked from this multithreaded process was sometimes killed before it
/// could exec. Instead `posix_spawn` starts the launcher (`vibeswitcher-host --pty-exec PROGRAM ARGS…`)
/// in a new session with the terminal as its only descriptors, default signal handling and an empty mask
/// (the host ignores SIGPIPE/SIGHUP and runs on GCD threads that block most signals). The launcher, a
/// fresh single-threaded process, makes the terminal its controlling terminal (macOS needs an explicit
/// TIOCSCTTY) and execs the program, which keeps its process id.
public enum PTYSpawn {
    /// What the launcher does with `--pty-exec`; call it first thing in its `main`.
    public static func execIfLaunched(_ arguments: [String]) {
        guard arguments.count > 2, arguments[1] == "--pty-exec" else { return }
        // On Linux started from the host's sealed copy: closed first, so the program never holds it (see V2/HostImages.swift).
        Platform.ProcessSelf.closeInheritedImage()
        // Its terminal made its controlling terminal; on Linux, its own or it exits 127 (see `SessionIdentityChecks`).
        let program = SessionIdentityChecks.takeTerminal(Array(arguments[2...]))
        // On Linux dumpable again, and its oom_score_adj raised for the program (see V2/HostImages.swift).
        HostImages.beforeProgram()
        let argv = program.map { strdup($0) } + [nil]
        execv(program[0], argv)
        // On the session's terminal, so its window says which program wasn't there (the shell named by $SHELL, say)
        // rather than ending with nothing on it.
        let said = "VibeSwitcher: " + LaunchPreflight.couldntStart(program[0], code: errno) + "\r\n"
        _ = said.withCString { write(2, $0, strlen($0)) }
        _exit(127)
    }

    /// `failure`: posix_spawn's errno when it couldn't start the launcher (0 when the terminal couldn't be made).
    /// `launcherFlags`: before the program, for the launcher (`SessionIdentityChecks.launcherFlags`).
    static func spawn(launcher: String, executable: String, args: [String], env: [String], directory: String,
                      size: inout winsize, failure: inout Int32, launcherFlags: [String] = []) -> (pid: pid_t, masterFD: Int32)? {
        // Both ends close-on-exec (from their making on Linux), the slave's path named from the master: see
        // `Platform.Terminals.open`.
        guard case .success(let terminal) = Platform.Terminals.open(rows: size.ws_row, cols: size.ws_col) else { return nil }
        let master = terminal.master
        // Held open until the program has opened the terminal (posix_spawn returns once it has): macOS clears a
        // terminal's window size when its last slave descriptor closes, and a program that started on a 0×0 terminal
        // and never got a resize (no view attached) drew nothing: Codex's TUI (task codex-s-tui-renders).
        defer { close(terminal.slave) }
        // On Linux the launchers' own sealed copy, never the parsers' (see V2/HostImages.swift).
        let launcher = HostImages.forSessions(launcher)

        // In a session of its own, the terminal its only descriptors (opened by its path, so the launcher's own
        // `makeControlling` takes it), with default signals and an empty mask.
        var spawn = Platform.Spawn(executable: launcher, arguments: [launcher, "--pty-exec"] + launcherFlags + [executable] + args.dropFirst())
        spawn.stdin = .path(terminal.devicePath, flags: Platform.Terminals.launcherOpenFlags)
        spawn.stdout = .sameAsStdin
        spawn.stderr = .sameAsStdin
        spawn.group = .ownSession
        spawn.directory = directory
        // On Linux the launcher is the host's sealed copy: kept, and named to it (see V2/HostImages.swift).
        let image = HostImages.launching(launcher, environment: env)
        spawn.environment = image.environment
        spawn.keep = image.keep
        switch spawn.start() {
        case .success(let pid):
            return (pid, master)
        case .failure(let error):
            failure = error.code
            close(master)
            return nil
        }
    }
}
