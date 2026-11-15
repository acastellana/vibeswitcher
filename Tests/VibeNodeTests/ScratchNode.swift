import Foundation
import Testing
import VibeCore
import VibeNode

/// A scratch node started as processes, for the server's and the command line's tests (the engine plan's E1): a
/// scratch session host started as stage 2's `TestHosts.authorize` starts one (the test process its app too, through
/// a connector given as `--test-app-pid`/`--test-app-connector`), with the built `vibeswitcher-server` as its server
/// child, on a short scratch root of its own (a socket's path fits in `sun_path`).
///
/// - `VIBESWITCHER_HOME` is the root; the host listens on `<root>/host.sock`, locks `<root>/scratch-host.lock`, and
///   takes `--node-root <root>/build`, whose `bin/` holds links to the built products and whose `build-info` records
///   each one's SHA-256 (stage 2's `BuildInfo`), so the host's start check (Task 9b) passes and stays exercised.
/// - `<root>/v2/test/` holds the stand-ins of the Global Constraints: a recording journal socket (`journal.sock`,
///   each datagram recorded with its sender's credentials as journald stamps them, in `journal.jsonl`), a stand-in
///   `journalctl` (that record) and `systemctl`, `claude` linked to `FakeClaude`'s launcher (EN-D13), and
///   `user-scopes`, the test's scopes for the command line's journal check.
/// - `userScopes` (by default this process's own cgroup) goes to the server as `--server-arg --test-user-scopes=…`;
///   nil leaves the server on the weaker rule. `housekeeping`: `--server-arg --test-housekeeping=…`. `testChild`:
///   `--server-arg --test-child=…`. `path`: the host's PATH. `holdFirstLook`: `--hold-first-look`, and
///   `--server-arg --test-first-look` so the server's engine knows (E4). `socketName`: the
///   host's socket in the root (another than `host.sock` isn't the root's: its server refuses it). `waitForServer`:
///   returns once the server answers, its link to the host welcomed.
///
/// Ended, with its server, sessions and files, by `stop()` or when it goes.
final class ScratchNode: @unchecked Sendable {
    let root: URL
    let home: URL
    let nodeRoot: URL
    let socket: String
    let lock: String
    let output: String
    let testFolder: URL
    let process = Process()
    let recorder: JournalRecorder?
    /// The fake Claude its `claude` link names (EN-D13): a lead the server starts runs it.
    let fake: FakeClaude.Install
    private var testEnd: Int32 = -1
    private var stopped = false
    private let lockForStop = NSLock()

    /// This process's own cgroup path (the unified hierarchy's, or systemd's v1 line's).
    static let ownScope: String? = Platform.Processes.cgroup(getpid()).flatMap { PeerFacts.unifiedPath($0) ?? PeerFacts.systemdPath($0) }

