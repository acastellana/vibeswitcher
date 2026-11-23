import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The engine's cards on a scratch host in the test process (the engine plan's E6): a `DeliveryWorld` (its host, its
/// repository, its link and engine) with the server's requests on the same link (`Requests`, no session list, the
/// weaker voice rule), so a case asks what the command line asks, as the user (`user`) or as a lead's tool server
/// (`toolServer`), and the lead's posts carry the host's real `.lead` seal. What a case calls on `Requests` it calls on
/// the engine's queue, where `NodeServer` calls it.
final class CardWorld: @unchecked Sendable {
    let world: DeliveryWorld
    let requests: Requests
    /// The world's engine, or one on the same link asking another vault for its cards.
    let engine: LeadEngine
    var host: NodeTestHost { world.host }
    var repo: String { world.repo }
    var queue: DispatchQueue { world.queue }

    /// A peer that is the user's voice under the weaker rule (no cgroup read). Its pid and terminal are no real
    /// process's or terminal's: the voice rule refuses a peer on a live session's terminal or under its program, and a
    /// scratch host's sessions get real pseudo-terminals, numbered from 0 on a machine where nothing else holds one (a
    /// CI runner, where a lead on "ttypts0" made every answer from a user on "ttypts0" not the user's). Above the
    /// highest pid either system gives (Linux's `PID_MAX_LIMIT`, 4194304), and a name no pseudo-terminal has.
    static let user = PeerFacts(pid: userPID, uid: getuid(), cgroup: nil, ancestry: [.init(pid: userPID, startTicks: 5)],
                                terminal: .named(userTerminal), sessionMarker: false, underRunner: false)
    static let userPID: pid_t = 9_000_900
    static let userTerminal = "ttytest-user"
    static let rule = VoiceRule(mode: .weaker, scopes: [], uid: getuid(), says: "a test's")

    private init(world: DeliveryWorld, engine: LeadEngine) {
        self.world = world
        self.engine = engine
        requests = Requests(link: world.link, sessions: nil, rule: Self.rule, root: world.host.root, hostSocket: world.host.socket,
                            commit: "test", hostPID: 1)
        requests.shutdown = { .error("not in this test") }
        requests.engine = engine
    }

    /// A world on a new scratch host; its cards built from and answers recorded in `vault` when given (the host's
    /// otherwise).
    static func make(_ scratch: Scratch, vault: ((NodeTestHost) -> LeadVault)? = nil) async throws -> CardWorld {
        let world = try await DeliveryWorld.make(scratch)
        guard let vault else { return CardWorld(world: world, engine: world.engine) }
        var options = LeadEngine.Options()
        options.answersTrust = false
        options.home = world.host.home.path
        options.vault = vault(world.host)
        return CardWorld(world: world, engine: LeadEngine(root: world.host.root, nodeRoot: nil, link: world.link, clock: nil, options: options))
    }

    /// A world whose engine has `plugins` (in place of the registry's list), on the host's vault.
    static func make(_ scratch: Scratch, plugins: [FeaturePlugin], bind: WebBind? = nil, note: @escaping (String) -> Void = { _ in }) async throws -> CardWorld {
        let world = try await DeliveryWorld.make(scratch)
        var options = LeadEngine.Options()
        options.answersTrust = false
        options.home = world.host.home.path
        options.plugins = plugins
        options.pluginBind = bind
        return CardWorld(world: world, engine: LeadEngine(root: world.host.root, nodeRoot: nil, link: world.link, clock: nil, options: options, note: note))
    }

    /// Stops the world, expecting every answer its server gave came on the requests' queue (`Requests.offQueueReplies`).
    func stop() {
        #expect(requests.offQueueReplies.isEmpty, "answered off the requests' queue: \(requests.offQueueReplies.sorted())")
        world.stop()
    }

    var project: String { NodeIds.project(root: repo) }

    /// The host's vault records `named` as workflow.md's accepted base branch (what `config accept` records under
    /// `ConfigHoldStore.baseBranchKey`; "" for none named: the main branch), which an approval card's files and diffstat
    /// are taken against.
    func acceptBase(_ named: String = "") async throws {
        let (vault, repo) = (host.vault, repo)
        try await offPool { try vault.setGuardedSettings([ConfigHoldStore.baseBranchKey: LeadVault.hash(named)], root: repo) }
    }

    // MARK: Asking

    /// `kind` with `args`, from `facts` (the user by default), with a new action id unless given: its reply.
    func ask(_ kind: String, _ args: [String: NodeWire.Value] = [:], action: String? = UUID().uuidString.lowercased(),
             from facts: PeerFacts = CardWorld.user, timeout: TimeInterval = 120) async -> NodeWire.Reply? {
        let reply = Locked<NodeWire.Reply?>(nil)
        let request = NodeWire.Request(id: UUID().uuidString, kind: kind, args: args, action: action)
        queue.async { self.requests.handle(request, from: facts) { answer in reply.value = answer } }
        _ = await eventually(timeout: timeout) { reply.value != nil }
        return reply.value
    }

    /// The card the server holds with `id`, now.
    func card(_ id: String) -> CardStore.Card? { queue.sync { engine.cards.cards[id] } }

    /// The question or approval card of `question`, now.
    func card(question: LeadQuestion, root: String? = nil) -> CardStore.Card? {
        queue.sync { engine.cards.card(question: question.id, root: root ?? repo) }
    }

    /// `answer` on `card` with its code (or `code`), bound to `version` when given.
    func answer(_ card: CardStore.Card, _ text: String, code: String? = nil, version: Int? = nil,
                action: String = UUID().uuidString.lowercased(), from facts: PeerFacts = CardWorld.user) async -> NodeWire.Reply? {
        var args: [String: NodeWire.Value] = ["card": .string(card.id), "code": .string(code ?? card.code), "text": .string(text)]
        if let version { args["version"] = .int(version) }
        return await ask("answer", args, action: action, from: facts)
    }

    // MARK: The lead's questions

    /// A lead session for `root` (this world's repository by default) that runs nothing but `sleep`: labelled as its lead
    /// and bound to its lead role in the host's vault (enough to post as its tool server).
    /// `branch`: the branch it starts on (the vault records its head then).
    func sleepingLead(root: String? = nil, branch: String = "main") async throws -> HostSession {
        let root = root ?? repo
        let session = try await host.spawn("exec /bin/sleep 600", cwd: root, label: "Lead · \((root as NSString).lastPathComponent)")
        let vault = host.vault
        try await offPool {
            try vault.bind(try vault.startLead(root: root, branch: branch), root: root, session: session.id.uuidString)
            try BoardStore(root: root).prepare()
        }
        return session
    }

    /// What the server reads of a process of `session` (its tool server, a child of its program), or of branch code
    /// under it (`runner`).
    static func toolServer(of session: HostSession, runner: Bool = false) -> PeerFacts {
        PeerFacts(pid: 77_001, uid: getuid(), cgroup: nil, ancestry: [.init(pid: 77_001, startTicks: 9), .init(pid: session.childPID, startTicks: 3)],
                  terminal: .named(session.tty), sessionMarker: true, underRunner: runner)
    }

    /// The board asks `text` (as `ask_user` writes it) in `root`.
    func boardAsks(_ text: String, options: [String] = [], priority: LeadQuestion.Priority? = nil, proposal: String? = nil,
                   decideIn: Int? = nil, root: String? = nil) throws -> LeadQuestion {
        try BoardStore(root: root ?? repo).update { board in
            board.ask(text, options: options, priority: priority, whyNow: nil, proposal: proposal, decideIn: decideIn)
        }
    }

    /// The post of `question` for `root` as the lead's tool server makes it (`NodeQuestionPost`): sealed by the host as
    /// `sealer`'s session (the lead's by default), sent from `facts` (the lead's tool server by default).
    func post(_ question: LeadQuestion, op: NodeQuestionPost.Op = .post, lead: HostSession, root: String? = nil, name: String? = nil,
              sealer: HostSession? = nil, facts: PeerFacts? = nil) async throws -> NodeWire.Reply? {
        try await post(text: NodeQuestionPost.encoded(question), op: op, lead: lead, root: root, name: name, sealer: sealer, facts: facts)
    }

    /// `post` of the JSON `text` (a question's, or a revision's for `.revise`).
    func post(text: Data, op: NodeQuestionPost.Op, lead: HostSession, root: String? = nil, name: String? = nil,
              sealer: HostSession? = nil, facts: PeerFacts? = nil) async throws -> NodeWire.Reply? {
        let root = root ?? repo
        let message = NodeQuestionPost.sealed(digest: NodeQuestionPost.digest(op: op, root: root, question: text), root: root,
                                              id: UUID().uuidString.lowercased(), at: Date().timeIntervalSince1970)
        var named = message
        if let name { named.from = .lead(name) }
        let sealing = (sealer ?? lead).id.uuidString
        let book = host.book
        let seal = try await offPool { try book.vault(folder: self.host.folder, as: { .session(sealing) }).seal(named) }
        let args: [String: NodeWire.Value] = [
            "root": .string(root), "question": .string(String(decoding: text, as: UTF8.self)),
            "seal": .object(["id": .string(message.id), "at": .string(String(message.at)), "name": .string(name ?? NodeQuestionPost.leadName(root: root)),
                             "seal": .string(seal)]),
        ]
        return await ask(op.rawValue, args, action: nil, from: facts ?? Self.toolServer(of: lead))
    }

    /// The lead's `revise_question` of question `id`: the board revised (`LeadBoard.revise`), then what the lead gave
    /// posted (`NodeQuestionPost.Revision`), as the tool posts it. The board's question after the revision, and the
    /// server's reply.
    func revise(_ id: String, text: String?, options: [String]?, note: String, lead: HostSession) async throws -> (board: LeadQuestion, reply: NodeWire.Reply?) {
        let revised = try BoardStore(root: repo).update { try $0.revise(id, text: text, options: options, note: note) }
        let revision = NodeQuestionPost.Revision(id: revised.id, text: text, options: options, note: note)
        return (revised, try await post(text: NodeQuestionPost.encoded(revision), op: .revise, lead: lead))
    }

    /// The board asks `text` and the lead's tool server posts it: its card.
    func asked(_ text: String, options: [String] = [], priority: LeadQuestion.Priority? = nil, proposal: String? = nil, decideIn: Int? = nil,
               lead: HostSession) async throws -> (question: LeadQuestion, card: CardStore.Card) {
        let question = try boardAsks(text, options: options, priority: priority, proposal: proposal, decideIn: decideIn)
        let reply = try #require(try await post(question, lead: lead))
        try #require(reply.ok, "\(reply)")
        let card = try #require(self.card(question: question))
        return (question, card)
    }

    /// The board as it is now.
    func board(root: String? = nil) -> LeadBoard { BoardStore(root: root ?? repo).load() }

    /// The vault's record of the user's actions now.
    func actions() async -> [LeadVaultV2.UserAction] {
        let client = world.link.vaultV2
        return await offPool { (try? client.userActions()) ?? [] }
    }

    /// What's held for the project's lead, or waits in its inbox (the lead `harness` when it runs).
    func held() -> [LeadStore.Held] { queue.sync { engine.leads.held[project] ?? [] } }

    /// Everything asked of the engine's reads queue, its queue and its work so far has run.
    func drained() async {
        await offPool {
            for _ in 0..<3 {
                self.engine.reads.queue.sync {}
                self.engine.work.sync(flags: .barrier) {}
                self.queue.sync {}
            }
        }
    }
}

/// A scratch repository at `folder` with a commit on `main` and a branch `agent/<task>` one commit ahead (its file
/// `name` changed), back on `main`: the branch's commit.
@discardableResult
func taskBranch(_ folder: String, task: String, file name: String = "a.txt", subject: String = "change") async throws -> String {
    func git(_ arguments: [String]) async throws -> String { try await scratchGit(folder, arguments) }
    _ = try await git(["checkout", "-q", "-b", "agent/\(task)"])
    try "\(task)\n".write(toFile: (folder as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8)
    _ = try await git(["add", "--", name])
    _ = try await git(["commit", "-q", "-m", subject])
    let commit = try await git(["rev-parse", "HEAD"])
    _ = try await git(["checkout", "-q", "main"])
    return commit
}

/// `git -C folder arguments…` on a scratch repository, with no user or system config: its output, trimmed.
@discardableResult
func scratchGit(_ folder: String, _ arguments: [String]) async throws -> String {
    let environment = ["HOME": folder, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                       "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
                       "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid"]
    let ran = try await run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", folder] + arguments, environment: environment)
    guard ran.status == 0 else { throw HostCall.Failure(description: "git \(arguments.joined(separator: " ")): \(ran.errors)") }
    return ran.output.trimmingCharacters(in: .whitespacesAndNewlines)
}
