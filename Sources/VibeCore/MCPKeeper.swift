import Darwin
import Foundation

/// Keeps a session's tool server running: `vibeswitcher-mcp --keeper <its arguments>` holds Claude Code's stdio and
/// runs the real server (the same binary, without `--keeper`) as its child, relaying lines both ways. When the child
/// ends while the client is still there (a crash, a SIGKILL, out of descriptors), the keeper answers each request the
/// child had in hand with an error naming the restart, starts a new child, replays the client's initialize and
/// initialized to it (swallowing the reply), tells the client its tools may have changed, and relays on: the client
/// sees a failed call, never a closed connection, and sends no new initialize. On 2026-10-27/28 the lead's tool server
/// stopped four times and each time the user had to run /mcp, which no agent can (incident 4).
///
/// It's dumb on purpose, so it doesn't die of what the server might: no tools, no session host, no switch of builds (a
/// new build takes over in the child, in place, on the same pipes, see `MCPHandover`). Of each line it reads only what
/// tells requests from replies (method and id). A child that keeps ending is started again at most `limit` times in
/// `window`, a little later each time, and then the keeper ends too, saying why on stderr: a broken build doesn't spin.
public enum MCPKeeper {
    public static let flag = "--keeper"

    /// What the keeper knows of the MCP session: the client's handshake, to replay to a new child, and the requests
    /// the child hasn't answered yet.
    public struct Relay {
        /// The client's last initialize request, as it sent it.
        private var initialize: [String: Any]?
        /// The client sent notifications/initialized after it.
        public private(set) var initialized = false
        /// The client's requests the child hasn't answered, in the order sent: their ids, and the ids as keys.
        private var inHand: [(key: String, id: Any)] = []
        private var replays = 0
        /// The id of the replayed initialize, until the child's reply to it is swallowed.
        private var replayID: String?

        public init() {}

        /// The requests in hand, by id.
        public var pending: [String] { inHand.map(\.key) }

        /// A line from the client, before it goes to the child.
        public mutating func fromClient(_ line: Data) {
            guard let message = Self.object(line), let method = message["method"] as? String else { return }
            if method == "initialize" {
                initialize = message
                initialized = false
            }
            if method == "notifications/initialized" { initialized = true }
            if let id = message["id"], let key = Self.key(id), !inHand.contains(where: { $0.key == key }) { inHand.append((key, id)) }
        }

        /// Whether a line from the child goes on to the client: all but the reply to a replayed initialize.
        public mutating func fromChild(_ line: Data) -> Bool {
            guard let message = Self.object(line), message["method"] == nil, let id = message["id"], let key = Self.key(id) else { return true }
            if let replayID, key == Self.key(replayID) {
                self.replayID = nil
                return false
            }
            inHand.removeAll { $0.key == key }
            return true
        }

        /// The child ended (`why`, in words): an error reply for each request it had in hand, none left in hand.
        public mutating func ended(_ why: String) -> [Data] {
            defer {
                inHand = []
                replayID = nil
            }
            let text = "VibeSwitcher's tool server stopped while this ran (it \(why)) and was started again; "
                + "what the call did before it stopped may stand: check, then call again."
            return inHand.compactMap { Self.encode(["jsonrpc": "2.0", "id": $0.id, "error": ["code": -32000, "message": text]]) }
        }

        /// What a new child is sent first: the client's initialize (under an id of the keeper's, its reply swallowed),
        /// then its initialized. None while the client hasn't initialized.
        public mutating func replay() -> [Data] {
            guard var request = initialize else { return [] }
            replays += 1
            let id = "vibeswitcher-keeper-\(replays)"
            request["id"] = id
            replayID = id
            var lines = [Self.encode(request)].compactMap { $0 }
            if initialized, let line = Self.encode(["jsonrpc": "2.0", "method": "notifications/initialized"]) { lines.append(line) }
            return lines
        }

        /// For the client once a new child has its handshake: its tools may be another build's, so it asks again (the
        /// child then knows what the client has, and tells it of a later change itself).
        public var toolsMayHaveChanged: Data? {
            initialized ? Self.encode(["jsonrpc": "2.0", "method": "notifications/tools/list_changed"]) : nil
        }

        /// An id as a key: a number and a string that read alike are different ids.
        static func key(_ id: Any) -> String? {
            if let text = id as? String { return "s:" + text }
            if let number = id as? NSNumber { return "n:\(number)" }
            return nil
        }

        static func object(_ line: Data) -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        }

        static func encode(_ object: [String: Any]) -> Data? {
            try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
    }

    /// How often a child that keeps ending is started again: at most `limit` times in `window`.
    public struct Restarts {
        public let limit: Int
        public let window: TimeInterval
        private var times: [Date] = []