    init(_ scratch: Scratch, userScopes: [String]? = ScratchNode.ownScope.map { [$0] }, housekeeping: Int? = nil,
         path: String = "/usr/bin:/bin", holdFirstLook: Bool = false, testChild: String? = nil, socketName: String = "host.sock",
         sealLife: Int? = nil, waitForServer: Bool = true) async throws {
        root = try scratch.shortFolder("vsn")
        home = root.appendingPathComponent("home", isDirectory: true)
        nodeRoot = root.appendingPathComponent("build", isDirectory: true)
        socket = root.appendingPathComponent(socketName).path
        lock = root.appendingPathComponent(NodeCheck.scratchLock).path
        output = root.appendingPathComponent("host.out").path
        testFolder = root.appendingPathComponent("v2/test", isDirectory: true)
        let files = FileManager.default
        for folder in [home, nodeRoot.appendingPathComponent("bin"), testFolder, root.appendingPathComponent("tmp")] {
            try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try Self.install(into: nodeRoot)
        try Self.standIns(in: testFolder, scopes: userScopes)
        // The node's `claude` (EN-D13): a link a test puts there, to the fake's launcher.
        fake = try FakeClaude.install(in: testFolder.appendingPathComponent("fake-claude", isDirectory: true))
        try files.createSymbolicLink(atPath: testFolder.appendingPathComponent("claude").path, withDestinationPath: fake.launcher.path)
        recorder = try JournalRecorder(folder: testFolder)
        files.createFile(atPath: output, contents: nil)

        var arguments = ["--socket", socket, "--lock", lock, "--idle-exit", "600", "--log", root.appendingPathComponent("host.log").path,
                         "--server", nodeRoot.appendingPathComponent("bin/vibeswitcher-server").path, "--node-root", nodeRoot.path]
        if let userScopes { arguments += ["--server-arg", ServerArguments.testUserScopesFlag + userScopes.joined(separator: ",")] }
        if let housekeeping { arguments += ["--server-arg", ServerArguments.testHousekeepingFlag + String(housekeeping)] }
        if let testChild { arguments += ["--server-arg", ServerArguments.testChildFlag + testChild] }
        // The vault holds its first look, and the server knows it (its engine refuses `lead` until the accepts, S7).
        if holdFirstLook { arguments += ["--hold-first-look", "--server-arg", ServerArguments.testFirstLookFlag] }
        // How long the vault's `.user` seals verify (the engine plan's EN-D11), for a test that waits one out.
        if let sealLife { arguments += ["--test-user-seal-life", String(sealLife)] }
        process.executableURL = nodeRoot.appendingPathComponent("bin/vibeswitcher-host")
        process.environment = ["HOME": home.path, "CFFIXED_USER_HOME": home.path, "VIBESWITCHER_HOME": root.path, "SHELL": "/bin/sh",
                               "PATH": path, "TMPDIR": root.appendingPathComponent("tmp").path + "/"]
        let said = try FileHandle(forWritingTo: URL(fileURLWithPath: output))
        process.standardOutput = said
        process.standardError = said
        // The test process as the host's app too (stage 2's `TestHosts.connectAsApp`): one end of a pair as the host's
        // stdin, the other registered for its socket, so this process can start sessions on it.
        guard let (hostEnd, testEnd) = Platform.Sockets.pair(type: Platform.Sockets.seqpacket) else { throw CancellationError() }
        Platform.Sockets.enableCredentials(hostEnd)
        process.standardInput = FileHandle(fileDescriptor: hostEnd, closeOnDealloc: false)
        process.arguments = arguments + ["--test-app-pid", String(getpid()), "--test-app-connector", "0"]
        self.testEnd = testEnd
        HostConnection.register(connector: testEnd, for: socket)
        defer { Sys.close(hostEnd) }
        try process.run()
        ScratchNodes.started(process.processIdentifier)
        if waitForServer {
            // Its link welcomed (the hello carries the host's start): before, a state change is answered `not-yet`.
            let up = await eventually(timeout: 120) { [self] in (try? WireClient(self))?.hello.host.startedAt != nil }
            if !up { stop() }
            try #require(up, "the scratch node's server never answered: \(self.said)")
        }
    }

    deinit { stop() }

    /// The host's and its server's stderr and stdout so far.
    var said: String { (try? String(contentsOfFile: output, encoding: .utf8)) ?? "" }

    var hostPID: pid_t { process.processIdentifier }

    /// The server's socket.
    var serverSocket: String { root.appendingPathComponent("v2/server.sock").path }

    /// The server running now (the host's child named so), when there is one.
    var serverPID: pid_t? {
        // Started from a sealed copy (`/proc/self/fd/N`), its name is the descriptor's number: known by its argv[0].
        Platform.Processes.children(hostPID).first { Platform.Processes.arguments($0).first == "vibeswitcher-server" }
    }

    /// The environment the command line runs with on this node: its root, a home of its own, and `extra`.
    func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in ["CLAUDE_CONFIG_DIR", "CODEX_HOME", PeerFacts.sessionMarkerName] { environment[key] = nil }
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["VIBESWITCHER_HOME"] = root.path
        environment["TMPDIR"] = root.appendingPathComponent("tmp").path + "/"
        return environment.merging(extra) { $1 }
    }

