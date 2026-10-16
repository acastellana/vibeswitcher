import Darwin
import Foundation

/// Starts a program on a new pseudo-terminal: its own session with the terminal as controlling tty, like
/// `forkpty`, but with `posix_spawn` so the kernel hands it nothing of ours: no file descriptors but the
/// terminal (a big multithreaded process holds many, some guarded, and bash or dash touching one gets
/// killed), default signal handling and an empty signal mask (the host ignores SIGPIPE/SIGHUP and runs on
/// GCD threads that block most signals; inherited, a session would get no SIGWINCH and ignore SIGHUP).
enum PTYSpawn {
    static func spawn(executable: String, args: [String], env: [String], directory: String,
                      size: inout winsize) -> (pid: pid_t, masterFD: Int32)? {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { return nil }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(slave, F_SETFD, FD_CLOEXEC)
        defer { close(slave) }
        guard let name = ttyname(slave).map({ String(cString: $0) }) else {
            close(master)
            return nil
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                   | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var all: sigset_t = ~0
        var none: sigset_t = 0
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Opened by the new session leader, the terminal becomes its controlling terminal.
        posix_spawn_file_actions_addopen(&actions, 0, name, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory)

        let argv = cStrings(args)
        let envp = cStrings(env)
        defer {
            release(argv, count: args.count)
            release(envp, count: env.count)
        }
        var pid: pid_t = 0
        guard posix_spawn(&pid, executable, &actions, &attributes, argv, envp) == 0 else {
            close(master)
            return nil
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