        public init(limit: Int = 5, window: TimeInterval = 60) {
            self.limit = limit
            self.window = window
        }

        /// The restarts in the window up to `now`.
        public func recent(at now: Date) -> Int { times.filter { now.timeIntervalSince($0) < window }.count }

        /// A restart at `now`, if one's left in the window: how long to wait before it (none for the window's first,
        /// then 0.25 s, doubling, 4 s at most); nil when the window has had `limit`.
        public mutating func spend(at now: Date) -> TimeInterval? {
            times.removeAll { now.timeIntervalSince($0) >= window }
            guard times.count < limit else { return nil }
            let delay = times.isEmpty ? 0 : min(4, 0.25 * pow(2, Double(times.count - 1)))
            times.append(now)
            return delay
        }
    }

    /// A child's end in words: "exited with status 3", "was killed by signal 9 (Killed: 9)".
    public static func describe(status: Int32) -> String {
        let signal = status & 0x7f
        guard signal != 0 else { return "exited with status \((status >> 8) & 0xff)" }
        return "was killed by signal \(signal) (\(String(cString: strsignal(signal))))"
    }

    /// Signals and child ends, from dispatch sources, for the relay's loop.
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var stop: Int32?
        /// The loop's wake-up: written to on every event, read in its poll.
        let wake: [Int32]
        private var sources: [DispatchSourceSignal] = []

        init() {
            var fds: [Int32] = [-1, -1]
            if Darwin.pipe(&fds) == 0 {
                for fd in fds {
                    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                }
            }
            wake = fds
            // SIGTERM (the host's orphan sweep) and SIGHUP go on to the child, which ends; then the keeper does.
            for number in [SIGTERM, SIGHUP] {
                signal(number) { _ in }
                listen(number) { [weak self] in self?.stopping(number) }
            }
            // A child's end wakes the loop at once (its default action is none, so no handler is needed).
            listen(SIGCHLD) {}
        }

