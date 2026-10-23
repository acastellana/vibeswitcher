import CryptoKit
import Darwin
import Foundation

/// A tool as `tools/list` describes it; its arguments are an object of named properties.
public struct MCPToolInfo {
    public struct Property {
        public var type: String
        public var description: String
        /// For `array` properties: the type of the items.
        public var items: String?
        public var options: [String]?

        public init(type: String, description: String, items: String? = nil, options: [String]? = nil) {
            self.type = type
            self.description = description
            self.items = items
            self.options = options
        }

        var json: [String: Any] {
            var object: [String: Any] = ["type": type, "description": description]
            if let items { object["items"] = ["type": items] }
            if let options { object["enum"] = options }
            return object
        }
    }

    public var name: String
    public var description: String
    public var properties: [String: Property]
    public var required: [String]

    public init(name: String, description: String, properties: [String: Property] = [:], required: [String] = []) {
        self.name = name
        self.description = description
        self.properties = properties
        self.required = required
    }

    var json: [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties.mapValues(\.json), "required": required] as [String: Any]]
    }
}

public struct MCPToolResult {
    public var text: String
    public var isError: Bool
    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

/// Whether the binary this server runs from is still the one on disk. An app update replaces it, and a running server
/// keeps the code it started with (an old lead's tools would still branch from main, say) unless it switches: so once
/// the file at `path` is another build, the server switches to it in place, between requests (see `MCPHandover`).
/// Only when that fails do tool results say so.
public final class BinaryWatch: @unchecked Sendable {
    /// A file as `stat` sees it, which is what tells builds apart: an install writes a new file (another inode) or
    /// rewrites it (another time or size).
    public struct Identity: Equatable, Codable {
        public var modified: TimeInterval
        public var size: Int64
        public var inode: UInt64
        public init(modified: TimeInterval, size: Int64, inode: UInt64) {
            self.modified = modified
            self.size = size
            self.inode = inode
        }
    }

    public let path: String
    private let identify: (String) -> Identity?
    /// The build this process runs.
    let running: Identity?
    private let lock = NSLock()
    private var failure: (build: Identity, at: Date, why: String)?
    /// How long a build that couldn't take over waits before it's tried again (a busy Mac can make its probe time out).
    var retry: TimeInterval = 60

    /// `running`: the build this process was executed from, when the one before it says (it checked the file just
    /// before); else the file as it is now: create it as the server starts.
    public init(path: String, running: Identity? = nil, identify: @escaping (String) -> Identity? = BinaryWatch.identity(of:)) {
        self.path = path
        self.identify = identify
        self.running = running ?? identify(path)
    }

    /// The build on disk when it isn't the one this process runs and it's time to switch to it. A missing file
    /// (mid-install, or moved) is no update, and neither is anything when the binary couldn't be read at start: no way
    /// to tell old from new.
    public func update(now: Date = Date()) -> Identity? {
        lock.lock()
        defer { lock.unlock() }
        guard let running, let disk = identify(path) else { return nil }
        guard disk != running else {
            failure = nil
            return nil
        }
        if let failure, failure.build == disk, now.timeIntervalSince(failure.at) < retry { return nil }
        return disk
    }

    /// Switching to `build` failed: it's tried again after `retry`, or as soon as another build replaces it.
    public func failed(_ build: Identity, because why: String, at now: Date = Date()) {
        lock.lock()
        failure = (build, now, why)
        lock.unlock()
    }

    /// The notice for a tool result: nil unless switching to a newer build failed.
    public func notice() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let failure else { return nil }
        return "VibeSwitcher was updated, but this tool server couldn't switch to the new build (\(failure.why)); it runs the old one and tries again in a minute."
    }

    public static func identity(of path: String) -> Identity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return Identity(modified: modified, size: Int64(info.st_size), inode: UInt64(info.st_ino))
    }
}

/// The MCP session as the client set it up: what a new build needs to go on answering the same client, with no
/// new initialize.
public struct MCPSession: Codable, Equatable {
    /// The revision `initialize` settled on.
    public var protocolVersion: String?
    /// What the client said of itself in `initialize`: `clientInfo` and `capabilities`, as JSON.
    public var client: Data?
    /// The client sent `notifications/initialized`.
    public var initialized = false
    /// The client was told that this server announces changes to its tools (`tools.listChanged`).
    public var announcesToolChanges = false
    /// A digest of the last `tools/list` the client got: a build with other tools tells it to ask again.
    public var tools: String?

