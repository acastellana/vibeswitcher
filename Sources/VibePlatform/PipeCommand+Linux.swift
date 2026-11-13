#if os(Linux)
import Foundation

// Linux's piped command: what the Mac's does with a kqueue, with `poll` on the two pipes, on a descriptor of the
// command (`pidfd_open`: ready when it has exited) and on a pipe that a stop signal writes to. Three things Linux
// lacks are made up for here:
// - A pipe can't be told not to raise SIGPIPE (the Mac's F_SETNOSIGPIPE): the signal is held back from this thread
//   for the length of the command, and one a write did raise is taken off before it is let through again.
// - Nothing watches a signal go by (the Mac's EVFILT_SIGNAL), and one this process ignores is dropped as it is sent:
//   the stop signals are handled for as long as a command runs (`StopSignalNotes`).
// - A process before Linux 5.3 can't be opened: the command is then asked whether it has ended, 20 times a second.
extension Platform {
    static func runPiped(_ command: String, input: Data, patience: TimeInterval, stopSignals: [Int32]) -> Data {
        runPiped(command, input: input, patience: patience, stopSignals: stopSignals, opening: { vibe_pidfd_open($0, 0) })
    }

    /// `open`: `pidfd_open`, or what stands in for it in a test.
    static func runPiped(_ command: String, input: Data, patience: TimeInterval, stopSignals: [Int32],
                         opening open: (pid_t) -> Int32) -> Data {
        var toChild: [Int32] = [-1, -1], fromChild: [Int32] = [-1, -1]
        // Close-on-exec from their making: this process's ends reach no other child it starts meanwhile.
        guard Sys.pipeClosedOnExec(&toChild) == 0 else { return Data() }
        guard Sys.pipeClosedOnExec(&fromChild) == 0 else {
            toChild.forEach { close($0) }
            return Data()
        }
        var spawn = Spawn(executable: "/bin/sh", arguments: ["/bin/sh", "-c", command])
        spawn.stdin = .descriptor(toChild[0])
        spawn.stdout = .descriptor(fromChild[1])
        spawn.stderr = .path("/dev/null", flags: O_WRONLY)
        // A process group of its own: stopping it stops the whole of it (a pipeline's every program).
        spawn.group = .ownGroup
        spawn.defaults = .only(stopSignals + [SIGPIPE])
        // Claude Code stopping this status line (TERM, then KILL about 2 s later): the command is stopped with it,
        // never left running. Listened for from before it starts, and heard even while ignored (`--status-line`
        // ignores them).
        let notes = StopSignalNotes.shared.begin(stopSignals)
        defer { StopSignalNotes.shared.end(stopSignals) }
        let started = spawn.start()
        close(toChild[0])
        close(fromChild[1])
        var writer: Int32 = toChild[1]
        let reader = fromChild[0]
        guard case .success(let pid) = started else {
            close(writer)
            close(reader)
            return Data()
        }
        for fd in [writer, reader] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        func stopWriting() {
            guard writer >= 0 else { return }
            close(writer)
            writer = -1
        }
        var output = Data(), pending = input[...]
        // Ready once the command has exited, a zombie included. Without one, `collected` below asks instead.
        let exit = open(pid)
        var exited = false, ended = false, stopped = false
        var status: Int32 = 0
        /// Only without a descriptor of the command: whether it has exited, collecting it if so.
        var wasCollected = false
        func collected() -> Bool {
            while true {
                let found = waitpid(pid, &status, WNOHANG)
                if found < 0 && errno == EINTR { continue }
                // An error: no such child, which can't be waited for any longer either.
                if found != 0 { wasCollected = true }
                return found != 0
            }
        }
        if pending.isEmpty { stopWriting() }
        let deadline = Date().addingTimeInterval(patience)
        var chunk = [UInt8](repeating: 0, count: 65_536)
        withoutBrokenPipeSignal {
            while !(exited && ended), !stopped {
                let left = deadline.timeIntervalSinceNow
                guard left > 0 else { break }
                // A descriptor below 0 is passed over: the writer once the input is written, the reader at its end.
                var polled = [pollfd(fd: notes, events: Int16(POLLIN), revents: 0),
                              pollfd(fd: exited ? -1 : exit, events: Int16(POLLIN), revents: 0),
                              pollfd(fd: ended ? -1 : reader, events: Int16(POLLIN), revents: 0),
                              pollfd(fd: writer, events: Int16(POLLOUT), revents: 0)]
                // In milliseconds, rounded up: never a wait of no length while time is left.
                var wait = Int32(min((left * 1000).rounded(.up), Double(Int32.max)))
                if exit < 0 { wait = min(wait, 50) }
                let count = poll(&polled, nfds_t(polled.count), wait)
                if count < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if polled[0].revents != 0 { stopped = true }
                // Its exit first: nothing is written after it.
                if !exited, exit >= 0 ? polled[1].revents != 0 : collected() {
                    exited = true
                    stopWriting()
                }
                if polled[2].revents != 0 {
                    while true {
                        let read = Sys.read(reader, &chunk, chunk.count)
                        if read > 0 { output.append(contentsOf: chunk[0..<read]); continue }
                        if read < 0 && errno == EINTR { continue }
                        if read == 0 || errno != EAGAIN { ended = true }
                        break
                    }
                }
                if writer >= 0, polled[3].revents != 0 {
                    // Its reader gone (POLLERR): the command closed its stdin or exited.
                    if polled[3].revents & Int16(POLLOUT) == 0 || polled[3].revents & Int16(POLLERR) != 0 { stopWriting(); continue }
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
        }
        stopWriting()
        close(reader)
        if exit >= 0 { close(exit) }
        if !exited {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
        while !wasCollected, waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        return output
    }

    /// Runs `body` with SIGPIPE held back from this thread, so that a write in it to a pipe or socket whose reader
    /// has gone is an error (EPIPE) and nothing more, whatever this process does on SIGPIPE; then takes off the one
    /// such a write left waiting for this thread, and lets the signal through again as before. One that was
    /// already waiting before `body` is left as it was.
    static func withoutBrokenPipeSignal<Value>(_ body: () -> Value) -> Value {
        var broken = sigset_t(), before = sigset_t(), waiting = sigset_t()
        sigemptyset(&broken)
        sigaddset(&broken, SIGPIPE)
        sigemptyset(&waiting)
        sigpending(&waiting)
        let wasWaiting = sigismember(&waiting, SIGPIPE) == 1
        pthread_sigmask(SIG_BLOCK, &broken, &before)
        defer {
            if !wasWaiting {
                // Not waiting at all: EAGAIN when there is none.
                var none = timespec()
                while sigtimedwait(&broken, nil, &none) < 0 && errno == EINTR {}
            }
            pthread_sigmask(SIG_SETMASK, &before, nil)
        }
        return body()
    }
}

/// Where the handler below writes: the writing end of `StopSignalNotes`' pipe, never closed once made. A global, as
/// a signal handler can hold nothing.
private var stopNotesWriteEnd: Int32 = -1

/// What a stop signal does while a piped command runs: its number, one byte, into the pipe. Only what a signal
/// handler may call.
private let noteStopSignal: @convention(c) (Int32) -> Void = { number in
    let before = errno
    var byte = UInt8(truncatingIfNeeded: number)
    _ = write(stopNotesWriteEnd, &byte, 1)
    errno = before
}

/// The stop signals of the piped commands under way in this process. While a command runs, each of its stop signals
/// is handled (`noteStopSignal`) whatever it did before, an ignored one included: Linux has no way to watch a signal
/// go by, and drops one that is ignored as it is sent. When the last command that named a signal is over, the
/// signal does again what it did; and when no command is left, each signal that came is sent to this process once
/// more, so that it has its own effect too (nothing where ignored, the process's end where that is its default).
///
/// One pipe serves every command, and a byte in it stays until none is left: a stop signal stops them all,
/// whichever named it, and one that starts while others are still being stopped.
private final class StopSignalNotes: @unchecked Sendable {
    static let shared = StopSignalNotes()

    private let lock = NSLock()
    private var readEnd: Int32 = -1
    /// For each signal handled now: the commands that named it, and what it did before the first of them.
    private var listeners: [Int32: Int] = [:]
    private var before: [Int32: sigaction] = [:]

    /// A command starts: its signals are handled from here on. The descriptor that reads as ready once one came, or
    /// -1 when there is none to listen for (or no pipe to be had).
    func begin(_ signals: [Int32]) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard !signals.isEmpty else { return -1 }
        if readEnd < 0 {
            var ends: [Int32] = [-1, -1]
            guard Sys.pipeClosedOnExec(&ends) == 0 else { return -1 }
            for end in ends { _ = fcntl(end, F_SETFL, fcntl(end, F_GETFL) | O_NONBLOCK) }
            readEnd = ends[0]
            stopNotesWriteEnd = ends[1]
        }
        // What a handler still running wrote after the last command had gone.
        if listeners.isEmpty { _ = noted() }
        for number in Set(signals) {
            if let count = listeners[number] {
                listeners[number] = count + 1
                continue
            }
            var action = sigaction(), old = sigaction()
            #if canImport(Glibc)
            action.__sigaction_handler.sa_handler = noteStopSignal
            #else
            action.__sa_handler.sa_handler = noteStopSignal
            #endif
            // Another thread's call the signal lands in is taken up again, as while the signal was ignored.
            action.sa_flags = Int32(truncatingIfNeeded: SA_RESTART)
            sigemptyset(&action.sa_mask)
            // SIGKILL and SIGSTOP can't be handled: not listened for.
            guard sigaction(number, &action, &old) == 0 else { continue }
            before[number] = old
            listeners[number] = 1
        }
        return readEnd
    }

    /// A command is over.
    func end(_ signals: [Int32]) {
        lock.lock()
        for number in Set(signals) {
            guard let count = listeners[number] else { continue }
            if count > 1 {
                listeners[number] = count - 1
                continue
            }
            listeners[number] = nil
            if var old = before.removeValue(forKey: number) { sigaction(number, &old, nil) }
        }
        let came = listeners.isEmpty ? noted() : []
        lock.unlock()
        for number in came.sorted() { kill(getpid(), number) }
    }

    /// Empties the pipe: the signals that came. Under `lock`.
    private func noted() -> Set<Int32> {
        var came: Set<Int32> = []
        var bytes = [UInt8](repeating: 0, count: 64)
        while readEnd >= 0 {
            let count = read(readEnd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            came.formUnion(bytes[0..<count].map { Int32($0) })
        }
        return came
    }
}
#endif
