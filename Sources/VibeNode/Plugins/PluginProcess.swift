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
    }

    /// Starts `copy` (its sealed copy) in `work`. Blocks briefly.
    func start(copy: Platform.ProcessSelf.SealedCopy, work: URL) -> Result<Void, PluginRefusal> {
        var toChild: [Int32] = [-1, -1], fromChild: [Int32] = [-1, -1], errChild: [Int32] = [-1, -1]
        // Close-on-exec from their making: the spawn gives the child its ends as its standard ones.
        guard Sys.pipeClosedOnExec(&toChild) == 0, Sys.pipeClosedOnExec(&fromChild) == 0, Sys.pipeClosedOnExec(&errChild) == 0 else {
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
            for fd in [toChild[1], fromChild[0], errChild[0]] { Sys.close(fd) }
            return .failure(PluginRefusal("its program didn't start (errno \(error.code))"))
        case .success(let child):
            queue.sync {
                pid = child
                input = toChild[1]
                output = fromChild[0]
                errors = errChild[0]
            }
            read(output, lines: true)
            read(errors, lines: false)
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
        var sent = 0
        next.line.withUnsafeBytes { raw in
            while sent < raw.count {
                let count = Darwin_or_Glibc_write(input, raw.baseAddress! + sent, raw.count - sent)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                sent += count
            }
        }
        if sent < next.line.count { breach("its input closed") }
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

    /// Reads `fd` on a thread of its own: lines of the protocol, or the log's (inert, capped).
    private func read(_ fd: Int32, lines: Bool) {
        let thread = Thread { [weak self] in
            var buffer = Data()
            var logged = 0
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
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

    /// Its whole group ended (TERM, then KILL a second on), its pipes closed, reaped without waiting on anyone else's child.
    private func kill() {
        let (pid, fds) = (self.pid, [input, output, errors])
        input = -1
        guard pid > 0 else { return }
        Darwin_or_Glibc_kill(-pid, SIGTERM)
        Sys.close(fds[0])
        DispatchQueue.global().async {
            var status: Int32 = 0
            let deadline = MacTime.real.awake() + 1
            while waitpid(pid, &status, WNOHANG) == 0 {
                if MacTime.real.awake() > deadline { Darwin_or_Glibc_kill(-pid, SIGKILL); _ = waitpid(pid, &status, 0); break }
                usleep(20_000)
            }
            Sys.close(fds[1])
            Sys.close(fds[2])
        }
    }
}

private func Darwin_or_Glibc_write(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int { write(fd, buffer, count) }
private func Darwin_or_Glibc_read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int { read(fd, buffer, count) }
private func Darwin_or_Glibc_kill(_ pid: pid_t, _ signal: Int32) { _ = Foundation.kill(pid, signal) }
