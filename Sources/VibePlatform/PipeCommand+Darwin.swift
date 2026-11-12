#if canImport(Darwin)
import Foundation

// The Mac's: AccountUsage's `runCommand`, its whole body as it was, with the stop signals now the caller's to name.
extension Platform {
    static func runPiped(_ command: String, input: Data, patience: TimeInterval, stopSignals: [Int32]) -> Data {
        var toChild: [Int32] = [-1, -1], fromChild: [Int32] = [-1, -1]
        guard pipe(&toChild) == 0 else { return Data() }
        guard pipe(&fromChild) == 0 else {
            toChild.forEach { close($0) }
            return Data()
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, toChild[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, fromChild[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t(), mask = sigset_t()
        sigemptyset(&defaults)
        for signal in stopSignals + [SIGPIPE] { sigaddset(&defaults, signal) }
        sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &mask)
        // A process group of its own: stopping it stops the whole of it (a pipeline's every program).
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP))
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(command), nil]
        defer { argv.forEach { free($0) } }
        let queue = kqueue()
        func watch(_ ident: Int32, _ filter: Int32, fflags: UInt32 = 0, flags: Int32 = EV_ADD) -> Bool {
            var change = kevent(ident: UInt(ident), filter: Int16(filter), flags: UInt16(flags), fflags: fflags, data: 0, udata: nil)
            return kevent(queue, &change, 1, nil, 0, nil) == 0
        }
        // Claude Code stopping this status line (TERM, then KILL about 2 s later): the command is stopped with it, never
        // left running. Watched from before it starts, and heard even while ignored (`--status-line` ignores them).
        for signal in stopSignals { _ = watch(signal, EVFILT_SIGNAL) }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, environ)
        close(toChild[0])
        close(fromChild[1])
        var writer: Int32 = toChild[1]
        let reader = fromChild[0]
        guard spawned == 0 else {
            close(writer)
            close(reader)
            if queue >= 0 { close(queue) }
            return Data()
        }
        _ = fcntl(writer, F_SETNOSIGPIPE, 1)
        for fd in [writer, reader] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        func stopWriting() {
            guard writer >= 0 else { return }
            close(writer) // Its kevent goes with it.
            writer = -1
        }
        var output = Data(), pending = input[...]
        // A command that has already exited (a zombie) can't be watched: it has exited.
        var exited = queue < 0 || !watch(pid, EVFILT_PROC, fflags: UInt32(NOTE_EXIT))
        var ended = queue < 0 || !watch(reader, EVFILT_READ)
        if pending.isEmpty || exited || queue < 0 || !watch(writer, EVFILT_WRITE) { stopWriting() }
        var stopped = false
        let deadline = Date().addingTimeInterval(patience)
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while !(exited && ended), !stopped {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { break }
            var wait = timespec(tv_sec: Int(left), tv_nsec: Int((left - left.rounded(.down)) * 1e9))
            var events = Array(repeating: kevent(), count: 4)
            let count = kevent(queue, nil, 0, &events, Int32(events.count), &wait)
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            let fired = events.prefix(Int(count))
            if fired.contains(where: { Int32($0.filter) == EVFILT_SIGNAL }) { stopped = true }
            // Its exit first: nothing is written after it.
            if fired.contains(where: { Int32($0.filter) == EVFILT_PROC }) {
                exited = true
                stopWriting()
            }
            for event in fired where Int32(event.filter) == EVFILT_READ {
                while true {
                    let read = Sys.read(reader, &chunk, chunk.count)
                    if read > 0 { output.append(contentsOf: chunk[0..<read]); continue }
                    if read < 0 && errno == EINTR { continue }
                    if read == 0 || errno != EAGAIN {
                        ended = true
                        _ = watch(reader, EVFILT_READ, flags: EV_DELETE)
                    }
                    break
                }
            }
            for event in fired where Int32(event.filter) == EVFILT_WRITE && writer >= 0 {
                // Its reader gone (EV_EOF): the command closed its stdin or exited.
                if event.flags & UInt16(EV_EOF) != 0 { stopWriting(); continue }
                while !pending.isEmpty {
                    let wrote = pending.withUnsafeBytes { Sys.write(writer, $0.baseAddress, $0.count) }
                    if wrote > 0 { pending = pending.dropFirst(wrote); continue }
                    if wrote < 0 && errno == EINTR { continue }
                    if wrote < 0 && errno == EAGAIN { break }
                    pending = pending.prefix(0) // EPIPE, or anything else: the rest isn't wanted.
                }
                if pending.isEmpty { stopWriting() }
            }
        }
        stopWriting()
        close(reader)
        if queue >= 0 { close(queue) }
        if !exited {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        return output
    }
}
#endif