    public init() {}
}

/// A tool server's switch to a new build, in place: the same process (Claude Code's child, on the same pipes) runs the
/// new binary from the next request on, so the client sees no disconnect and sends no new initialize.
///
/// The new build gets the MCP session and the input not handled yet (`State`), in a file only this process holds (an
/// unlinked one, open on a descriptor the new image inherits). Never a role: the new build asks the session host which
/// session it runs in, as at a fresh start, and the host answers from the process (the same pid, parent and terminal),
/// not from anything the old build says. A build that can't take the state never replaces the running one: it's run
/// first as a probe that reads it, and the exec happens only when the probe says it can.
public enum MCPHandover {
    /// Bumped whenever `State` changes shape: a build takes only its own.
    public static let format = 1
    /// How the probe is run: `vibeswitcher-mcp --mcp-handover-probe`, the state on its stdin.
    public static let probeFlag = "--mcp-handover-probe"
    /// What the probe prints when it can take over.
    static let probeAnswer = "vibeswitcher-mcp handover \(format) ok"
    /// Names the descriptor holding the state, in the new build's environment.
    static let variable = "VIBESWITCHER_MCP_HANDOVER"

    public struct State: Codable, Equatable {
        public var format = MCPHandover.format
        public var session: MCPSession
        /// Input read from the client but not handled yet: the new build handles it first.
        public var input: Data
        /// The build being switched to, as the file was just before (see `BinaryWatch.running`).
        public var binary: BinaryWatch.Identity?

        public init(session: MCPSession, input: Data, binary: BinaryWatch.Identity?) {
            self.session = session
            self.input = input
            self.binary = binary
        }
    }

    /// The state when it's one this build takes (`format`), else nil.
    static func decode(_ data: Data) -> State? {
        guard let state = try? JSONDecoder().decode(State.self, from: data), state.format == format else { return nil }
        return state
    }

    /// The probe, in the new build: reads the state on stdin and says whether it takes it. Exits.
    public static func answerProbe() -> Never {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard decode(data) != nil else {
            FileHandle.standardError.write(Data("vibeswitcher-mcp: handover probe: not a state this build takes (format \(format))\n".utf8))
            exit(1)
        }
        print(probeAnswer)
        exit(0)
    }

