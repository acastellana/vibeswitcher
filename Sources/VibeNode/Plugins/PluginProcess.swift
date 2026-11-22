import Foundation
import VibeCore

/// An external plugin's program as the server runs it (the definition's "The process" and "The protocol"): a child
/// started from a sealed copy of the program checked against the vault's record, with no terminal (its own session),
/// its own process group, a clean environment (PATH of root's folders, HOME its private working folder, LANG) and that
/// folder as its working one; standard input and output the protocol's two pipes, standard error to the node's log
/// (inert, capped). Protocol v1: JSON, one object a line, 256 KiB a line at most; the node asks, the plugin answers with
/// the asker's `id`, one call at a time, 10 s each. A line too long, an answer to no question or out of order, a line
/// that isn't an object, a call unanswered in time, or the program ending: a breach, which ends it (its whole group)
/// and fails every call waiting. Its answers are data: whoever calls checks each one's shape.
///
/// Its descriptors (automated review 1): each reader owns its pipe and closes it when it ends, and the writer owns the
/// input; none is closed under a thread still using it. Ending closes the write end of one cancel pipe, which wakes every
/// reader and the writer from `poll` (a child of the plugin that kept the pipes open can't hold them); the cancel pipe's
/// read end is closed once all three have let go. Writes are non-blocking and off the process's queue, so a program
/// that doesn't read its input never holds the queue (its call times out). Reaping is bounded.
final class PluginProcess: @unchecked Sendable {
    typealias Message = [String: Any]

    struct Breach: Error, CustomStringConvertible {
        var description: String
    }

    static let lineBytesAtMost = 256 * 1024
    static let callTimeout: TimeInterval = 10
    static let stderrKept = 64 * 1024

    let id: String
    private let queue: DispatchQueue
    private let note: (String) -> Void
    private var pid: pid_t = 0
    private var input: Int32 = -1
    private var output: Int32 = -1
    private var errors: Int32 = -1
    /// The cancel pipe: closing `cancel[1]` ends the readers and the writer.
    private var cancel: [Int32] = [-1, -1]
    private let users = DispatchGroup()
    private let writes: DispatchQueue
    /// The numbers its two readers' descriptors had (a test's look at their reuse).
    private(set) var readEnds: [Int32] = []
    private var nextID = 1
    private var waiting: [(id: Int, line: Data, then: (Result<Message, Breach>) -> Void)] = []
    private var inFlight: (id: Int, then: (Result<Message, Breach>) -> Void, timer: DispatchWorkItem)?
    private(set) var ended: String?
    /// Told once, on the process's queue, when it breached or ended (not when stopped).
    var onEnd: ((String) -> Void)?

    init(id: String, note: @escaping (String) -> Void) {
        self.id = id
        self.note = note
        queue = DispatchQueue(label: "vibenode.plugin.\(id)")
        writes = DispatchQueue(label: "vibenode.plugin.\(id).writes")
    }

    /// Starts `copy` (its sealed copy) in `work`. Blocks briefly.
    func start(copy: Platform.ProcessSelf.SealedCopy, work: URL) -> Result<Void, PluginRefusal> {
        var toChild: [Int32] = [-1, -1], fromChild: [Int32] = [-1, -1], errChild: [Int32] = [-1, -1], cancel: [Int32] = [-1, -1]
        // Close-on-exec from their making: the spawn gives the child its ends as its standard ones.
        guard Sys.pipeClosedOnExec(&toChild) == 0, Sys.pipeClosedOnExec(&fromChild) == 0, Sys.pipeClosedOnExec(&errChild) == 0,
              Sys.pipeClosedOnExec(&cancel) == 0 else {
            for fd in toChild + fromChild + errChild + cancel where fd >= 0 { Sys.close(fd) }
            return .failure(PluginRefusal("no pipes (errno \(errno))"))
        }
        // A write to a program that has gone is an error for the write, not the server's end.
        signal(SIGPIPE, SIG_IGN)
        var spawn = Platform.Spawn(executable: copy.path, arguments: [copy.path])
        spawn.environment = ["PATH=/usr/bin:/bin", "HOME=\(work.path)", "LANG=C.UTF-8"]
        spawn.directory = work.path
        spawn.stdin = .descriptor(toChild[0])
        spawn.stdout = .descriptor(fromChild[1])
        spawn.stderr = .descriptor(errChild[1])
        spawn.keep = [copy.fd]
        spawn.group = .ownSession
        let started = spawn.start()
        for fd in [toChild[0], fromChild[1], errChild[1]] { Sys.close(fd) }
        switch started {
        case .failure(let error):
            for fd in [toChild[1], fromChild[0], errChild[0]] + cancel { Sys.close(fd) }
            return .failure(PluginRefusal("its program didn't start (errno \(error.code))"))
        case .success(let child):
            _ = fcntl(toChild[1], F_SETFL, fcntl(toChild[1], F_GETFL) | O_NONBLOCK)
            queue.sync {
                pid = child
                input = toChild[1]
                output = fromChild[0]
                errors = errChild[0]
                readEnds = [fromChild[0], errChild[0]]
                self.cancel = cancel
            }
            // The writer is a user of the cancel pipe from now until it lets the input go (`kill`).
            users.enter()
            read(fromChild[0], lines: true, cancel: cancel[0])
            read(errChild[0], lines: false, cancel: cancel[0])
            users.notify(queue: .global()) { Sys.close(cancel[0]) }
            return .success(())
        }
    }

