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
        let patience = isScratch ? 10 : Self.journalPatience
        // The writer the server's `journal.ack` uses too.
        let context = self
        let writer = JournalWriter(send: { Platform.Journal.send($0, to: socket) }, read: { context.sentEntries(nonce: $0) },
                                   patience: patience, pause: isScratch ? 0.01 : Self.journalPause)
        guard let written = writer.write(fields) else { return false }
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

    private(set) var fd: Int32
    private(set) var hello: NodeWire.Hello
    /// Where the request's journal entries go (`change`, `journal`).
    private let context: NodeContext
    private var lines = NodeWire.Lines()
    private var ready: [Data] = []
    private var counter = 0
    /// Whether the last `send` got no reply (the connection closed, a bye, the time passed): `change` journals such a
    /// state change as `unanswered`.
    private var unansweredLast = false

    private init(fd: Int32, hello: NodeWire.Hello, context: NodeContext, lines: NodeWire.Lines, ready: [Data]) {
        self.fd = fd
        self.hello = hello
        self.context = context
        self.lines = lines
        self.ready = ready
    }

    deinit { if fd >= 0 { Sys.close(fd) } }

    /// Before a request goes: when the server has closed this connection already (its end read, or a `bye`, as it does
    /// to one that sat with no request past its limit, `NodeServer.Idle`: a typed code can take longer than that to
    /// type), a new connection in its place, once and silently, the server checked again and its hello read. A
    /// connection still open, or one whose server can't be reached again, is left as it is: the request then says so.
    private func reconnectIfClosed() {
        var watched = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&watched, 1, 0) > 0 else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Sys.read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN { break }
            if count <= 0 { return _ = replace() }
            ready += lines.append(Data(chunk[0..<count]))
            if ready.contains(where: { NodeWire.decode(NodeWire.Bye.self, $0)?.kind == "bye" }) { return _ = replace() }
        }
    }

    /// This connection's descriptor, hello and lines taken from a new one to the same server; whether one was made. Its
    /// hello read last, so the request that follows goes at once (the server's limit for a connection's first request
    /// counts from its hello: nothing of this command line's own, the build's warning included, comes between).
    @discardableResult
    private func replace() -> Bool {
        guard case .success(let fresh) = NodeClient.connect(context, warn: false) else { return false }
        Sys.close(fd)
        (fd, hello, lines, ready) = (fresh.fd, fresh.hello, fresh.lines, fresh.ready)
        fresh.fd = -1
        return true
    }

    /// Connects to `context`'s server, checks it, and reads its hello. `warn`: say, once, when the server runs another
    /// build (a reconnect leaves it out: its request goes right after the hello).
    static func connect(_ context: NodeContext, timeout: TimeInterval = 15, warn: Bool = true) -> Result<NodeClient, Failure> {
        connectChecked(context, timeout: timeout, warn: warn).mapError(\.failure)
    }

    /// `connect`'s failure, and whether a refusal may be a server on its way out (`ServerCheck.Refusal.unsettled`).
    struct Checked: Error {
        var failure: Failure
        var unsettled = false
    }

    /// `connect`, telling a server on its way out (`unsettled`) from a refusal: a switch's waits look again at it.
    static func connectChecked(_ context: NodeContext, timeout: TimeInterval = 15, warn: Bool = true) -> Result<NodeClient, Checked> {
        if let unbuilt = context.usersNodeRefusal { return .failure(Checked(failure: .notRunning(unbuilt))) }
        let fd: Int32
        do {
            fd = try UnixSocket.connect(path: context.socketPath, patience: 1)
        } catch UnixSocket.Failure.system("connect", let code) where code == ENOENT || code == ECONNREFUSED {
            return .failure(Checked(failure: .notRunning("the node isn't running: no server answers at \(context.socketPath)")))
        } catch {
            return .failure(Checked(failure: .broken("the node's server couldn't be reached: \(error)")))
        }
        if let refusal = ServerCheck.verdict(fd: fd, context: context) {
            Sys.close(fd)
            return .failure(Checked(failure: .refused(refusal.text), unsettled: refusal.unsettled))
        }
        var lines = NodeWire.Lines()
        var ready: [Data] = []
        let first = read(fd, &lines, &ready, until: Platform.Clock.steadyDate().addingTimeInterval(timeout))
        let hello: NodeWire.Hello
        switch NodeWire.greeting(first) {
        case .success(let given): hello = given
        case .failure(let why):
            Sys.close(fd)
            return .failure(Checked(failure: .broken(ConfigSeal.inert(why.description, limit: 500))))
        }
        if warn { warnOfBuild(server: hello.server.commit) }
        return .success(NodeClient(fd: fd, hello: hello, context: context, lines: lines, ready: ready))
    }

    /// Whether this process said already that the server runs another build (`BuildMismatch`): once is enough.
    private static var warnedOfBuild = false

    /// Says, once, on stderr, when the server runs another build than this command line's own.
    private static func warnOfBuild(server: String) {
        guard !warnedOfBuild, let warning = BuildMismatch.warning(own: BuildMismatch.own(executable: "/proc/self/exe"), server: server) else { return }
        warnedOfBuild = true
        Say.err("vibeswitcher: \(warning)")
    }

    /// Whether this connection's server is on the Mac's rule (`VoiceRule.Mode.approval`): it asks the person at the Mac
    /// itself for each state change, so the command line shows what the request does and the word its dialog will
    /// carry, and asks no code (`TypedWord.ask`'s `approval`). Per connection: a confirmation of the command line's own
    /// (a journal acknowledgement) never takes it.
    var approvalRule: Bool { hello.rule == "approval" }

    /// How long a state change waits under the Mac's rule at least: the server's dialog (60 s) and its record.
    static let approvalPatience: TimeInterval = 120

    /// How long a request answered `not-yet` (the server's link to its host isn't welcomed yet) is asked again for.
    static let notYetPatience: TimeInterval = 15

    /// Whether `kind` goes only through `change`: it changes state (`NodeWire.changesState`, a kind this build doesn't
    /// know among them), or the vault records it (`Requests.recorded`: `start` too).
    static func changes(_ kind: String) -> Bool { NodeWire.changesState(kind) || Requests.recorded.contains(kind) }

    /// Sends one request that changes nothing (a read, a list) and waits for its reply (a `bye` instead, or the time
    /// passing, fails). A kind that changes state, or that the vault records, is refused here, unsent: it goes through
    /// `change`, after the typed word.
    func request(_ kind: String, args: [String: NodeWire.Value]? = nil, timeout: TimeInterval = 30) -> Result<NodeWire.Reply, Failure> {
        guard !Self.changes(kind) else {
            return .failure(.refused("\(kind) changes state: the command line sends it only after its typed code (NodeClient.change)"))
        }
        return send(kind, args: args, action: nil, timeout: timeout)
    }

    /// How a typed read went (`read`): its result, decoded; the server's refusal; or no answer.
    enum Read<R> {
        case success(R, raw: NodeWire.Value)
        case refused(NodeWire.Reply)
        case failure(Failure)

        /// The result made into another.
        func map<T>(_ make: (R) -> T) -> Read<T> {
            switch self {
            case .success(let result, let raw): return .success(make(result), raw: raw)
            case .refused(let reply): return .refused(reply)
            case .failure(let failure): return .failure(failure)
            }
        }
    }

    /// A typed read kind (`WireKind`, the architecture review's row 11): asked with its `args` (none when it takes
    /// none), its result decoded into its type, the reply's value kept beside it (`raw`, for `--json`, whole as the
    /// server sent it). How the command line asks a kind in `WireKinds.typed`: `WireKindsLintTests` refuses a
    /// `request("…")` of one.
    func read<K: WireKind>(_ kind: K.Type, _ args: K.Args, timeout: TimeInterval = 30) -> Read<K.Result> {
        Self.decoded(K.self, request(K.kind, args: Self.given(K.self, args), timeout: timeout))
    }

    /// A typed state-changing kind (`WireChangeKind`), sent as `change` sends one (the typed word's token, the journal
    /// entry as `when` says, the same refusals): its result decoded into its type. How the command line sends a kind in
    /// `WireKinds.changes`: `WireKindsLintTests` refuses a `change("…")` of one.
    func change<K: WireChangeKind>(_ kind: K.Type, _ args: K.Args, action: String, typed: Typed?, timeout: TimeInterval = 30,
                                   journal when: JournalWhen = .accepted) -> Read<K.Result> {
        Self.decoded(K.self, change(K.kind, args: Self.given(K.self, args), action: action, typed: typed, timeout: timeout, journal: when))
    }

    /// `args` as a request's: none for a kind that takes none, else its fields (those set).
    private static func given<K: WireKind>(_: K.Type, _ args: K.Args) -> [String: NodeWire.Value]? {
        switch NodeWire.Value(wire: args) {
        case .object(let fields) where !fields.isEmpty: return fields
        default: return K.Args.self == WireNoArgs.self ? nil : [:]
        }
    }

    private static func decoded<K: WireKind>(_: K.Type, _ sent: Result<NodeWire.Reply, Failure>) -> Read<K.Result> {
        switch sent {
        case .failure(let failure): return .failure(failure)
        case .success(let reply):
            guard reply.ok, let result = reply.result else { return .refused(reply) }
            do {
                return .success(try result.wire(K.Result.self), raw: result)
            } catch {
                return .failure(.broken("the node's server answered \(K.kind) in a form this command line doesn't read: \(error)"))
            }
        }
    }

    /// When `change` writes the request's journal entry: once the server accepted it (`accepted`: it answered, or its
    /// engine refused after the vault's record; the server's own refusals before it, `voice`, `stopping`, `not-yet`,
    /// aren't an accepted request), or only once it answered (`ok`).
    enum JournalWhen { case accepted, ok }

    /// The one way a state change is sent (the architecture review's row 5): `kind` with `action`, under `typed`, the
    /// token of the prompt that showed `action`'s word (`TypedWord.said`; nil only for a recorded kind that changes
    /// nothing, `start`, whose server asks no code). Then, as `when` says, the request's journal entry (ids only), so
    /// `status` finds the user's own request accounted for. A kind that doesn't change state is refused here: it is
    /// `request`'s.
    func change(_ kind: String, args: [String: NodeWire.Value]? = nil, action: String, typed: Typed?, timeout: TimeInterval = 30,
                journal when: JournalWhen = .accepted) -> Result<NodeWire.Reply, Failure> {
        guard Self.changes(kind) else { return .failure(.refused("\(kind) changes nothing: it is sent as a request, with no typed code")) }
        if NodeWire.changesState(kind), typed?.vouches(for: action) != true {
            return .failure(.refused("\(kind) wasn't sent: no typed code was asked for it"))
        }
        unansweredLast = false
        let answer = send(kind, args: args, action: action, timeout: timeout)
        if case .success(let reply) = answer, reply.ok || (when == .accepted && reply.error?.code == NodeWire.Code.refused.rawValue) {
            context.writeJournal(NodeJournal.entry(event: "request", action: action, kind: kind, epoch: hello.epoch))
        }
        // No reply came (the connection closed, a bye, the time passed): the action may have been recorded, and done,
        // before the server went, so its outcome isn't known; said with its id (`unanswered`) and journaled so.
        if case .failure = answer, unansweredLast {
            context.writeJournal(NodeJournal.entry(event: "unanswered", action: action, kind: kind, epoch: hello.epoch))
        }
        // A repeat of a done action whose result isn't kept (`Requests.repeatResult`: web.open's link, one too long for
        // the record): it was done, so a success, said here, as no command's own rendering knows the shape.
        if case .success(let reply) = answer, reply.ok, reply.result?["repeat"]?.bool == true {
            for line in reply.result?["say"]?.array ?? [] { Say.out(ConfigSeal.inert(line.string ?? "", limit: .max)) }
            exit(0)
        }
        return answer
    }

    /// The journal entry of an action the server took though `change` didn't see it accepted (a stop or a switch whose
    /// server ended before its reply), or that a batch did (each item recorded as its own action): under `typed`, the
    /// token of the prompt that asked.
    func journal(_ kind: String, action: String, typed: Typed) {
        context.writeJournal(NodeJournal.entry(event: "request", action: action, kind: kind, epoch: hello.epoch))
    }

    /// Sends one request and waits for its reply, the user seeing one outcome:
    /// - answered `not-yet`, it is asked again, a quarter second apart, for up to `notYetPatience`;
    /// - the connection ended with the server saying it took no request on it (its idle `bye`,
    ///   `NodeServer.tookNoRequest`), or before the request could be written: it wasn't received, so it is sent again on a
    ///   fresh connection, up to `notTakenTries` times, whatever host that one's server has; past them, said so (nothing
    ///   was done), never "isn't known". Safe even when part of the request's line reached the old server: a server
    ///   takes whole lines only, and a line it had whole would have been written whole (`sent`), so the server that
    ///   closed never took it;
    /// - the connection ended after it was sent, with no reply: sent once more on a fresh connection, with the same action
    ///   id, when that is safe (`resendable`: a kind the vault records by its action id, or one that changes nothing),
    ///   and, for a recorded kind, only when the fresh connection's hello names the same session host as the first's
    ///   (`sameHost`: its start and pid, both kept across a build switch's handover, which carries the vault): on Linux
    ///   the vault lives in the host's memory, so a host that restarted has no record of it, and the action would be
    ///   done twice; then it isn't sent again, and its outcome isn't known. The server's vault then answers: not recorded, it is done now, once, and its reply is the reply; recorded and
    ///   finished, its recorded outcome (the result, or that it was done at T, or the failure); recorded and still being
    ///   done (the same server), asked again until it is finished; recorded and begun on a server that ended, done again
    ///   when its kind allows, else that it began and its outcome isn't known (`Requests.retry`). Any other kind, or a
    ///   second loss, or no reply in `timeout`: its outcome isn't known (`unanswered`).
    private func send(_ kind: String, args: [String: NodeWire.Value]?, action: String?, timeout: TimeInterval) -> Result<NodeWire.Reply, Failure> {
        reconnectIfClosed()
        testCloseBeforeSend()
        let patience = Platform.Clock.steadyDate().addingTimeInterval(Self.notYetPatience)
        let timeout = approvalRule && NodeWire.changesState(kind) ? max(timeout, Self.approvalPatience) : timeout
        let deadline = Platform.Clock.steadyDate().addingTimeInterval(timeout)
        var notTaken = 0
        var resent = false
        var polls = 0
        // The host its request first went to (the connection's hello names it): a lost request is sent again only there.
        var host = hello.host
        while true {
            switch ask(kind, args: args, action: action, timeout: timeout) {
            case .reply(let reply):
                if reply.error?.code == NodeWire.Code.notYet.rawValue, Platform.Clock.steadyDate() < patience {
                    usleep(250_000)
                    continue
                }
                // Sent again after a loss and found under way (its first request's server still doing it): asked again.
                // Backing off to 1 s: each ask is a request the server judges.
                if resent, let action, reply.error?.message == Requests.beingDoneNow(action: action), Platform.Clock.steadyDate() < deadline {
                    polls += 1
                    usleep(useconds_t(min(1_000_000, 250_000 << min(polls - 1, 2))))
                    continue
                }
                return .success(reply)
            case .notTaken(let why):
                notTaken += 1
                guard notTaken <= Self.notTakenTries, reconnect() else { return .failure(.broken(Self.notTakenSaid(why, kind: kind))) }
                // Nothing was taken: whichever host this one's server has is the request's now.
                host = hello.host
            case .lost(let why):
                guard !resent, Self.resendable(kind, action: action), reconnect() else { return unanswered(kind, action, why) }
                if Requests.recorded.contains(kind), !Self.sameHost(host, hello.host) {
                    return unanswered(kind, action, why + "; the node's session host restarted since, and its record of actions with it, so it isn't sent again")
                }
                resent = true
            case .timedOut(let why):
                return unanswered(kind, action, why)
            case .failed(let failure):
                return .failure(failure)
            }
        }
    }

    /// Whether two hellos name the same session host: its start and its pid, both known and equal (a build switch's
    /// handover keeps both, and carries the vault).
    static func sameHost(_ first: NodeWire.Hello.Host, _ now: NodeWire.Hello.Host) -> Bool {
        guard let started = first.startedAt, let pid = first.pid else { return false }
        return now.startedAt == started && now.pid == pid
    }

    /// How many times a request the server said it didn't take is sent again.
    static let notTakenTries = 3
    /// How long a fresh connection is tried for, a quarter second apart: a server the host restarts (it ended) answers
    /// again within a few seconds.
    static let reconnectPatience: TimeInterval = 15

    /// A fresh connection in this one's place, tried for up to `reconnectPatience`; whether one was made.
    private func reconnect() -> Bool {
        let until = Platform.Clock.steadyDate().addingTimeInterval(Self.reconnectPatience)
        while true {
            if replace() { return true }
            guard Platform.Clock.steadyDate() < until else { return false }
            usleep(250_000)
        }
    }

    /// Whether a request whose connection ended after it was sent may be sent again on a fresh one: the vault records its
    /// kind by its action id, so a second ask is answered from the record and never does it twice; or it changes nothing.
    static func resendable(_ kind: String, action: String?) -> Bool {
        if Requests.recorded.contains(kind) { return action != nil }
        return !NodeWire.changesState(kind)
    }

    /// What is said of a request the server didn't take, `notTakenTries` times over: nothing was done.
    static func notTakenSaid(_ why: String, kind: String) -> String {
        "\(why): the node's server didn't take \(kind) (it closed the connection before reading it), so nothing was done; run the command again"
    }

    /// How a request went on one connection.
    private enum Asked {
        case reply(NodeWire.Reply)
        /// The server didn't take it: its bye says it took no request, or it couldn't be written.
        case notTaken(String)
        /// Sent, and the connection ended (its end, or another bye) before the reply.
        case lost(String)
        case timedOut(String)
        case failed(Failure)
    }

    /// A scratch node's test (`VIBESWITCHER_TEST_CLOSE_BEFORE_SEND=1`): once, after the check that the connection is
    /// open and before the request is written, waits (up to 10 s) for the server to close it, as a server whose limit
    /// runs out just then does. Never on the user's node.
    private func testCloseBeforeSend() {
        guard context.isScratch, !Self.closedBeforeSend, ProcessInfo.processInfo.environment["VIBESWITCHER_TEST_CLOSE_BEFORE_SEND"] == "1" else { return }
        Self.closedBeforeSend = true
        let until = Platform.Clock.steadyDate().addingTimeInterval(10)
        while Platform.Clock.steadyDate() < until {
            var watched = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&watched, 1, 100) > 0, watched.revents & Int16(POLLHUP) != 0 { return }
        }
    }
    private static var closedBeforeSend = false

    private func ask(_ kind: String, args: [String: NodeWire.Value]?, action: String?, timeout: TimeInterval) -> Asked {
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
        // Not written whole: the server had closed the connection, and never read the request.
        guard sent else { return .notTaken("the node's server closed the connection") }
        let deadline = Platform.Clock.steadyDate().addingTimeInterval(timeout)
        while let next = Self.read(fd, &lines, &ready, until: deadline) {
            guard let envelope = NodeWire.decode(NodeWire.Envelope.self, next) else { continue }
            if envelope.kind == "bye" {
                let bye = NodeWire.decode(NodeWire.Bye.self, next)
                let why = "the node's server closed the connection: \(ConfigSeal.inert(bye?.reason ?? "no reason", limit: .max))"
                return bye.map(NodeServer.tookNoRequest) == true ? .notTaken(why) : .lost(why)
            }
            if envelope.re == id, let reply = NodeWire.decode(NodeWire.Reply.self, next) { return .reply(reply) }
        }
        // An older server's reply past the line's limit (today's says so in a reply of its own: `NodeWire.replyLine`).
        if lines.tooLong { return .failed(.broken("the node's server answered \(kind) with a line past the limit of \(NodeWire.maxLine) bytes: ask for less")) }
        if Platform.Clock.steadyDate() < deadline {
            return .lost("the node's server closed the connection before answering \(kind) (it may have restarted)")
        }
        return .timedOut("the node's server didn't answer \(kind) in \(Int(timeout)) s")
    }

    /// No reply came to `kind`: `why`, and for a state change with an action id that id and that its outcome isn't
    /// known (it may have been recorded, and done, before the server went), which `change` journals (the
    /// architecture review's row 10).
    private func unanswered(_ kind: String, _ action: String?, _ why: String) -> Result<NodeWire.Reply, Failure> {
        guard let action, NodeWire.changesState(kind) else { return .failure(.broken(why)) }
        unansweredLast = true
        return .failure(.broken(Self.outcomeUnknown(why, action: action)))
    }

    /// What the command line says of a state change that got no reply.
    static func outcomeUnknown(_ why: String, action: String) -> String {
        "\(why). Action \(action): whether it was carried out isn't known; `vibeswitcher status` shows what is now"
    }

    /// The next whole line from `fd`, waiting until `deadline`; nil at the end, or past it.
    private static func read(_ fd: Int32, _ lines: inout NodeWire.Lines, _ ready: inout [Data], until deadline: Date) -> Data? {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while ready.isEmpty {
            let left = deadline.timeIntervalSince(Platform.Clock.steadyDate())
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