    /// Replaces this process's image with `executable` (run with `arguments`), handing it `state`. Returns only when
    /// that didn't happen, saying why; nothing changed then. Call it between requests, with none running.
    public static func replace(with executable: String, arguments: [String], state: State, probeTimeout: TimeInterval = 20) -> String {
        guard let data = try? JSONEncoder().encode(state) else { return "the session couldn't be written" }
        var template = Array((NSTemporaryDirectory() as NSString).appendingPathComponent("vibeswitcher-mcp-handover.XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { return "no state file: \(String(cString: strerror(errno)))" }
        defer { Darwin.close(fd) }
        // Only this descriptor holds it: nothing to clean up, nothing anyone else can open.
        unlink(template)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        guard writeAll(fd, data) else { return "the state file couldn't be written: \(String(cString: strerror(errno)))" }
        // The probe reads it from the start (it shares the offset), and so does the new build.
        guard lseek(fd, 0, SEEK_SET) == 0 else { return "the state file couldn't be rewound" }
        if let failure = probe(executable, stateFD: fd, timeout: probeTimeout) { return failure }
        guard lseek(fd, 0, SEEK_SET) == 0 else { return "the state file couldn't be rewound" }
        fflush(stdout)
        return exec(executable, arguments: arguments, stateFD: fd)
    }

    /// The state the build before handed this process, in the new build (once: the descriptor is closed after).
    public static func take() -> State? {
        guard let value = getenv(variable) else { return nil }
        let named = Int32(String(cString: value))
        unsetenv(variable)
        guard let fd = named, fd > 2, fcntl(fd, F_GETFD) != -1 else { return nil }
        defer { Darwin.close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = pread(fd, &buffer, buffer.count, off_t(data.count))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
        }
        guard let state = decode(data) else {
            FileHandle.standardError.write(Data("vibeswitcher-mcp: the build before handed over a session this one can't read; starting afresh\n".utf8))
            return nil
        }
        return state
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var written = 0
            while written < raw.count {
                let count = Darwin.write(fd, raw.baseAddress! + written, raw.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                written += count
            }
            return true
        }
    }

    /// Runs `executable --mcp-handover-probe` on the state and waits (up to `timeout`) for it to say it takes it; nil
    /// when it does, else why not.
    static func probe(_ executable: String, stateFD: Int32, timeout: TimeInterval) -> String? {
        var pipe: [Int32] = [-1, -1]
        guard Darwin.pipe(&pipe) == 0 else { return "no pipe for its probe" }
        defer { Darwin.close(pipe[0]) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var all: sigset_t = ~0
        var none: sigset_t = 0
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stateFD, 0)
        posix_spawn_file_actions_adddup2(&actions, pipe[1], 1)
        posix_spawn_file_actions_addinherit_np(&actions, 2)
        let words = [executable, probeFlag]
        let argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        Darwin.close(pipe[1])
        guard spawned == 0 else { return "it couldn't start: \(String(cString: strerror(spawned)))" }

        _ = fcntl(pipe[0], F_SETFL, fcntl(pipe[0], F_GETFL) | O_NONBLOCK)
        var output = Data()
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(timeout)
        while waitpid(pid, &status, WNOHANG) == 0 {
            guard Date() < deadline else {
                kill(pid, SIGKILL)
                waitpid(pid, &status, 0)
                return "its probe didn't answer"
            }
            output.append(drain(pipe[0]))
            usleep(10_000)
        }
        output.append(drain(pipe[0]))
        let answer = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0, answer.hasSuffix(probeAnswer) else {
            let exit = status & 0x7f == 0 ? "exited with status \((status >> 8) & 0xff)" : "was killed by signal \(status & 0x7f)"
            return answer.isEmpty ? "its probe \(exit)" : "its probe said \(answer.suffix(200))"
        }
        return nil
    }

    private static func drain(_ fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { return data }
            data.append(contentsOf: buffer[0..<count])
        }
    }

    /// The exec itself: the new image keeps the pid and gets stdin, stdout, stderr and the state's descriptor (named in
    /// its environment), nothing else. Returns only when it failed.
    private static func exec(_ executable: String, arguments: [String], stateFD: Int32) -> String {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETEXEC | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        // Default handling and an empty mask, as at a fresh start.
        var all: sigset_t = ~0
        var none: sigset_t = 0
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd in [0, 1, 2, stateFD] { posix_spawn_file_actions_addinherit_np(&actions, fd) }
        // An in-place exec refuses to hand on a descriptor marked close-on-exec (EBADF): unmark the state's while it
        // runs, and mark it again if it fails.
        _ = fcntl(stateFD, F_SETFD, 0)
        defer { _ = fcntl(stateFD, F_SETFD, FD_CLOEXEC) }
        let words = [executable] + arguments
        let argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var environment = ProcessInfo.processInfo.environment
        environment[variable] = "\(stateFD)"
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        return "it couldn't be executed: \(String(cString: strerror(result == 0 ? EINVAL : result)))"
    }
}

public protocol MCPToolset: AnyObject {
    var tools: [MCPToolInfo] { get }
    func call(_ name: String, _ arguments: [String: Any]) -> MCPToolResult
    /// False while the toolset can't tell its tools yet (see `MCPHostedToolset`): nothing is announced until it can.
    var settled: Bool { get }
}

extension MCPToolset {
    public var settled: Bool { true }
}

/// A toolset that the session host's answer makes (it tells which role the session holds), when the host can't be
/// asked yet. After an install it restarts, handing over to its new build, at the very moment the tool servers switch
/// to theirs: rather than serve nothing for good, this asks again, less often each time, for up to `patience`, and
/// answers calls meanwhile with `waiting`. Whatever the host answers is final (the toolset made from it decides).
public final class MCPHostedToolset: MCPToolset, @unchecked Sendable {
    public static let waiting = "The session host is restarting; try again in a few seconds."

