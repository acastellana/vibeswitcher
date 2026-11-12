#if canImport(Darwin)
// The Mac's posix_spawn with Apple's additions, as each caller had them before this file: every descriptor closed
// but the ones named (POSIX_SPAWN_CLOEXEC_DEFAULT, addinherit_np), and a spawn in place of this process
// (POSIX_SPAWN_SETEXEC).
extension Platform.Spawn {
    /// Starts the program as a child of this process: its pid, or posix_spawn's error (ENOENT for a program that
    /// isn't there).
    public func start() -> Result<pid_t, Platform.Errno> {
        var pid: pid_t = 0
        let code = posixSpawn(&pid, replacing: false)
        return code == 0 ? .success(pid) : .failure(Platform.Errno(code: code))
    }

    /// Runs the program in place of this process, which keeps its pid: returns only when that failed, with the
    /// error and with this process as it was.
    public func replaceProcess() -> Int32 {
        // An in-place exec refuses to hand on a descriptor marked close-on-exec (EBADF): unmark the ones it keeps
        // (everything else still closes), and mark them again if it fails.
        let marked = (keep ?? []).filter { fcntl($0, F_GETFD) & FD_CLOEXEC != 0 }
        marked.forEach { _ = fcntl($0, F_SETFD, 0) }
        defer { marked.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) } }
        var pid: pid_t = 0
        let code = posixSpawn(&pid, replacing: true)
        return code == 0 ? EINVAL : code
    }

    /// posix_spawn's own result. `replacing`: in place of this process, and then it returns only an error.
    private func posixSpawn(_ pid: inout pid_t, replacing: Bool) -> Int32 {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Default handling and an empty mask, as at a fresh start.
        var flags = POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        if replacing { flags |= POSIX_SPAWN_SETEXEC }
        // Nothing but what the actions below name: no other descriptor of this process leaks into it.
        if keep != nil { flags |= POSIX_SPAWN_CLOEXEC_DEFAULT }
        switch group {
        case .inherit: break
        case .ownGroup:
            flags |= POSIX_SPAWN_SETPGROUP
            // Group 0: its own, its id its pid.
            posix_spawnattr_setpgroup(&attributes, 0)
        case .ownSession: flags |= POSIX_SPAWN_SETSID
        }
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var toDefault: sigset_t = ~0
        if case .only(let numbers) = defaults {
            sigemptyset(&toDefault)
            for number in numbers { sigaddset(&toDefault, number) }
        }
        var none: sigset_t = 0
        posix_spawnattr_setsigdefault(&attributes, &toDefault)
        posix_spawnattr_setsigmask(&attributes, &none)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for (number, stdio) in [(STDIN_FILENO, self.stdin), (STDOUT_FILENO, self.stdout), (STDERR_FILENO, self.stderr)] {
            switch stdio {
            case .inherit: posix_spawn_file_actions_addinherit_np(&actions, number)
            case .descriptor(let descriptor): posix_spawn_file_actions_adddup2(&actions, descriptor, number)
            case .path(let path, let oflag, let mode): posix_spawn_file_actions_addopen(&actions, number, path, oflag, mode)
            case .sameAsStdin:
                if number == STDIN_FILENO {
                    posix_spawn_file_actions_addinherit_np(&actions, number)
                } else {
                    posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, number)
                }
            }
        }
        if let directory { posix_spawn_file_actions_addchdir_np(&actions, directory) }
        for descriptor in keep ?? [] { posix_spawn_file_actions_addinherit_np(&actions, descriptor) }

        let argv = Self.cStrings(arguments)
        defer { Self.release(argv) }
        guard let environment else { return posix_spawn(&pid, executable, &actions, &attributes, argv, environ) }
        let envp = Self.cStrings(environment)
        defer { Self.release(envp) }
        return posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
    }
}
#endif