        private func listen(_ number: Int32, _ handler: @escaping () -> Void) {
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in
                handler()
                self?.nudge()
            }
            source.resume()
            sources.append(source)
        }

        private func stopping(_ number: Int32) {
            lock.lock()
            if stop == nil { stop = number }
            lock.unlock()
        }

        /// The stop signal, once.
        func takeStop() -> Int32? {
            lock.lock()
            defer { lock.unlock() }
            let number = stop
            stop = nil
            return number
        }

        func nudge() { if wake[1] >= 0 { _ = Darwin.write(wake[1], [UInt8(1)], 1) } }
    }

    /// A running child: its pid, and this side of its stdin and stdout.
    private struct Child {
        let pid: pid_t
        var input: Int32
        var output: Int32
        /// When its stdout ended, while it hadn't exited yet.
        var outputEnded: Date?
    }

    /// Starts `executable` with `arguments` on new pipes for stdin and stdout, stderr shared; nil and why when it can't.
    private static func spawn(_ executable: String, _ arguments: [String]) -> (child: Child?, why: String?) {
        var input: [Int32] = [-1, -1], output: [Int32] = [-1, -1]
        guard Darwin.pipe(&input) == 0 else { return (nil, "couldn't be started: no pipe, \(MCPLog.errnoText(errno))") }
        guard Darwin.pipe(&output) == 0 else {
            input.forEach { Darwin.close($0) }
            return (nil, "couldn't be started: no pipe, \(MCPLog.errnoText(errno))")
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Nothing but its stdio: no descriptor of the keeper's leaks into it. Default signals and an empty mask, as at a
        // fresh start (the keeper catches some).
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var all: sigset_t = ~0
        var none: sigset_t = 0
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input[0], 0)
        posix_spawn_file_actions_adddup2(&actions, output[1], 1)
        posix_spawn_file_actions_addinherit_np(&actions, 2)
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        Darwin.close(input[0])
        Darwin.close(output[1])
        guard spawned == 0 else {
            Darwin.close(input[1])
            Darwin.close(output[0])
            return (nil, "couldn't be started: \(MCPLog.errnoText(spawned))")
        }
        for fd in [input[1], output[0]] {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        _ = fcntl(input[1], F_SETNOSIGPIPE, 1)
        return (Child(pid: pid, input: input[1], output: output[0]), nil)
    }

    /// Complete lines off the front of `buffer`, each with its newline.
    private static func lines(_ buffer: inout Data) -> [Data] {
        var lines: [Data] = []
        while let end = buffer.firstIndex(of: 0x0A) {
            lines.append(Data(buffer[buffer.startIndex...end]))
            buffer = Data(buffer[buffer.index(after: end)...])
        }
        return lines
    }

    /// Writes what it can of `data` to `fd` (non-blocking); false when the reader has gone.
    private static func flush(_ data: inout Data, to fd: Int32) -> Bool {
        while !data.isEmpty {
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                data.removeFirst(count)
                continue
            }
            if count < 0 && errno == EINTR { continue }
            return count < 0 && errno == EAGAIN
        }
        return true
    }

    /// Reads what's there on `fd` (non-blocking) onto `buffer`; false at its end (or a read that failed).
    private static func drain(_ fd: Int32, into buffer: inout Data) -> Bool {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                continue
            }
            if count < 0 && errno == EINTR { continue }
            return count < 0 && errno == EAGAIN
        }
    }

    /// The keeper itself: serves stdin and stdout with `executable arguments` as its child until the client goes (its
    /// input ends, or its output's reader has gone) or a stop signal comes, then waits for the child to end and returns
    /// 0. Returns 1 when the child kept ending (`restarts`).
    public static func run(executable: String, arguments: [String], restarts: Restarts = Restarts(),
                           input clientIn: Int32 = STDIN_FILENO, output clientOut: Int32 = STDOUT_FILENO) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        _ = fcntl(clientOut, F_SETNOSIGPIPE, 1)
        for fd in [clientIn, clientOut] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        let events = Events()
        var restarts = restarts
        var relay = Relay()
        var child: Child?
        var fromClient = Data(), toChild = Data(), fromChild = Data(), toClient = Data()
        var clientOpen = true, clientGone = false, stopping = false
        // When the next child starts (nil: now); the first has no handshake to replay.
        var startAt: Date?
        var first = true
        // When the client went: a child that doesn't end within `ending` of it is killed.
        var leftAt: Date?
        let ending: TimeInterval = 30

        /// The rest of what the client is owed, for up to 2 s, then the keeper ends with `status`.
        func finish(_ status: Int32) -> Int32 {
            let deadline = Date().addingTimeInterval(2)
            while !toClient.isEmpty, !clientGone, Date() < deadline {
                if !flush(&toClient, to: clientOut) { break }
                var fds = [pollfd(fd: clientOut, events: Int16(POLLOUT), revents: 0)]
                _ = poll(&fds, 1, 100)
            }
            return status
        }

        /// A child's end (its status, in words) while the client is there: its calls answered, the next one due.
        /// False when it's been started again too often.
        func ended(_ why: String) -> Bool {
            let answered = relay.ended(why)
            toClient += answered.reduce(Data()) { $0 + $1 + Data([0x0A]) }
            toChild = Data()
            let now = Date()
            let calls = answered.count == 1 ? "1 call in hand answered with an error" : "\(answered.count) calls in hand answered with an error"
            guard let delay = restarts.spend(at: now) else {
                let line = "vibeswitcher-mcp keeper: the tool server stopped \(restarts.limit + 1) times within \(Int(restarts.window)) s "
                    + "(last: it \(why)); not starting it again"
                MCPLog.note("keeper: \(line.dropFirst("vibeswitcher-mcp keeper: ".count)); \(calls); exiting with status 1")
                FileHandle.standardError.write(Data((line + "\n").utf8))
                return false
            }
            MCPLog.note("keeper: the tool server \(why); starting it again" + (delay > 0 ? " in \(delay) s" : "")
                        + " (restart \(restarts.recent(at: now)) of \(restarts.limit) within \(Int(restarts.window)) s); \(calls)")
            startAt = now.addingTimeInterval(delay)
            return true
        }

        while true {
            if let number = events.takeStop() {
                MCPLog.note("keeper: stopping: signal \(number) (\(String(cString: strsignal(number))))" + (child.map { ", passed on to pid \($0.pid)" } ?? ""))
                stopping = true
                if let child { kill(child.pid, number) }
            }
            let leaving = stopping || !clientOpen || clientGone
            if leaving, leftAt == nil { leftAt = Date() }

            if child == nil {
                if leaving { return finish(0) }
                if let at = startAt, at > Date() {
                    // Waits below, reading the client meanwhile.
                } else {
                    let started = spawn(executable, arguments)
                    if let new = started.child {
                        child = new
                        startAt = nil
                        if first {
                            MCPLog.note("keeper: pid \(getpid()) runs the tool server, pid \(new.pid)")
                        } else {
                            // Its handshake goes ahead of what the client sent meanwhile.
                            toChild = relay.replay().reduce(Data()) { $0 + $1 + Data([0x0A]) } + toChild
                            if let changed = relay.toolsMayHaveChanged { toClient += changed + Data([0x0A]) }
                            MCPLog.note("keeper: started the tool server again, pid \(new.pid)" + (relay.initialized ? ", the client's initialize replayed" : ""))
                        }
                        first = false
                    } else {
                        first = false
                        if !ended(started.why ?? "couldn't be started") { return finish(1) }
                        continue
                    }
                }
            }

            // The client's input once it's said all (a child closes its input when the client's does).
            if !clientOpen || clientGone, toChild.isEmpty || clientGone, var running = child, running.input >= 0 {
                Darwin.close(running.input)
                running.input = -1
                child = running
            }
            if let running = child, let left = leftAt, Date().timeIntervalSince(left) > ending {
                MCPLog.note("keeper: the tool server, pid \(running.pid), didn't end within \(Int(ending)) s of the client; killing it")
                kill(running.pid, SIGKILL)
                leftAt = Date()
            }

            var fds: [pollfd] = [pollfd(fd: events.wake[0], events: Int16(POLLIN), revents: 0)]
            let readClient = clientOpen && !clientGone ? fds.count : -1
            if readClient >= 0 { fds.append(pollfd(fd: clientIn, events: Int16(POLLIN), revents: 0)) }
            let writeClient = !toClient.isEmpty && !clientGone ? fds.count : -1
            if writeClient >= 0 { fds.append(pollfd(fd: clientOut, events: Int16(POLLOUT), revents: 0)) }
            let readChild = child.map { $0.output >= 0 } == true ? fds.count : -1
            if readChild >= 0 { fds.append(pollfd(fd: child!.output, events: Int16(POLLIN), revents: 0)) }
            let writeChild = child.map { $0.input >= 0 } == true && !toChild.isEmpty ? fds.count : -1
            if writeChild >= 0 { fds.append(pollfd(fd: child!.input, events: Int16(POLLOUT), revents: 0)) }
            // A second at most (a child's end is heard at once, by SIGCHLD); less while a start waits.
            let wait = child == nil ? max(0, startAt.map { $0.timeIntervalSinceNow } ?? 0) : 1
            let ready = poll(&fds, nfds_t(fds.count), Int32(min(1, wait) * 1000))
            if ready < 0, errno != EINTR, errno != EAGAIN {
                MCPLog.note("keeper: poll failed with \(MCPLog.errnoText(errno)); \(MCPLog.descriptors())")
                usleep(100_000)
            }
            var scratch = [UInt8](repeating: 0, count: 64)
            if fds[0].revents != 0 { while Darwin.read(events.wake[0], &scratch, scratch.count) > 0 {} }

            if readClient >= 0, fds[readClient].revents != 0 {
                if !drain(clientIn, into: &fromClient) {
                    clientOpen = false
                    MCPLog.note("keeper: the client's input ended")
                    // Closed: the last line may have no newline.
                    if !fromClient.isEmpty { fromClient.append(0x0A) }
                }
                for line in lines(&fromClient) {
                    relay.fromClient(line)
                    toChild += line
                }
            }
            if let running = child, readChild >= 0, fds[readChild].revents != 0 {
                if !drain(running.output, into: &fromChild) {
                    // Its end, heard: closed, so the poll doesn't wake for it again.
                    Darwin.close(running.output)
                    child?.output = -1
                    child?.outputEnded = Date()
                }
                for line in lines(&fromChild) where relay.fromChild(line) { toClient += line }
            }
            if let running = child, writeChild >= 0, fds[writeChild].revents != 0, !flush(&toChild, to: running.input) {
                // Its input is closed: it's ending, and its end is what counts.
                toChild = Data()
            }
            if writeClient >= 0, fds[writeClient].revents != 0, !flush(&toClient, to: clientOut) {
                MCPLog.note("keeper: the client's output has no reader (it's gone)")
                clientGone = true
                toClient = Data()
            }

            guard let running = child else { continue }
            var status: Int32 = 0
            let reaped = waitpid(running.pid, &status, WNOHANG)
            if reaped == 0 {
                // Its stdout ended but it hasn't: a process with no output can't serve, so it's ended.
                if let since = running.outputEnded, Date().timeIntervalSince(since) > 5 {
                    MCPLog.note("keeper: the tool server, pid \(running.pid), closed its output 5 s ago and is still running; killing it")
                    kill(running.pid, SIGKILL)
                    child?.outputEnded = nil
                }
                continue
            }
            // Ended: what it wrote before it did goes out first, a last half line never (it would read as broken JSON).
            if running.output >= 0 { _ = drain(running.output, into: &fromChild) }
            for line in lines(&fromChild) where relay.fromChild(line) { toClient += line }
            fromChild = Data()
            if running.output >= 0 { Darwin.close(running.output) }
            if running.input >= 0 { Darwin.close(running.input) }
            child = nil
            let why = reaped < 0 ? "ended (its status couldn't be read: \(MCPLog.errnoText(errno)))" : describe(status: status)
            if stopping || !clientOpen || clientGone {
                MCPLog.note("keeper: the tool server, pid \(running.pid), \(why) after the client went; exiting")
                return finish(0)
            }
            if !ended(why) { return finish(1) }
        }
    }
}