    private let attempt: () -> MCPToolset?
    private let giveUp: () -> MCPToolset
    private let patience: TimeInterval
    private let firstDelay: TimeInterval
    private let longestDelay: TimeInterval
    private let lock = NSLock()
    private var made: MCPToolset?

    /// `attempt`: the toolset from the host's answer, or nil when the host couldn't be asked. `giveUp`: the toolset
    /// once `patience` has run out (one that says why it has no tools).
    public init(patience: TimeInterval = 120, firstDelay: TimeInterval = 0.25, longestDelay: TimeInterval = 5,
                attempt: @escaping () -> MCPToolset?, giveUp: @escaping () -> MCPToolset) {
        self.attempt = attempt
        self.giveUp = giveUp
        self.patience = patience
        self.firstDelay = firstDelay
        self.longestDelay = longestDelay
    }

    /// Asks once now, waiting for the answer as a fresh start does (so the client's first `tools/list` is the role's),
    /// then, while the host can't be asked, again on a thread of its own. `settled` is called when the toolset is made
    /// after that.
    public func start(settled: @escaping () -> Void) {
        if let toolset = attempt() {
            settle(toolset)
            return
        }
        FileHandle.standardError.write(Data("vibeswitcher-mcp: the session host can't be asked yet; asking again\n".utf8))
        Thread.detachNewThread { [self] in
            let deadline = Date().addingTimeInterval(patience)
            var delay = firstDelay
            var toolset: MCPToolset?
            while toolset == nil, Date() < deadline {
                Thread.sleep(forTimeInterval: min(delay, max(0, deadline.timeIntervalSinceNow)))
                delay = min(delay * 2, longestDelay)
                toolset = attempt()
            }
            if toolset == nil {
                FileHandle.standardError.write(Data("vibeswitcher-mcp: the session host didn't answer for \(Int(patience)) s; giving up\n".utf8))
            }
            settle(toolset ?? giveUp())
            settled()
        }
    }

    private func settle(_ toolset: MCPToolset) {
        lock.lock()
        made = toolset
        lock.unlock()
    }

    private var current: MCPToolset? {
        lock.lock()
        defer { lock.unlock() }
        return made
    }

    public var settled: Bool { current != nil }

    public var tools: [MCPToolInfo] { current?.tools ?? [] }

    public func call(_ name: String, _ arguments: [String: Any]) -> MCPToolResult {
        current?.call(name, arguments) ?? MCPToolResult(text: Self.waiting, isError: true)
    }
}

/// What a long tool call says while it works (merge and an audit waiting for a test and build slot, or for the load to
/// drop, and testing): MCP `notifications/progress` on the request's progress token, so the client hears from it at
/// least every `every` (Claude Code ends a call that sends "no response or progress for 1800s"). Set on the call's
/// thread (`current`), as `ShellCancel` is; nil when the client gave no progress token, and in tests that set none.
public final class ToolProgress: @unchecked Sendable {
    /// How often a wait or a run says how it goes.
    public let every: TimeInterval
    private let sink: (String) -> Void

    public init(every: TimeInterval = 30, _ sink: @escaping (String) -> Void) {
        self.every = every
        self.sink = sink
    }

    public func send(_ message: String) { sink(message) }

    private static let key = "VibeSwitcher.ToolProgress"
    public static var current: ToolProgress? { Thread.current.threadDictionary[key] as? ToolProgress }

    /// `body` with `progress` as `current` (nil: none); the one set before is set again afterwards.
    public static func with<T>(_ progress: ToolProgress?, _ body: () throws -> T) rethrows -> T {
        let outer = Thread.current.threadDictionary[key]
        Thread.current.threadDictionary[key] = progress
        defer { Thread.current.threadDictionary[key] = outer }
        return try body()
    }

