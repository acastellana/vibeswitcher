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
        /// Not a breach: refused because too many calls wait (`call`'s `atMost`); the program runs on.
        var busy = false
    }

    /// The most a protocol line nests (arrays and objects): a deeper one is a breach, found before it is parsed.
    static let nestingAtMost = 32

    static let lineBytesAtMost = 256 * 1024
    static let callTimeout: TimeInterval = 10
    static let stderrKept = 64 * 1024

    let id: String
    private let queue: DispatchQueue
    private let note: (String) -> Void
    private(set) var pid: pid_t = 0
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
    /// Starts the child: on a thread that lives as long as the server, which its parent-death signal is tied to.
    private let spawner: PluginSpawner
    /// Its own cgroup, when the server's can hold one (`PluginCgroup`): killed whole however it forked or left its session.
    private var cgroup: PluginCgroup?
    /// How it was confined, for `plugin list`'s readers and the log: "cgroup", "parent-death signal" or "process group".
    private(set) var confinement = ""

    init(id: String, note: @escaping (String) -> Void, spawner: PluginSpawner = .shared) {
        self.id = id
        self.note = note
        self.spawner = spawner
        queue = DispatchQueue(label: "vibenode.plugin.\(id)")
        writes = DispatchQueue(label: "vibenode.plugin.\(id).writes")
    }

    /// The program's environment (the review of step C, H1): no writable place it reads at start (HOME names nothing,
    /// the working folder is `/`), Python told not to read a user's site or the script's folder or write bytecode, and
    /// nothing else of any runtime's; with `data`, its private folder's path, which it reads as untrusted input.
    static func environment(data: URL?) -> [String] {
        ["PATH=/usr/bin:/bin", "HOME=/nonexistent", "LANG=C.UTF-8", "PYTHONNOUSERSITE=1", "PYTHONSAFEPATH=1", "PYTHONDONTWRITEBYTECODE=1"]
            + (data.map { ["VIBESWITCHER_PLUGIN_DATA=\($0.path)"] } ?? [])
    }

    /// Starts `copy` (its sealed copy), working in `/`, with `data` its private folder when it keeps data. Blocks briefly.
    /// Its group is its own (its own session); it gets the parent-death signal (KILL) through setpriv, tied to the
    /// spawner's thread, so the server's end ends it; and, when the server's cgroup can hold one, a cgroup of its own,
    /// which `kill` empties whole. The limit without a cgroup: a child of the program that starts a session of its
    /// own escapes the group's kill and doesn't inherit the parent-death signal; and a server that ends in the instant
    /// between the spawn and setpriv's setting the signal leaves the program running.
    func start(copy: Platform.ProcessSelf.SealedCopy, data: URL?) -> Result<Void, PluginRefusal> {
        var toChild: [Int32] = [-1, -1], fromChild: [Int32] = [-1, -1], errChild: [Int32] = [-1, -1], cancel: [Int32] = [-1, -1]
        // Close-on-exec from their making: the spawn gives the child its ends as its standard ones.
        guard Sys.pipeClosedOnExec(&toChild) == 0, Sys.pipeClosedOnExec(&fromChild) == 0, Sys.pipeClosedOnExec(&errChild) == 0,
              Sys.pipeClosedOnExec(&cancel) == 0 else {
            for fd in toChild + fromChild + errChild + cancel where fd >= 0 { Sys.close(fd) }
            return .failure(PluginRefusal("no pipes (errno \(errno))"))
        }
        // A write to a program that has gone is an error for the write, not the server's end.
        signal(SIGPIPE, SIG_IGN)
        let cgroup = PluginCgroup.make(id: id)
        let (executable, arguments, confinement) = Self.launch(copy: copy.path, cgroup: cgroup)
        var spawn = Platform.Spawn(executable: executable, arguments: arguments)
        spawn.environment = Self.environment(data: data)
        spawn.directory = "/"
        spawn.stdin = .descriptor(toChild[0])
        spawn.stdout = .descriptor(fromChild[1])
        spawn.stderr = .descriptor(errChild[1])
        spawn.keep = [copy.fd]
        spawn.group = .ownSession
        let started = spawner.run { spawn.start() }
        for fd in [toChild[0], fromChild[1], errChild[1]] { Sys.close(fd) }
        switch started {
        case .failure(let error):
            for fd in [toChild[1], fromChild[0], errChild[0]] + cancel { Sys.close(fd) }
            cgroup?.remove()
            return .failure(PluginRefusal("its program didn't start (errno \(error.code))"))
        case .success(let child):
            _ = fcntl(toChild[1], F_SETFL, fcntl(toChild[1], F_GETFL) | O_NONBLOCK)
            queue.sync {
                self.cgroup = cgroup
                self.confinement = confinement
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

    /// The program as the spawn starts it: through `sh` that moves itself into `cgroup` first (when there is one), then
    /// setpriv for the parent-death signal (when the system has it, root's), then the sealed copy; and how that confines it.
    static func launch(copy: String, cgroup: PluginCgroup?, setpriv: String? = PluginSpawner.setpriv) -> (String, [String], String) {
        var words = [copy]
        var confinement = "its process group"
        if let setpriv {
            words = [setpriv, "--pdeathsig", "KILL", "--"] + words
            confinement = "its process group and the parent-death signal"
        }
        if let cgroup {
            words = ["/bin/sh", "-c", #"echo $$ > "$0" || exit 125; exec "$@""#, cgroup.procs] + words
            confinement = "a cgroup of its own"
        }
        return (words[0], words, confinement)
    }

    /// Asks `call` with `fields` (`id` and `call` are the node's); `then` on the process's queue with the answer, its
    /// `id` taken off, or the breach. With `atMost`, refused as busy (not a breach) when that many calls wait already.
    func call(_ call: String, _ fields: Message = [:], atMost: Int? = nil, then: @escaping (Result<Message, Breach>) -> Void) {
        queue.async { [self] in
            if let ended { return then(.failure(Breach(description: ended))) }
            if let atMost, waiting.count + (inFlight == nil ? 0 : 1) >= atMost {
                return then(.failure(Breach(description: "busy: \(atMost) of its calls wait already", busy: true)))
            }
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
        switch Self.answer(line, expecting: inFlight?.id) {
        case .failure(let why): return breach(why.description)
        case .success(let answer):
            guard let flight = inFlight else { return breach("it answered no question, or out of order") }
            flight.timer.cancel()
            inFlight = nil
            flight.then(.success(answer))
            sendNext()
        }
    }

    /// A line as the answer to call `expecting` (nil: none in flight): the object without its `id`, or the breach. Its
    /// nesting bounded before it is parsed (a deep line would be the parser's recursion, in the server).
    static func answer(_ line: Data, expecting: Int?) -> Result<Message, Breach> {
        guard nesting(line) <= nestingAtMost else { return .failure(Breach(description: "a line nested over \(nestingAtMost) deep")) }
        guard let message = try? JSONSerialization.jsonObject(with: line) as? Message else {
            return .failure(Breach(description: "it wrote a line that isn't a JSON object"))
        }
        // A number, never `true` (Foundation reads a JSON true as 1 too).
        guard let expecting, let number = message["id"] as? NSNumber, !Platform.isBoolean(number), number.intValue == expecting,
              number.doubleValue == Double(expecting) else {
            return .failure(Breach(description: "it answered no question, or out of order"))
        }
        var answer = message
        answer["id"] = nil
        return .success(answer)
    }

    /// How deep `line` nests arrays and objects, outside its strings (counted on its bytes, before any parse).
    static func nesting(_ line: Data) -> Int {
        var depth = 0, deepest = 0, inString = false, escaped = false
        for byte in line {
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                deepest = max(deepest, depth)
            case UInt8(ascii: "]"), UInt8(ascii: "}"): depth -= 1
            default: break
            }
        }
        return deepest
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
            // The wire's reader, linear however the bytes come (the fuzz tests of 2026-11-23: this loop rescanned what it
            // held at each read and copied what followed each line it took, the two patterns `NodeWire.Lines` had).
            var reader = NodeWire.Lines(maxLine: Self.lineBytesAtMost)
            var logged = 0
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                guard Self.wait(for: fd, events: Int16(POLLIN), cancel: cancel) else { return }
                let count = chunk.withUnsafeMutableBytes { Darwin_or_Glibc_read(fd, $0.baseAddress!, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                guard let self else { return }
                if lines {
                    for line in reader.append(Data(chunk[0..<count])) { self.queue.async { self.heard(line) } }
                    if reader.tooLong { self.queue.async { self.breach("a line over 256 KiB") }; return }
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
        let (pid, input, cancel, note, id, cgroup) = (self.pid, self.input, self.cancel[1], self.note, self.id, self.cgroup)
        self.cgroup = nil
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
                if now > giveUpAt { break }
                usleep(20_000)
            }
            // Whatever it started, in a session of its own or not: its cgroup emptied.
            cgroup?.killAll()
            if waitpid(pid, &status, WNOHANG) == 0 { note("plugin \(id): its program (pid \(pid)) wasn't reaped 6 s after it was ended") }
        }
    }
}

private func Darwin_or_Glibc_write(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int { write(fd, buffer, count) }
private func Darwin_or_Glibc_read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int { read(fd, buffer, count) }
private func Darwin_or_Glibc_kill(_ pid: pid_t, _ signal: Int32) { _ = Foundation.kill(pid, signal) }

/// A thread that lives as long as the server and starts plugins' programs: a child's parent-death signal is tied to the
/// thread that started it (prctl(2)), so starting from a dispatch queue's worker, which ends when idle, would end the
/// program at random. A test makes its own and ends it, as the server's end would.
final class PluginSpawner: @unchecked Sendable {
    static let shared = PluginSpawner()
    /// setpriv, when the system has it in root's folders (util-linux): it sets the parent-death signal, then execs.
    static let setpriv: String? = ["/usr/bin/setpriv", "/bin/setpriv"].first { path in
        var info = stat()
        return stat(path, &info) == 0 && info.st_uid == 0 && info.st_mode & 0o022 == 0 && access(path, X_OK) == 0
    }

    private let condition = NSCondition()
    private var jobs: [() -> Void] = []
    private var ending = false

    init() {
        let thread = Thread { [condition] in
            while true {
                condition.lock()
                while self.jobs.isEmpty && !self.ending { condition.wait() }
                if self.jobs.isEmpty && self.ending { condition.unlock(); return }
                let job = self.jobs.removeFirst()
                condition.unlock()
                job()
            }
        }
        thread.name = "plugin-spawner"
        thread.start()
    }

    /// Runs `work` on the spawner's thread and waits for it.
    func run<T>(_ work: @escaping () -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        var result: T?
        condition.lock()
        jobs.append {
            result = work()
            done.signal()
        }
        condition.signal()
        condition.unlock()
        done.wait()
        return result!
    }

    /// Ends its thread once what it was given ran (a test's stand-in for the server's end).
    func end() {
        condition.lock()
        ending = true
        condition.signal()
        condition.unlock()
    }
}

/// A plugin program's own cgroup (cgroup v2), made under the server's when the server may write there (the node's
/// systemd unit's, under the user's manager): every process the program starts stays in it, whatever session it
/// makes, and `killAll` ends them all. Nil where the server's cgroup isn't writable (no systemd, a root-owned one).
final class PluginCgroup: @unchecked Sendable {
    let folder: String
    var procs: String { folder + "/cgroup.procs" }

    init(folder: String) { self.folder = folder }

    /// A new cgroup for plugin `id` beside the server's processes, or nil. `own`: the server's cgroup line (tests).
    static func make(id: String, own: String? = try? String(contentsOfFile: "/proc/self/cgroup", encoding: .utf8)) -> PluginCgroup? {
        guard let line = own?.split(separator: "\n").first(where: { $0.hasPrefix("0::/") }) else { return nil }
        let path = String(line.dropFirst(3))
        guard path != "/", !path.contains(".."), !path.contains("/vs-plugin-") else { return nil }
        let parent = "/sys/fs/cgroup" + path
        guard access(parent, W_OK) == 0, access(parent + "/cgroup.procs", W_OK) == 0 else { return nil }
        let folder = parent + "/vs-plugin-\(id)-\(UUID().uuidString.prefix(8).lowercased())"
        guard mkdir(folder, 0o755) == 0 else { return nil }
        return PluginCgroup(folder: folder)
    }

    /// Every process in it killed (cgroup.kill, else each listed), waited for briefly, the cgroup removed.
    func killAll() {
        if let kill = FileHandle(forWritingAtPath: folder + "/cgroup.kill") {
            try? kill.write(contentsOf: Data("1".utf8))
            try? kill.close()
        } else {
            let listed = (try? String(contentsOfFile: procs, encoding: .utf8)) ?? ""
            for pid in listed.split(separator: "\n").compactMap({ pid_t($0) }) { Darwin_or_Glibc_kill(pid, SIGKILL) }
        }
        let until = MacTime.real.awake() + 2
        while MacTime.real.awake() < until, ((try? String(contentsOfFile: procs, encoding: .utf8)) ?? "").isEmpty == false { usleep(20_000) }
        remove()
    }

    /// Removes it (empty; else the kernel refuses, and it is left).
    func remove() { _ = rmdir(folder) }

    /// What a server before this one left (it died with programs in their cgroups, which its parent-death signal
    /// doesn't reach when they left their session): each `vs-plugin-*` cgroup under the server's emptied and removed.
    /// Once, as the server starts.
    static func sweep(own: String? = try? String(contentsOfFile: "/proc/self/cgroup", encoding: .utf8)) {
        guard let line = own?.split(separator: "\n").first(where: { $0.hasPrefix("0::/") }) else { return }
        let path = String(line.dropFirst(3))
        guard path != "/", !path.contains("..") else { return }
        let parent = "/sys/fs/cgroup" + path
        guard access(parent, W_OK) == 0 else { return }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? [] where name.hasPrefix("vs-plugin-") {
            PluginCgroup(folder: parent + "/" + name).killAll()
        }
    }
}
