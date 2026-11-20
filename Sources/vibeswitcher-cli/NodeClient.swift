import Foundation
import VibeCore
import VibeNode

/// Where the command line's node is and how it reads it (the engine plan's E1, EN-D8, EN-D15 and the Global
/// Constraints): the root (`NodeCheck.root`: a scratch node's `VibePaths.root`, the user's node's the account's), which check the server gets (`NodeCheck.mode`), and, for a scratch node,
/// its test's stand-ins under `<root>/v2/test/` in place of the user's journal and manager. A scratch node never
/// writes to `/run/systemd/journal/socket` and never runs `/usr/bin/journalctl` or `/usr/bin/systemctl`: without a
/// stand-in it says "scratch node: no journal, no manager".
struct NodeContext {
    let root: URL
    let mode: NodeCheck.Mode

    /// The context of this process: a scratch node when `VIBESWITCHER_HOME` names one; else the user's node, which on
    /// Linux, where `NodeFolders.mode` says pid 1 isn't systemd, was started detached and is checked by its record
    /// (the start plan's S3, ST-D6; read again with each context, so a start that wrote a new record sees it). A
    /// machine whose manager's socket is missing keeps the unit's check (its `MainPID` can't be read, so a server
    /// fails it), and `start` and `stop`'s fallback refuse it.
    static func current() -> NodeContext {
        let home = getenv("VIBESWITCHER_HOME").map { String(cString: $0) }
        let account = VibePaths.accountHome
        var mode = NodeCheck.mode(vibeswitcherHome: home, accountHome: account)
        // `Platform.Service.runtimeFolder` is nil on the Mac, whose user's node isn't built (`usersNodeRefusal`).
        if mode == .node, let runtime = Platform.Service.runtimeFolder(uid: getuid()), NodeFolders.mode(runtimeFolder: runtime) == .noSystemd {
            mode = .detached(record: NodeRecord.read(root: NodeFolders.nodeRoot(accountHome: account)))
        }
        return NodeContext(root: URL(fileURLWithPath: NodeCheck.root(of: mode, environmentRoot: VibePaths.root.path, accountHome: account), isDirectory: true),
                           mode: mode)
    }

    var isScratch: Bool { if case .scratch = mode { return true } else { return false } }

    /// Why the user's node can't be reached, started or stopped on this system (`NodeSystem`: the Mac's isn't built),
    /// or nil: always nil for a scratch node. Asked before anything else is read or run.
    var usersNodeRefusal: String? { isScratch ? nil : NodeSystem.usersNodeRefusal() }
    var socketPath: String { root.appendingPathComponent("v2/server.sock").path }
    var testFolder: URL { root.appendingPathComponent("v2/test", isDirectory: true) }
    static let noStandIn = "scratch node: no journal, no manager"