    /// Until `stop` is called, `message()` every `every` on a thread of its own: for a call blocked in a command.
    public func heartbeat(_ message: @escaping @Sendable () -> String) -> () -> Void {
        let done = ShellCancel()
        let every = self.every
        Thread.detachNewThread { [self] in
            var next = Date().addingTimeInterval(every)
            while !done.isCancelled {
                if Date() >= next {
                    send(message())
                    next = Date().addingTimeInterval(every)
                }
                Thread.sleep(forTimeInterval: min(0.5, every / 4))
            }
        }
        return { done.cancel() }
    }
}

/// MCP over stdio: one JSON-RPC 2.0 message per line in, one reply per line out (none for notifications). Tool
/// calls run side by side (a 20-minute merge doesn't make `status` or `ping` wait), and a cancelled call's commands
/// are stopped. With a `watch`, the server switches to a new build of itself when one is installed, between requests
/// (see `MCPHandover`); it tells the client when the new build's tools differ.
///
/// Its input's end (a lead closed or restarted) and `stop` (SIGTERM, from the host's orphan sweep) end it the same way:
/// every running call is cancelled, and `serve` returns once they have all ended, `stopGrace` at most. A process that
/// just exited left a merge's test command running on in its own group without the test and build lock (its fd went
/// with the process), and the merge's scratch worktree registered (its cleanup never ran): process audit 2026-10-22, #6.
public final class MCPServer: @unchecked Sendable {
    private let name: String
    private let version: String
    private let toolset: MCPToolset
    private let watch: BinaryWatch?
    private let lock = NSLock()
    private var running: [String: ShellCancel] = [:]
    /// Ending: asked to stop, or its input ended.
    private var stopping = false
    /// How long an ending server waits for its cancelled calls to end (their commands stopped, their cleanup run).
    public var stopGrace: TimeInterval = 10
    /// The signal sources `stop(on:)` made, kept while it serves.
    private var signalSources: [DispatchSourceSignal] = []
    private var session: MCPSession
    /// Input the build before read but didn't handle (see `MCPHandover.State.input`).
    private var carried: Data
    /// Written to when a tool call ends: the reader looks again whether it can switch builds.
    private var wake: Int32 = -1
    /// How `serve` writes to the client, for announcements from other threads.
    private var announce: ((Data) -> Void)?
    /// Whether to switch to a new build now; asked once one is due (`vibeswitcher-mcp` waits for the session host to
    /// answer, as it restarts after an install too). Nil: always.
    public var switchWhen: (() -> Bool)?

    /// The MCP revisions this server speaks, newest first: tools only, text results, no JSON-RPC batches (2025-03-26
    /// has them), which reads the same in each. Not 2026-07-28, which has no initialize (a `server/discover`, a `_meta`
    /// envelope on every request, `resultType`, `ttlMs` and `cacheScope` on results). Claude Code 2.1.302 asks
    /// `server/discover` first, gets "method not found" and falls back to initialize with 2025-11-25.
    public static let protocolVersions = ["2025-11-25", "2025-06-18", "2024-11-05"]

    /// The version a client asked for when this server speaks it, else the newest it does (the client then decides
    /// whether to go on): never one it doesn't, as an echo would.
    public static func negotiate(_ requested: String?) -> String {
        requested.flatMap { protocolVersions.contains($0) ? $0 : nil } ?? protocolVersions[0]
    }

    /// `resuming`: what the build before this one handed over, when this process was that build a moment ago.
    public init(name: String, version: String, toolset: MCPToolset, watch: BinaryWatch? = nil, resuming: MCPHandover.State? = nil) {
        self.name = name
        self.version = version
        self.toolset = toolset
        self.watch = watch
        session = resuming?.session ?? MCPSession()
        carried = resuming?.input ?? Data()
    }

    /// The session as the client has set it up so far.
    public var currentSession: MCPSession {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    /// Ends `serve`: its running calls are cancelled, and it returns once they've ended (see the type's comment). From
    /// any thread.
    public func stop() {
        lock.lock()
        stopping = true
        let wake = self.wake
        lock.unlock()
        if wake >= 0 { _ = Darwin.write(wake, [UInt8(1)], 1) }
    }

    /// `stop` on any of `signals`: each caught (so a command a call starts gets it at its default, not ignored) and
    /// heard by a dispatch source.
    public func stop(on signals: [Int32]) {
        for number in signals {
            signal(number) { _ in }
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in self?.stop() }
            source.resume()
            lock.lock()
            signalSources.append(source)
            lock.unlock()
        }
    }

