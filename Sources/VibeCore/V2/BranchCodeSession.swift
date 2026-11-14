import Foundation

/// A verifier's command in a POSIX session of its own, on Linux (the stage 2 plan's Task 10c; the security architecture
/// document's S4 and S10). `BranchCode.runPrefix` becomes the wrapper in place on the Mac, where the command is then in
/// the session Claude Code gave it. On Linux it starts the wrapper as a child instead, with `setsid` (`Platform.Spawn`'s
/// `.ownSession`), waits for it and ends as it did: in a new child `setsid` can't fail, where in the prefix itself it
/// would with `EPERM` whenever the prefix already leads its process group (a Bash tool's process may). So nothing the
/// branch's code starts has a controlling terminal: a process that escapes the wrapper's tree (a double fork) is no
/// session's to the host, not even by its terminal (`SessionIdentityChecks.session(of:among:reading:note:)`).
///
/// SIGTERM, SIGINT and SIGHUP the prefix gets are sent on to the command's process group, the wrapper's (one the prefix
/// ignores stays ignored, and isn't sent on, as it would stay ignored in the command run in place). A SIGKILL can't be:
/// whether Claude Code's timeout and interrupt still end the command is Task 12b's measurement.
///
/// Only the wrapped branch code (`BranchCode.isRunner`): the verifier's own tool server, which `prefix` runs as itself,
/// is still run in place, so a SIGKILL Claude Code sends it reaches it.
enum BranchCodeSession {
    /// The signals sent on to the command.
    static let passedOn: [Int32] = [SIGTERM, SIGINT, SIGHUP]

    /// Starts `argv` (its first word the program's path) with `environment`, in a session of its own, keeping this
    /// process's descriptors that aren't close-on-exec and the signals it ignores, as an exec in place would; waits
    /// for it; then gives its exit status, or ends this process by the same signal (`reraised`; another signal: 128 and
    /// its number, as a shell's `$?`). 126 when it can't be started, the error printed, as `runPrefix`'s failed exec.
    static func run(_ argv: [String], environment: [String: String]) -> Int32 {
        var spawn = Platform.Spawn(executable: argv[0], arguments: argv)
        spawn.environment = environment.map { "\($0.key)=\($0.value)" }
        // As an exec in place: every descriptor that isn't close-on-exec, and ignored signals still ignored.
        spawn.keep = nil
        spawn.defaults = .only([])
        spawn.group = .ownSession

        // Held until the child's group is known, so a signal in between is sent on, not lost.
        var held = sigset_t(), before = sigset_t()
        sigemptyset(&held)
        for number in passedOn { sigaddset(&held, number) }
        pthread_sigmask(SIG_BLOCK, &held, &before)
        for number in passedOn {
            let previous = signal(number, sendOn)
            if unsafeBitCast(previous, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self) { signal(number, SIG_IGN) }
        }
        let started = spawn.start()
        if case .success(let pid) = started { commandGroup = pid }
        pthread_sigmask(SIG_SETMASK, &before, nil)
        guard case .success(let pid) = started else {
            if case .failure(let error) = started {
                FileHandle.standardError.write(Data("vibeswitcher: couldn't run \(argv[0]): \(String(cString: strerror(error.code)))\n".utf8))
            }
            return 126
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            guard errno == EINTR else { return 126 }
        }
        let signalled = status & 0x7f
        guard signalled != 0 else { return (status >> 8) & 0xff }
        // Ended by a signal that ends a process without a core: so does this one. By another, 128 and its number.
        guard reraised.contains(signalled) else { return 128 + signalled }
        signal(signalled, SIG_DFL)
        var only = sigset_t()
        sigemptyset(&only)
        sigaddset(&only, signalled)
        pthread_sigmask(SIG_UNBLOCK, &only, nil)
        kill(getpid(), signalled)
        return 128 + signalled
    }

    /// The signals that, ending the command, end the prefix too: those whose default ends a process without a core.
    static let reraised: Set<Int32> = [SIGTERM, SIGINT, SIGHUP, SIGKILL, SIGPIPE, SIGALRM, SIGUSR1, SIGUSR2]
}

/// The command's process group, once started (0 before): read by `sendOn`, in a signal handler.
nonisolated(unsafe) private var commandGroup: pid_t = 0

/// Sends the signal on to the command's process group.
private func sendOn(_ number: Int32) {
    let group = commandGroup
    if group > 0 { kill(-group, number) }
}