    /// Asks `call` with `fields` (`id` and `call` are the node's); `then` on the process's queue with the answer, its
    /// `id` taken off, or the breach.
    func call(_ call: String, _ fields: Message = [:], then: @escaping (Result<Message, Breach>) -> Void) {
        queue.async { [self] in
            if let ended { return then(.failure(Breach(description: ended))) }
            let id = nextID
            nextID += 1
            var message = fields
            message["id"] = id
            message["call"] = call
            guard let line = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]), line.count < Self.lineBytesAtMost else {
                return then(.failure(Breach(description: "the node's \(call) didn't fit a line")))
            }
            waiting.append((id, line + Data("\n".utf8), then))
            sendNext()
        }
    }

    private func sendNext() {
        guard inFlight == nil, ended == nil, !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        let timer = DispatchWorkItem { [weak self] in self?.breach("it didn't answer within \(Int(Self.callTimeout)) s") }
        inFlight = (next.id, next.then, timer)
        queue.asyncAfter(deadline: .now() + Self.callTimeout, execute: timer)
        let (input, cancel) = (self.input, self.cancel[0])
        writes.async { [weak self] in
            guard !Self.write(next.line, to: input, cancel: cancel) else { return }
            self?.queue.async { self?.breach("its input closed") }
        }
    }

    /// Writes `line` whole to the non-blocking `fd`, waiting in `poll` while its pipe is full; false when the pipe
    /// closed, or the cancel pipe did (the program ending). On the writer's queue.
    private static func write(_ line: Data, to fd: Int32, cancel: Int32) -> Bool {
        guard fd >= 0 else { return false }
        var sent = 0
        return line.withUnsafeBytes { raw in
            while sent < raw.count {
                let count = Darwin_or_Glibc_write(fd, raw.baseAddress! + sent, raw.count - sent)
                if count > 0 { sent += count; continue }
                guard count < 0, errno == EINTR || errno == EAGAIN else { return false }
                if errno == EAGAIN, !wait(for: fd, events: Int16(POLLOUT), cancel: cancel) { return false }
            }
            return true
        }
    }

    /// Waits until `fd` is ready for `events`: false when the cancel pipe closed (or poll failed).
    private static func wait(for fd: Int32, events: Int16, cancel: Int32) -> Bool {
        var polled = [pollfd(fd: fd, events: events, revents: 0), pollfd(fd: cancel, events: Int16(POLLIN), revents: 0)]
        while true {
            let count = poll(&polled, nfds_t(polled.count), -1)
            if count < 0, errno == EINTR { continue }
            guard count > 0, polled[1].revents == 0 else { return false }
            if polled[0].revents != 0 { return true }
        }
    }

    /// A line from the program: its answer to the call in flight, or a breach.
    private func heard(_ line: Data) {
        guard ended == nil else { return }
        guard let message = try? JSONSerialization.jsonObject(with: line) as? Message else { return breach("it wrote a line that isn't a JSON object") }
        guard let flight = inFlight, let id = message["id"] as? Int, id == flight.id else {
            return breach("it answered no question, or out of order")
        }
        flight.timer.cancel()
        inFlight = nil
        var answer = message
        answer["id"] = nil
        flight.then(.success(answer))
        sendNext()
    }

    /// Reads `fd` on a thread of its own, which owns it and closes it when it ends (its end of file, an error, a breach,
    /// or the cancel pipe closing): lines of the protocol, or the log's (inert, capped).
    private func read(_ fd: Int32, lines: Bool, cancel: Int32) {
        users.enter()
        let users = self.users
        let thread = Thread { [weak self] in
            defer {
                Sys.close(fd)
                users.leave()
            }
            var buffer = Data()
            var logged = 0
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                guard Self.wait(for: fd, events: Int16(POLLIN), cancel: cancel) else { return }
                let count = chunk.withUnsafeMutableBytes { Darwin_or_Glibc_read(fd, $0.baseAddress!, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                guard let self else { return }
                if lines {
                    buffer.append(contentsOf: chunk[0..<count])
                    while let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                        let line = buffer[buffer.startIndex..<end]
                        buffer = Data(buffer[(end + 1)...])
                        if line.count > Self.lineBytesAtMost { self.queue.async { self.breach("a line over 256 KiB") }; return }
                        let copy = Data(line)
                        self.queue.async { self.heard(copy) }
                    }
                    if buffer.count > Self.lineBytesAtMost { self.queue.async { self.breach("a line over 256 KiB") }; return }
                } else if logged < Self.stderrKept {
                    let text = String(decoding: chunk[0..<min(count, Self.stderrKept - logged)], as: UTF8.self)
                    logged += count
                    for line in text.split(separator: "\n") { self.note("plugin \(self.id) says: \(ConfigSeal.inert(String(line), limit: 300))") }
                }
            }
            if lines, let self { self.queue.async { self.breach("its program ended") } }
        }
        thread.name = "plugin-\(id)-\(lines ? "out" : "err")"
        thread.start()
    }

    /// Ends it for `why`: its group signalled, every call failed, `onEnd` told once.
    private func breach(_ why: String) {
        guard ended == nil else { return }
        ended = why
        note("plugin \(id) ended: \(why)")
        kill()
        let failed = (inFlight.map { [$0.then] } ?? []) + waiting.map(\.then)
        inFlight?.timer.cancel()
        inFlight = nil
        waiting = []
        for then in failed { then(.failure(Breach(description: why))) }
        onEnd?(why)
    }

    /// Stops it (off, removed, the server stopping): nothing waiting is answered, `onEnd` isn't told.
    func stop() {
        queue.sync {
            guard ended == nil else { return }
            ended = "stopped"
            onEnd = nil
            kill()
            let failed = (inFlight.map { [$0.then] } ?? []) + waiting.map(\.then)
            inFlight?.timer.cancel()
            inFlight = nil
            waiting = []
            for then in failed { then(.failure(Breach(description: "stopped"))) }
        }
    }

    /// Its whole group ended (TERM, then KILL a second on), its readers and writer told to let their descriptors go (the
    /// cancel pipe), reaped without waiting on anyone else's child, for a few seconds at most. On `queue`.
    private func kill() {
        let (pid, input, cancel, note, id) = (self.pid, self.input, self.cancel[1], self.note, self.id)
        (self.input, self.output, self.errors, self.cancel[1]) = (-1, -1, -1, -1)
        guard pid > 0 else { return }
        Darwin_or_Glibc_kill(-pid, SIGTERM)
        // Wakes the readers (each closes its own pipe) and a writer waiting on a full pipe; the writer then lets the
        // input go, after any write it is in.
        if cancel >= 0 { Sys.close(cancel) }
        let users = self.users
        writes.async {
            if input >= 0 { Sys.close(input) }
            users.leave()
        }
        DispatchQueue.global().async {
            var status: Int32 = 0
            let killAt = MacTime.real.awake() + 1, giveUpAt = killAt + 5
            var killed = false
            while waitpid(pid, &status, WNOHANG) == 0 {
                let now = MacTime.real.awake()
                if !killed, now > killAt { Darwin_or_Glibc_kill(-pid, SIGKILL); killed = true }
                if now > giveUpAt { return note("plugin \(id): its program (pid \(pid)) wasn't reaped 6 s after it was ended") }
                usleep(20_000)
            }
        }
    }
}

private func Darwin_or_Glibc_write(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int { write(fd, buffer, count) }
private func Darwin_or_Glibc_read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int { read(fd, buffer, count) }
private func Darwin_or_Glibc_kill(_ pid: pid_t, _ signal: Int32) { _ = Foundation.kill(pid, signal) }