    /// The built command line on this node, stdin /dev/null.
    func run(_ arguments: [String], _ extra: [String: String] = [:]) async throws -> CommandRun {
        try await VibeNodeTests.run(commandLine, arguments, environment: environment(extra))
    }

    /// The built command line, on a pty of its own (`runOnTerminal`, the code shown typed) when `tty`, else with stdin
    /// /dev/null (`run(_:_:)`): the plan's form.
    func run(_ arguments: [String], tty: Bool) async throws -> CommandRun {
        tty ? try await runOnTerminal(arguments) : try await run(arguments)
    }

    /// The built command line on a pty of its own (`script`), answering a typed word with `answer` (the code shown, by
    /// default, or nil for none): its status and what the terminal showed.
    func runOnTerminal(_ arguments: [String], answer: @escaping @Sendable (String) -> String? = { $0 }) async throws -> CommandRun {
        try await ScratchNodes.onTerminal(commandLine.path, arguments, environment: environment(), answer: answer)
    }

    /// Ends the host (SIGTERM, then SIGKILL), waits for its server to go, ends what is left of it, and removes the
    /// registration. Once.
    func stop() {
        let first = lockForStop.withLock { () -> Bool in
            defer { stopped = true }
            return !stopped
        }
        guard first else { return }
        let server = serverPID
        let host = hostPID
        if host > 0, process.isRunning {
            kill(host, SIGTERM)
            let deadline = MacTime.real.awake() + 10
            while process.isRunning, MacTime.real.awake() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(host, SIGKILL) }
            let killed = MacTime.real.awake() + 30
            while process.isRunning, MacTime.real.awake() < killed { Thread.sleep(forTimeInterval: 0.02) }
        }
        if let server {
            let deadline = MacTime.real.awake() + 10
            while kill(server, 0) == 0, MacTime.real.awake() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if kill(server, 0) == 0 { kill(server, SIGKILL) }
        }
        ScratchNodes.ended(host)
        recorder?.stop()
        if HostConnection.connector(for: socket) == testEnd { HostConnection.unregister(path: socket) }
        if testEnd >= 0 { Sys.close(testEnd) }
    }

    /// Starts `command` (a shell line) in a new session of this node's host, as its app, and returns it.
    func spawn(_ command: String, cwd: String? = nil, label: String = "Test") async throws -> HostSession {
        let request = SpawnRequest(cwd: cwd ?? home.path, command: command, env: [:], cols: 100, rows: 30, keepShell: false,
                                   label: label, agent: nil)
        let reply = try await offPool { [socket] in try HostCall.request(.spawn(request), socket: socket, appKey: nil, timeout: 60) }
        guard case .spawned(let session) = reply else { throw HostCall.Failure(description: "the scratch host didn't start the session: \(reply)") }
        return session
    }

    /// The host's sessions now.
    func sessions() throws -> [HostSession] { try HostCall.sessions(socket: socket, appKey: nil) }

    // MARK: The build folder and the stand-ins

    /// The built products this node's `bin/` links to.
    static let products = ["vibeswitcher-host", "vibeswitcher-server", "vibeswitcher-mcp", "vibeswitcher-hook", "vibeswitcher-cli"]

    /// Each product's SHA-256, read once per run.
    private static let hashes: [String: String] = {
        var hashes: [String: String] = [:]
        for name in products {
            if let data = FileManager.default.contents(atPath: builtProducts.appendingPathComponent(name).path) {
                hashes[name] = BuildInfo.sha256(of: data)
            }
        }
        return hashes
    }()

    /// `<folder>/bin/<product>` linked to each built product, and `<folder>/build-info` recording them.
    static func install(into folder: URL) throws {
        for name in products {
            try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("bin/" + name).path,
                                                       withDestinationPath: builtProducts.appendingPathComponent(name).path)
        }
        let info = BuildInfo(commit: String(repeating: "0", count: 40), binaries: hashes, swift: "test", resolved: String(repeating: "0", count: 64))
        try info.encoded.write(to: folder.appendingPathComponent(BuildInfo.fileName))
    }

    /// The stand-ins in `<root>/v2/test/`.
    static func standIns(in folder: URL, scopes: [String]?) throws {
        let record = folder.appendingPathComponent("journal.jsonl").path
        FileManager.default.createFile(atPath: record, contents: nil)
        try script("#!/bin/sh\ncat '\(record)'\nexit 0\n", at: folder.appendingPathComponent("journalctl"))
        try script("""
            #!/bin/sh
            case "$*" in
              *show-environment*) printf 'HOME=/home/test\\nLANG=C.UTF-8\\nPATH=/usr/bin:/bin\\nUSER=test\\nXDG_RUNTIME_DIR=/run/user/1000\\n' ;;
              *ExecMainStartTimestamp*) printf 'Result=success\\nExecMainStatus=0\\nExecMainStartTimestamp=\\n' ;;
            esac
            exit 0

            """, at: folder.appendingPathComponent("systemctl"))
        if let scopes { try (scopes.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("user-scopes"), atomically: true, encoding: .utf8) }
        // The binfmt_misc entries and mounts the command line reads on this node: interop off (both of WSL's entries,
        // as a machine with systemd has them), unless a test says otherwise.
        let binfmt = folder.appendingPathComponent("binfmt_misc", isDirectory: true)
        try FileManager.default.createDirectory(at: binfmt, withIntermediateDirectories: true)
        for (name, text) in ["WSLInterop": "disabled\ninterpreter /init\nflags: PF\n", "WSLInterop-late": "disabled\ninterpreter /init\nflags: P\n",
                             "status": "enabled\n"] {
            try text.write(to: binfmt.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try "".write(to: folder.appendingPathComponent("mounts"), atomically: true, encoding: .utf8)
    }

    /// A script at `url`, executable, written through a copy (no test process holds it open for writing, so no child
    /// started meanwhile makes running it fail with ETXTBSY).
    static func script(_ text: String, at url: URL) throws {
        let source = url.appendingPathExtension("txt")
        try text.write(to: source, atomically: true, encoding: .utf8)
        let copy = Process()
        copy.executableURL = URL(fileURLWithPath: "/bin/cp")
        copy.arguments = [source.path, url.path]
        copy.standardInput = FileHandle.nullDevice
        try copy.run()
        copy.waitUntilExit()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

/// journald's stand-in on a scratch node: a datagram socket at `<folder>/journal.sock`, each entry (journald's native
/// form, `Platform.Journal.decode`) recorded as one JSON line in `<folder>/journal.jsonl` with the fields journald
/// stamps from the sender's credentials (`_UID`, `_PID`, `_SYSTEMD_CGROUP`, read as the datagram comes) and
/// `__REALTIME_TIMESTAMP`, as `journalctl -o json` writes them.
final class JournalRecorder: @unchecked Sendable {
    let path: String
    let record: String
    private let fd: Int32
    private let lock = NSLock()
    private var stopping = false
    private let done = DispatchSemaphore(value: 0)

    init(folder: URL) throws {
        path = folder.appendingPathComponent("journal.sock").path
        record = folder.appendingPathComponent("journal.jsonl").path
        #if canImport(Glibc)
        let datagram = Int32(SOCK_DGRAM.rawValue)
        #else
        let datagram = SOCK_DGRAM
        #endif
        fd = Platform.Sockets.makeSocket(type: datagram)
        guard fd >= 0, let address = Platform.Sockets.unixAddress(path),
              Platform.Sockets.bindOwnerOnly(fd, to: address, path: path, mode: 0o600) == nil else { throw CancellationError() }
        Platform.Sockets.enableCredentials(fd)
        let thread = Thread { [self] in serve() }
        thread.name = "journal-recorder"
        thread.start()
    }

    private func serve() {
        defer { done.signal() }
        var buffer = [UInt8](repeating: 0, count: 70_000)
        while !lock.withLock({ stopping }) {
            var watched = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&watched, 1, 100) > 0 else { continue }
            let (count, sender) = buffer.withUnsafeMutableBytes { Platform.Sockets.receive(fd, into: $0) }
            guard count > 0, let fields = Platform.Journal.decode(Data(buffer[0..<count])) else { continue }
            var entry: [String: String] = [:]
            for (name, value) in fields { entry[name] = value }
            if let sender {
                entry["_PID"] = String(sender.pid)
                if case .record(let record) = Platform.Processes.record(sender.pid), let uid = record.uid { entry["_UID"] = String(uid) }
                if let lines = Platform.Processes.cgroup(sender.pid), let cgroup = PeerFacts.unifiedPath(lines) ?? PeerFacts.systemdPath(lines) {
                    entry["_SYSTEMD_CGROUP"] = cgroup
                }
            }
            entry["__REALTIME_TIMESTAMP"] = String(Int64(Date().timeIntervalSince1970 * 1_000_000))
            append(entry)
        }
    }

    /// One more entry in the record, as given (a test's own unit lines or forged ones).
    func append(_ entry: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        lock.withLock {
            guard let handle = FileHandle(forWritingAtPath: record) else { return }
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        }
    }

    /// The entries recorded so far.
    var entries: [JournalEntry] {
        NodeJournal.entries(json: (try? String(contentsOfFile: record, encoding: .utf8)) ?? "")
    }

    func stop() {
        let first = lock.withLock { () -> Bool in
            defer { stopping = true }
            return !stopping
        }
        guard first else { return }
        done.wait()
        Sys.close(fd)
    }
}

/// A client of a scratch node's server, as the command line is one, for the tests that speak the protocol themselves.
final class WireClient {
    let fd: Int32
    let hello: NodeWire.Hello
    private var lines = NodeWire.Lines()
    private var ready: [Data] = []
    private var counter = 0

    init(_ node: ScratchNode, timeout: TimeInterval = 10) throws {
        fd = try UnixSocket.connect(path: node.serverSocket)
        guard let first = Self.read(fd, &lines, &ready, until: Date().addingTimeInterval(timeout)),
              let hello = NodeWire.decode(NodeWire.Hello.self, first) else {
            Sys.close(fd)
            throw CancellationError()
        }
        self.hello = hello
    }

    deinit { Sys.close(fd) }

    /// Writes `line` (a newline added) as it is.
    func write(_ line: String) {
        let data = Data((line + "\n").utf8)
        _ = data.withUnsafeBytes { Platform.Sockets.send(fd, $0.baseAddress, $0.count) }
    }

    /// Sends a request and returns the messages up to its reply (the reply last), or up to a `bye` and the close.
    func request(_ kind: String, args: [String: NodeWire.Value]? = nil, action: String? = UUID().uuidString.lowercased(),
                 must: Bool? = nil, v: Int = NodeWire.version, timeout: TimeInterval = 60) -> [Data] {
        counter += 1
        let id = "t\(counter)"
        let request = NodeWire.Request(v: v, id: id, kind: kind, args: args, action: action, must: must)
        var line = NodeWire.line(request)
        line.removeLast()
        write(String(decoding: line, as: UTF8.self))
        return next(until: { NodeWire.decode(NodeWire.Envelope.self, $0)?.re == id }, timeout: timeout)
    }

    /// The messages that come until one `stop` accepts (it last), a `bye`, the close or `timeout`.
    func next(until stop: (Data) -> Bool = { _ in false }, timeout: TimeInterval = 10) -> [Data] {
        var got: [Data] = []
        let deadline = Date().addingTimeInterval(timeout)
        while let message = Self.read(fd, &lines, &ready, until: deadline) {
            got.append(message)
            if stop(message) || NodeWire.decode(NodeWire.Envelope.self, message)?.kind == "bye" { break }
        }
        return got
    }

    /// Whether the server closed the connection (a read gives its end) within `timeout`.
    func closed(within timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var chunk = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var watched = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&watched, 1, 100) > 0 else { continue }
            let count = Sys.read(fd, &chunk, chunk.count)
            if count == 0 { return true }
            if count < 0, errno != EAGAIN, errno != EINTR { return true }
        }
        return false
    }

    static func read(_ fd: Int32, _ lines: inout NodeWire.Lines, _ ready: inout [Data], until deadline: Date) -> Data? {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while ready.isEmpty {
            guard deadline.timeIntervalSinceNow > 0 else { return nil }
            var watched = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&watched, 1, 100) > 0 else { continue }
            let count = Sys.read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { return nil }
            ready += lines.append(Data(chunk[0..<count]))
        }
        return ready.removeFirst()
    }

    /// A reply among `messages`.
    static func reply(_ messages: [Data]) -> NodeWire.Reply? {
        messages.lazy.compactMap { message -> NodeWire.Reply? in
            guard NodeWire.decode(NodeWire.Envelope.self, message)?.re != nil else { return nil }
            return NodeWire.decode(NodeWire.Reply.self, message)
        }.first
    }

    /// A `bye` among `messages`.
    static func bye(_ messages: [Data]) -> NodeWire.Bye? {
        messages.lazy.compactMap { message -> NodeWire.Bye? in
            guard NodeWire.decode(NodeWire.Envelope.self, message)?.kind == "bye" else { return nil }
            return NodeWire.decode(NodeWire.Bye.self, message)
        }.first
    }
}

