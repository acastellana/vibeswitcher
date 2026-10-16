import Darwin

/// `forkpty` + `execve`, like SwiftTerm's helper, except the program starts with default signal handling.
/// The host ignores SIGPIPE and SIGHUP and runs on GCD threads that block most signals; without the reset a
/// session would inherit both (no SIGWINCH on resize, and ending it with SIGHUP wouldn't work).
enum PTYFork {
    static func spawn(executable: String, args: [String], env: [String], directory: String,
                      size: inout winsize) -> (pid: pid_t, masterFD: Int32)? {
        // Everything the child touches is prepared before the fork: after it, only async-signal-safe calls.
        let argv = cStrings(args)
        let envp = cStrings(env)
        let path = strdup(executable)
        let folder = strdup(directory)
        defer {
            release(argv, count: args.count)
            release(envp, count: env.count)
            free(path)
            free(folder)
        }
        var master: Int32 = 0
        let pid = forkpty(&master, nil, nil, &size)
        if pid < 0 { return nil }
        if pid == 0 {
            for number in 1..<32 { _ = signal(Int32(number), SIG_DFL) }
            var none: sigset_t = 0
            sigprocmask(SIG_SETMASK, &none, nil)
            _ = chdir(folder)
            execve(path, argv, envp)
            _exit(127)
        }
        return (pid, master)
    }

    private static func cStrings(_ strings: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let array = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() { array[index] = strdup(string) }
        array[strings.count] = nil
        return array
    }

    private static func release(_ array: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, count: Int) {
        for index in 0..<count { free(array[index]) }
        array.deallocate()
    }
}