    /// A stand-in under `<root>/v2/test/` when this is a scratch node (nil when it isn't there); the system's path
    /// otherwise, nil where this system has no such tool (`Platform.Service`: no systemd tools on the Mac).
    private func tool(_ name: String, system: String?) -> String? {
        guard isScratch else { return system }
        let path = testFolder.appendingPathComponent(name).path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    var journalctl: String? { tool("journalctl", system: Platform.Service.journalctl) }
    var systemctl: String? { tool("systemctl", system: Platform.Service.systemctl) }
    var journalSocket: String? {
        guard isScratch else { return Platform.Journal.systemSocket }
        let path = testFolder.appendingPathComponent("journal.sock").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// The rule journal entries are checked by: the measured and documented terminal scopes, or a scratch node's
    /// test's (`<root>/v2/test/user-scopes`, one cgroup a line).
    var journalRule: VoiceRule {
        if isScratch, let text = FileManager.default.contents(atPath: testFolder.appendingPathComponent("user-scopes").path) {
            let scopes = String(decoding: text, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
            return VoiceRule(mode: .systemd, scopes: scopes.map { VoiceRule.Scope($0, basis: "a scratch node's test") }, uid: getuid(),
                             says: "a scratch node's test scopes")
        }
        return VoiceRule(mode: .systemd, scopes: VoiceRule.terminalScopes, uid: getuid(), says: "the terminal scopes")
    }

    /// The environment a tool runs with: on the user's node only `NodeStarter.environment` (`PATH=/usr/bin:/bin` and
    /// the manager's runtime folder from the uid, never this process's `XDG_RUNTIME_DIR` or bus address: the start
    /// plan's ST-D2); a scratch node's stand-ins get this process's.
    var toolEnvironment: [String]? { isScratch ? nil : NodeStarter.environment(runtimeFolder: NodeFolders.runtimeFolder(uid: getuid())) }

    /// `systemctl --user show-environment`'s text, or why it can't be had.
    func managerEnvironment() -> Result<String, NodeFacts.Failure> {
        guard let systemctl else { return .failure(.init(Self.noStandIn)) }
        guard let ran = runTool(systemctl, ["--user", "show-environment"]), ran.status == 0 else {
            return .failure(.init("systemctl --user show-environment didn't answer"))
        }
        return .success(ran.output)
    }

    /// What the machine says (`NodeFacts`); a scratch node's test may stand in for binfmt_misc and the mounts with
    /// the folder `<root>/v2/test/binfmt_misc` and `<root>/v2/test/mounts`. `managerEnvironment`: the manager's
    /// environment read already (`start` reads it once for the facts and its refusal); read here when nil.
    func facts(managerEnvironment read: Result<String, NodeFacts.Failure>? = nil) -> NodeFacts {
        func standIn(_ name: String, _ system: String) -> String {
            let path = testFolder.appendingPathComponent(name).path
            return isScratch && FileManager.default.fileExists(atPath: path) ? path : system
        }
        return NodeFacts.read(.machine(binfmtFolder: standIn("binfmt_misc", "/proc/sys/fs/binfmt_misc"),
                                       mountsFile: standIn("mounts", "/proc/mounts"),
                                       managerEnvironment: { read ?? managerEnvironment() }))
    }

    /// The journal entries the command line reads: the node unit's and its own, the user's only
    /// (`NodeJournal.readArguments`). nil, and why, when there is no journal to read.
    func journalEntries() -> Result<[JournalEntry], NodeFacts.Failure> {
        guard let journalctl else { return .failure(.init(Self.noStandIn)) }
        var entries: [JournalEntry] = []
        for arguments in NodeJournal.readArguments(uid: getuid()) {
            guard let ran = runTool(journalctl, arguments), ran.status == 0 else {
                return .failure(.init("journalctl --user didn't answer"))
            }
            entries += NodeJournal.entries(json: ran.output)
        }
        // The stand-in gives every entry for each match; a real journal gives each once. Once each either way.
        var seen = Set<[String: String]>()
        return .success(entries.filter { seen.insert($0.fields).inserted })
    }

    /// The unit's state (`systemctl --user show`); nil without a manager.
    func unitState() -> NodeJournal.UnitState? {
        guard let systemctl, let ran = runTool(systemctl, ["--user", "show", "-p", "Result,ExecMainStatus,ExecMainStartTimestamp,ExecMainPID", VoiceRule.nodeUnit]),
              ran.status == 0 else { return nil }
        return NodeJournal.unitState(show: ran.output)
    }

    /// How long the user's node's command line waits for journald to show an entry it sent, and how long between two
    /// looks (each a `journalctl` run).
    static let journalPatience: TimeInterval = 5
    static let journalPause: TimeInterval = 0.02

    /// Writes an entry of the command line's, and stays until the journal holds it: true only when it does, with the
    /// cgroup journald read for this process. journald reads a writer's `/proc/<pid>/cgroup` as it takes the datagram,
    /// not as the datagram is sent, and an entry counts only by that cgroup (`NodeJournal.passes`): a command line
    /// that ended right after its datagram left an entry that never counted (measured, the bootstrap path's M4,
    /// 2026-11-17). So the entry carries a nonce (`NodeJournal.entryField`) and is looked for again, up to
    /// `journalPatience` (`NodeJournal.awaitEntry`): on the user's node with `journalctl --user` on the nonce
    /// (`NodeJournal.entryArguments`); on a scratch node in its stand-in's record (`journal.jsonl`, up to 10 s), which
    /// stamps each entry with the sender's credentials as the datagram comes, as journald does.
    ///
    /// False when there is no journal or the datagram didn't go; false too, with a line on stderr saying which
    /// (`NodeJournal.notCounted`), when the entry never showed or journald recorded no cgroup for it (it couldn't
    /// read this process, which was there: not the writer that ended first that `status` speaks of).
    @discardableResult
    func writeJournal(_ fields: [(name: String, value: String)]) -> Bool {
        guard let socket = journalSocket else { return false }
        let nonce = UUID().uuidString.lowercased()
        guard Platform.Journal.send(fields + [(NodeJournal.entryField, nonce)], to: socket) else { return false }
        let patience = isScratch ? 10 : Self.journalPatience
        let written = NodeJournal.awaitEntry(nonce: nonce, patience: patience, pause: isScratch ? 0.01 : Self.journalPause,
                                             awake: MacTime.real.awake, sleep: { usleep(useconds_t($0 * 1_000_000)) },
                                             read: { sentEntries(nonce: nonce) })
        let event = fields.first { $0.name == "VIBESWITCHER_EVENT" }?.value ?? "?"
        if let why = NodeJournal.notCounted(written, event: event, patience: patience) { Say.err("vibeswitcher: \(why)") }
        return written == .recorded
    }

    /// The journal's entries that carry `nonce`, as it holds them now; nil when it can't be read this time. The user's
    /// node's: `journalctl --user` matched on the nonce, by its fixed path and with the tools' environment
    /// (`toolEnvironment`), whatever its status (one that finds nothing prints no entry).
    /// A scratch node's: its stand-in's record, the lines naming the nonce.
    private func sentEntries(nonce: String) -> [JournalEntry]? {
        if isScratch {
            guard let text = FileManager.default.contents(atPath: testFolder.appendingPathComponent("journal.jsonl").path) else { return nil }
            let lines = String(decoding: text, as: UTF8.self).split(whereSeparator: \.isNewline).filter { $0.contains(nonce) }
            return NodeJournal.entries(json: lines.joined(separator: "\n"))
        }
        // One look is bounded by the wait's own patience, not the minute a tool gets elsewhere.
        guard let journalctl, let ran = NodeStarter.run(journalctl, NodeJournal.entryArguments(nonce: nonce, uid: getuid()),
                                                        environment: toolEnvironment, timeout: Self.journalPatience) else { return nil }
        return NodeJournal.entries(json: ran.output)
    }

    /// Runs `program` (by its absolute path, never looked up) with `arguments`, stdin /dev/null, with `toolEnvironment`;
    /// its status and stdout. nil when it can't be started or doesn't end within a minute.
    func runTool(_ program: String, _ arguments: [String]) -> (status: Int32, output: String)? {
        NodeStarter.run(program, arguments, environment: toolEnvironment, timeout: 60)
    }
}

/// One connection to the node's server (the engine plan's "The protocol"): connect, the server checked (`ServerCheck`),
/// its `hello` read, then a request and its reply.
final class NodeClient {
    enum Failure: Error {
        /// No server: "the node isn't running" (exit 69).
        case notRunning(String)
        /// The server reached isn't the node's (exit 77).
        case refused(String)
        /// Anything else (exit 1).
        case broken(String)

        var message: String {
            switch self {
            case .notRunning(let why), .refused(let why), .broken(let why): return why
            }
        }

        var exitCode: Int32 {
            switch self {
            case .notRunning: return 69
            case .refused: return 77
            case .broken: return 1
            }
        }
    }

    let fd: Int32
    let hello: NodeWire.Hello
    private var lines = NodeWire.Lines()
    private var ready: [Data] = []
    private var counter = 0

    private init(fd: Int32, hello: NodeWire.Hello, lines: NodeWire.Lines, ready: [Data]) {
        self.fd = fd
        self.hello = hello
        self.lines = lines
        self.ready = ready
    }

    deinit { Sys.close(fd) }

    /// Connects to `context`'s server, checks it, and reads its hello.
    static func connect(_ context: NodeContext, timeout: TimeInterval = 15) -> Result<NodeClient, Failure> {
        if let unbuilt = context.usersNodeRefusal { return .failure(.notRunning(unbuilt)) }
        let fd: Int32
        do {
            fd = try UnixSocket.connect(path: context.socketPath, patience: 1)
        } catch UnixSocket.Failure.system("connect", let code) where code == ENOENT || code == ECONNREFUSED {
            return .failure(.notRunning("the node isn't running: no server answers at \(context.socketPath)"))
        } catch {
            return .failure(.broken("the node's server couldn't be reached: \(error)"))
        }
        if let refusal = ServerCheck.refusal(fd: fd, context: context) {
            Sys.close(fd)
            return .failure(.refused(refusal))
        }
        var lines = NodeWire.Lines()
        var ready: [Data] = []
        guard let first = read(fd, &lines, &ready, until: Date().addingTimeInterval(timeout)),
              let hello = NodeWire.decode(NodeWire.Hello.self, first), hello.kind == "hello" else {
            Sys.close(fd)
            return .failure(.broken("the node's server sent no hello"))
        }
        return .success(NodeClient(fd: fd, hello: hello, lines: lines, ready: ready))
    }

    /// How long a request answered `not-yet` (the server's link to its host isn't welcomed yet) is asked again for.
    static let notYetPatience: TimeInterval = 15

    /// Sends one request and waits for its reply (a `bye` instead, or the time passing, fails). Answered `not-yet`, it
    /// is asked again, a quarter second apart, for up to `notYetPatience`; then the last answer is the reply.
    func request(_ kind: String, args: [String: NodeWire.Value]? = nil, action: String? = nil,
                 timeout: TimeInterval = 30) -> Result<NodeWire.Reply, Failure> {
        let patience = Date().addingTimeInterval(Self.notYetPatience)
        while true {
            let answer = ask(kind, args: args, action: action, timeout: timeout)
            guard case .success(let reply) = answer, reply.error?.code == NodeWire.Code.notYet.rawValue, Date() < patience else { return answer }
            usleep(250_000)
        }
    }

    private func ask(_ kind: String, args: [String: NodeWire.Value]?, action: String?, timeout: TimeInterval) -> Result<NodeWire.Reply, Failure> {
        counter += 1
        let id = "\(getpid())-\(counter)"
        let line = NodeWire.line(NodeWire.Request(id: id, kind: kind, args: args, action: action))
        let sent = line.withUnsafeBytes { bytes -> Bool in
            var offset = 0
            while offset < bytes.count {
                let written = Platform.Sockets.send(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0, errno == EINTR || errno == EAGAIN { usleep(1_000); continue }
                return false
            }
            return true
        }
        guard sent else { return .failure(.broken("the node's server closed the connection")) }
        let deadline = Date().addingTimeInterval(timeout)
        while let next = Self.read(fd, &lines, &ready, until: deadline) {
            guard let envelope = NodeWire.decode(NodeWire.Envelope.self, next) else { continue }
            if envelope.kind == "bye" {
                let reason = NodeWire.decode(NodeWire.Bye.self, next)?.reason ?? "no reason"
                return .failure(.broken("the node's server closed the connection: \(ConfigSeal.inert(reason, limit: .max))"))
            }
            if envelope.re == id, let reply = NodeWire.decode(NodeWire.Reply.self, next) { return .success(reply) }
        }
        // An older server's reply past the line's limit (today's says so in a reply of its own: `NodeWire.replyLine`).
        if lines.tooLong { return .failure(.broken("the node's server answered \(kind) with a line past the limit of \(NodeWire.maxLine) bytes: ask for less")) }
        return .failure(.broken("the node's server didn't answer \(kind)"))
    }

    /// The next whole line from `fd`, waiting until `deadline`; nil at the end, or past it.
    private static func read(_ fd: Int32, _ lines: inout NodeWire.Lines, _ ready: inout [Data], until deadline: Date) -> Data? {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while ready.isEmpty {
            let left = deadline.timeIntervalSinceNow
            guard left > 0, !lines.tooLong else { return nil }
            var watched = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let woke = poll(&watched, 1, Int32(min(left * 1_000, 60_000)))
            if woke < 0, errno == EINTR { continue }
            guard woke > 0 else { continue }
            let count = Sys.read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { return nil }
            ready += lines.append(Data(chunk[0..<count]))
        }
        return ready.removeFirst()
    }
}