/// The scratch nodes' hosts started and not yet ended (ended at the runner's exit, as `TestHosts` ends its), and the
/// command line on a terminal.
enum ScratchNodes {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var running: Set<pid_t> = []
    private static let endedAtExit: Void = { atexit { ScratchNodes.killAll() } }()

    static func started(_ pid: pid_t) {
        _ = endedAtExit
        lock.withLock { _ = running.insert(pid) }
    }

    static func ended(_ pid: pid_t) { lock.withLock { _ = running.remove(pid) } }

    private static func killAll() { for pid in lock.withLock({ running }) { kill(pid, SIGKILL) } }

    /// `program` with `arguments` on a pty of its own (util-linux `script`), its terminal's output read as it comes;
    /// when it shows "Type CODE and Enter", `answer(CODE)` is typed (nothing when nil). Its status and what it showed.
    static func onTerminal(_ program: String, _ arguments: [String], environment: [String: String],
                           answer: @escaping @Sendable (String) -> String?) async throws -> CommandRun {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        let line = ([program] + arguments).map(FakeClaude.quoted).joined(separator: " ")
        process.arguments = ["-q", "-e", "-c", line, "/dev/null"]
        process.environment = environment.merging(["SHELL": "/bin/sh"]) { $1 }
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let shown = await offPool { () -> String in
            var seen = Data()
            var answered = false
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                seen.append(chunk)
                let text = String(decoding: seen, as: UTF8.self)
                if !answered, let range = text.range(of: #"Type ([A-Z]{4}) and Enter"#, options: .regularExpression) {
                    answered = true
                    let code = String(text[range].dropFirst(5).prefix(4))
                    if let typed = answer(code) { try? input.fileHandleForWriting.write(contentsOf: Data((typed + "\r").utf8)) }
                }
            }
            return String(decoding: seen, as: UTF8.self)
        }
        try? input.fileHandleForWriting.close()
        #expect(await exited(process, within: 120), "\(arguments.joined(separator: " ")) on a terminal never ended")
        return CommandRun(status: process.terminationStatus, output: shown, errors: "")
    }
}
