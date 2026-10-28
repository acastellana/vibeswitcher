import Darwin
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
        _ = ioctl(0, TIOCSCTTY, 0)
        let program = Array(arguments[2...])
        let argv = program.map { strdup($0) } + [nil]
        execv(program[0], argv)
        // On the session's terminal, so its window says which program wasn't there (the shell named by $SHELL, say)
        // rather than ending with nothing on it.
        let said = "VibeSwitcher: " + LaunchPreflight.couldntStart(program[0], code: errno) + "\r\n"
        _ = said.withCString { write(2, $0, strlen($0)) }
        _exit(127)
    }

    /// `failure`: posix_spawn's errno when it couldn't start the launcher (0 when the terminal couldn't be made).
    static func spawn(launcher: String, executable: String, args: [String], env: [String], directory: String,
                      size: inout winsize, failure: inout Int32) -> (pid: pid_t, masterFD: Int32)? {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { return nil }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        // From the master (the kernel names it): ttyname's buffer is shared between threads, and on a busy Mac it
        // can find no name yet for a terminal just made.
        var buffer = [CChar](repeating: 0, count: 128)
        let name = ptsname_r(master, &buffer, buffer.count) == 0 ? String(cString: buffer) : nil
        close(slave)
        guard let name else {
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
        posix_spawn_file_actions_addopen(&actions, 0, name, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory)

        let launch = [launcher, "--pty-exec", executable] + args.dropFirst()
        let argv = cStrings(launch)
        let envp = cStrings(env)
        defer {
            release(argv, count: launch.count)
            release(envp, count: env.count)
        }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, launcher, &actions, &attributes, argv, envp)
        guard code == 0 else {
            failure = code
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