    /// Cancels every running call and waits, `stopGrace` at most, for them to end.
    private func end() {
        lock.lock()
        stopping = true
        let calls = Array(running.values)
        lock.unlock()
        calls.forEach { $0.cancel() }
        let deadline = Date().addingTimeInterval(stopGrace)
        while Date() < deadline {
            lock.lock()
            let idle = running.isEmpty
            lock.unlock()
            if idle { return }
            usleep(20_000)
        }
    }

    /// Reads requests from `input` until it closes (or `stop`), answering on `output`, then ends its calls. Between
    /// requests, with no tool call running, it switches to a new build when one is installed (and goes on here when
    /// that fails).
    public func serve(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO) {
        // A reader that has gone (a closed client) makes a write fail, not kill this process with SIGPIPE: an ending
        // server's cancelled calls still answer.
        _ = fcntl(output, F_SETNOSIGPIPE, 1)
        let writing = NSLock()
        let respond: (Data) -> Void = { reply in
            let line = Array(reply + Data([0x0A]))
            writing.lock()
            var sent = 0
            while sent < line.count {
                let count = line[sent...].withUnsafeBytes { Darwin.write(output, $0.baseAddress, $0.count) }
                if count > 0 { sent += count } else if count < 0 && errno == EINTR { continue } else { break }
            }
            writing.unlock()
        }
        var wakeup: [Int32] = [-1, -1]
        if Darwin.pipe(&wakeup) == 0 {
            for fd in wakeup {
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            }
        }
        lock.lock()
        wake = wakeup[1]
        announce = respond
        var pending = carried
        carried = Data()
        lock.unlock()
        defer {
            end()
            lock.lock()
            wake = -1
            announce = nil
            lock.unlock()
            for fd in wakeup where fd >= 0 { Darwin.close(fd) }
        }
        if let changed = toolsChanged() { respond(changed) }

        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            lock.lock()
            let stopped = stopping
            lock.unlock()
            if stopped { return }
            switchIfDue(pending: pending)
            if let end = pending.firstIndex(of: 0x0A) {
                var line = Data(pending[pending.startIndex..<end])
                pending = Data(pending[pending.index(after: end)...])
                if line.last == 0x0D { line.removeLast() }
                if !Self.isBlank(line) { receive(line, respond: respond) }
                continue
            }
            // A second at most: an idle server switches too, and the client hears of new tools before it asks.
            var fds = [pollfd(fd: input, events: Int16(POLLIN), revents: 0), pollfd(fd: wakeup[0], events: Int16(POLLIN), revents: 0)]
            let ready = poll(&fds, wakeup[0] >= 0 ? 2 : 1, 1_000)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if fds[1].revents != 0 { while Darwin.read(wakeup[0], &chunk, chunk.count) > 0 {} }
            guard fds[0].revents != 0 else { continue }
            let count = Darwin.read(input, &chunk, chunk.count)
            if count > 0 {
                pending.append(contentsOf: chunk[0..<count])
            } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                // Closed: the last line may have no newline.
                if !Self.isBlank(pending) { receive(pending, respond: respond) }
                return
            }
        }
    }

    private static func isBlank(_ line: Data) -> Bool {
        line.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
    }

    /// Switches to the build on disk when it's another one and no tool call is running (only this thread starts them,
    /// so none starts in between). Returns only when it didn't switch.
    private func switchIfDue(pending: Data) {
        guard let watch else { return }
        lock.lock()
        let idle = running.isEmpty
        let state = MCPHandover.State(session: session, input: pending, binary: nil)
        lock.unlock()
        guard idle, let build = watch.update(), switchWhen?() ?? true else { return }
        var handover = state
        handover.binary = build
        let why = MCPHandover.replace(with: watch.path, arguments: Array(CommandLine.arguments.dropFirst()), state: handover)
        watch.failed(build, because: why)
        FileHandle.standardError.write(Data("vibeswitcher-mcp: couldn't switch to the new build at \(watch.path): \(why); this build serves on\n".utf8))
    }

    /// The toolset can tell its tools now (see `MCPToolset.settled`): the client hears if they aren't the ones it got.
    public func toolsSettled() {
        lock.lock()
        let announce = self.announce
        lock.unlock()
        if let announce, let changed = toolsChanged() { announce(changed) }
    }

    /// The notification that the tools changed, for a client that got other tools (another build's, or none while
    /// the role was still being asked) and was told they may. Once: the client asks again.
    private func toolsChanged() -> Data? {
        guard toolset.settled else { return nil }
        let digest = Self.digest(toolset.tools)
        lock.lock()
        defer { lock.unlock() }
        guard session.initialized, session.announcesToolChanges, let told = session.tools, told != digest else { return nil }
        session.tools = digest
        return encode(["jsonrpc": "2.0", "method": "notifications/tools/list_changed"])
    }

    static func digest(_ tools: [MCPToolInfo]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: tools.map(\.json), options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// One incoming message: tool calls are answered when they finish (on another thread), the rest at once.
    public func receive(_ data: Data, respond: @escaping (Data) -> Void) {
        let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let method = message?["method"] as? String
        if method == "tools/call", let id = message?["id"] {
            let token = ShellCancel()
            let key = "\(id)"
            lock.lock()
            running[key] = token
            lock.unlock()
            // A thread of its own, not the shared pool: a call blocks for as long as its commands run, and while the
            // pool is busy (a build, other calls) it wouldn't even start; a cancel would find nothing running.
            // The client's progress token, when it gave one: what the call says while it works goes to it.
            let progressToken = ((message?["params"] as? [String: Any])?["_meta"] as? [String: Any])?["progressToken"]
            let progress = progressToken.map { token in
                let counting = NSLock()
                var count = 0
                return ToolProgress { [weak self] text in
                    counting.lock()
                    count += 1
                    let note: [String: Any] = ["jsonrpc": "2.0", "method": "notifications/progress",
                                               "params": ["progressToken": token, "progress": count, "message": text]]
                    counting.unlock()
                    if let data = self?.encode(note) { respond(data) }
                }
            }
            Thread.detachNewThread { [self] in
                let reply = ShellCancel.with(token) { ToolProgress.with(progress) { handle(data) } }
                // Answered before it counts as ended: a switch of builds waits for no call, and loses none.
                if let reply { respond(reply) }
                lock.lock()
                running[key] = nil
                let wake = self.wake
                lock.unlock()
                if wake >= 0 { _ = Darwin.write(wake, [UInt8(1)], 1) }
            }
            return
        }
        if method == "notifications/cancelled", let params = message?["params"] as? [String: Any], let request = params["requestId"] {
            lock.lock()
            running["\(request)"]?.cancel()
            lock.unlock()
        }
        if let reply = handle(data) { respond(reply) }
    }

    public func handle(_ data: Data) -> Data? {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        if method == "notifications/initialized" { remember { $0.initialized = true } }
        // Notifications (no id) get no reply.
        guard let id else { return nil }
        switch method {
        case "initialize":
            let negotiated = Self.negotiate(params["protocolVersion"] as? String)
            let client = ["clientInfo": params["clientInfo"] ?? NSNull(), "capabilities": params["capabilities"] ?? NSNull()]
            remember {
                $0.protocolVersion = negotiated
                $0.client = try? JSONSerialization.data(withJSONObject: client, options: [.sortedKeys])
                $0.announcesToolChanges = true
            }
            return reply(id, ["protocolVersion": negotiated,
                              "capabilities": ["tools": ["listChanged": true]], "serverInfo": ["name": name, "version": version]])
        case "ping":
            return reply(id, [String: Any]())
        case "tools/list":
            let tools = toolset.tools
            remember { $0.tools = Self.digest(tools) }
            return reply(id, ["tools": tools.map(\.json)])
        case "tools/call":
            let tool = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let result = toolset.call(tool, arguments)
            var content = [["type": "text", "text": result.text]]
            if let notice = watch?.notice() { content.append(["type": "text", "text": notice]) }
            return reply(id, ["content": content, "isError": result.isError])
        default:
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    private func remember(_ change: (inout MCPSession) -> Void) {
        lock.lock()
        change(&session)
        lock.unlock()
    }

    private func reply(_ id: Any, _ result: [String: Any]) -> Data? {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
