import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// A scratch host in the test process (`NodeTestHost`), a repository with one commit, and the engine on a link to the
/// host with its own root, queue and home (the engine plan's E5): what `DeliveryTests` and `WakeTests` deliver to and
/// type into. Its leads are `FakeClaude` (`NodeHarness`) in sessions labelled as the repository's lead, each bound to
/// the lead's role in the host's vault and named on the board as its tool server names it. What the engine does with
/// them it is asked on its queue, as the server asks it; what it types and why it didn't is recorded (`steps`).
final class DeliveryWorld: @unchecked Sendable {
    let host: NodeTestHost
    let fake: FakeClaude.Install
    let repo: String
    let link: HostLink
    let engine: LeadEngine
    let queue = DispatchQueue(label: "delivery-tests.engine")
    private let key = DispatchSpecificKey<Bool>()
    /// Every step of typing into a session, in order.
    let steps = Locked<[WakeStep]>([])
    /// What was typed into each session, as the writes sent.
    let typed = Locked<[(session: UUID, writes: [HostInput.Write])]>([])
    /// Called with each step as it's recorded, on the engine's queue (a test's hook into the moment).
    let onStep = Locked<(WakeStep) -> Void>({ _ in })

    /// The node's session scan on the link (`scan`), started with the world: the agents its fakes are (E7's witness).
    let sessions: NodeSessions?

    private init(host: NodeTestHost, fake: FakeClaude.Install, repo: String, scan: Bool, sweepsRoles: Bool, plugins: [FeaturePlugin]? = nil,
                 pluginBind: WebBind? = nil, note: @escaping (String) -> Void = { _ in }, vault: ((NodeTestHost) -> LeadVault)? = nil) {
        self.host = host
        self.fake = fake
        self.repo = repo
        queue.setSpecific(key: key, value: true)
        link = HostLink(dialer: host.dialer, root: host.root, queue: queue)
        sessions = scan ? NodeSessions(root: host.root, home: host.home.path, queue: queue, link: link) : nil
        var options = LeadEngine.Options()
        options.answersTrust = false
        options.home = host.home.path
        options.sweepsRoles = sweepsRoles
        options.plugins = plugins
        options.pluginBind = pluginBind
        options.vault = vault?(host)
        engine = LeadEngine(root: host.root, nodeRoot: nil, link: link, clock: nil, sessions: sessions, options: options, note: note)
        let (engine, steps, typed, onStep) = (engine, steps, typed, onStep)
        link.onWelcome = { _, _ in engine.welcomed() }
        queue.sync {
            // The disk watch (E7) reads no real volume unless a case gives it one: a full disk here isn't the case's.
            engine.freeSpace = { _ in nil }
            engine.wakeStep = { step in
                steps.mutate { $0.append(step) }
                onStep.value(step)
            }
            engine.typing = { id, writes in typed.mutate { $0.append((id, writes)) } }
        }
    }

    /// A world on a new scratch host, its link welcomed unless `connect` is false.
    /// `scan`: with the node's session scan (`NodeSessions`) on the link, started once it's welcomed. `sweepsRoles`: the
    /// engine ends the finished tasks' role sessions from the host's roster, as the server's does (`RoleSweep`).
    /// `plugins`, `pluginBind`, `note`: the world's one engine's (a second engine on the same root and link would answer
    /// the same welcomes and write the same plugin files).
    static func make(_ scratch: Scratch, connect: Bool = true, scan: Bool = false, sweepsRoles: Bool = false, plugins: [FeaturePlugin]? = nil,
                     pluginBind: WebBind? = nil, note: @escaping (String) -> Void = { _ in },
                     vault: ((NodeTestHost) -> LeadVault)? = nil) async throws -> DeliveryWorld {
        let host = try NodeTestHost(scratch)
        let fake = try FakeClaude.install(in: host.folder.appendingPathComponent("fake", isDirectory: true))
        let repo = host.folder.appendingPathComponent("repo", isDirectory: true)
        try await scratchRepository(repo)
        let world = DeliveryWorld(host: host, fake: fake, repo: repo.resolvingSymlinksInPath().path, scan: scan, sweepsRoles: sweepsRoles,
                                  plugins: plugins, pluginBind: pluginBind, note: note, vault: vault)
        if connect { await world.connect() }
        if let sessions = world.sessions { world.queue.sync { sessions.start() } }
        return world
    }

    /// Another engine on the same link and root, as a restarted server's: it takes back what `engine.json` holds.
    /// `userActions`: the record a held `.user` message is vouched for by (none passes by default; the server gives the
    /// vault's, `VaultUserActions`).
    func restarted(userActions: UserActions? = nil) -> LeadEngine {
        var options = LeadEngine.Options()
        options.answersTrust = false
        options.home = host.home.path
        if let userActions { options.userActions = userActions }
        return LeadEngine(root: host.root, nodeRoot: nil, link: link, clock: nil, options: options)
    }

    func connect() async {
        link.start()
        _ = await eventually(timeout: 60) { self.queue.sync { self.link.state == .connected } }
    }

    func stop() {
        if let sessions { queue.sync { sessions.stop() } }
        host.stop()
    }

    var project: String { NodeIds.project(root: repo) }
    var name: String { (repo as NSString).lastPathComponent }

    /// Whether the calling code runs on the engine's queue.
    var onEngine: Bool { DispatchQueue.getSpecific(key: key) == true }

    /// The project's lead as the engine's store has it now.
    var stored: LeadStore.Lead? { queue.sync { engine.leads.leads[project] } }

    /// What's held for the project's lead now.
    func held() -> [LeadStore.Held] { queue.sync { engine.leads.held[project] ?? [] } }

    /// A lead: the fake started in a session labelled as the repository's lead (`keepShell`: its shell stays once the
    /// fake exits), its role bound to that session in the host's vault, and the board naming it with its pid and
    /// terminal, as its tool server names it. Between turns (its hooks said Stop) when `idle`, else mid-turn
    /// (PreToolUse). Returned once the engine's store has the project's lead running there.
    func lead(keepShell: Bool = false, idle: Bool = true) async throws -> NodeHarness {
        let harness = try await NodeHarness.start(on: host, fake: fake, cwd: repo, label: "Lead · \(name)", keepShell: keepShell)
        let pid = try #require(harness.agentPid)
        let (vault, repo, id) = (host.vault, repo, harness.session.id)
        try await offPool {
            let grant = try vault.startLead(root: repo, branch: "main")
            try vault.bind(grant, root: repo, session: id.uuidString)
            try BoardStore(root: repo).prepare()
            try BoardStore(root: repo).update { board in
                board.leadSession = id.uuidString
                board.leadPid = pid
                board.leadTTY = harness.session.tty
            }
        }
        try hook(harness, idle ? "Stop" : "PreToolUse")
        try await harness.waitFor { self.stored?.session == id }
        return harness
    }

    /// The fake's hooks said `event` just now (the hooks' state file under the host's root, as `vibeswitcher-hook`
    /// writes it).
    func hook(_ harness: NodeHarness, _ event: String) throws {
        var state = HookState(agent: .claude, tty: harness.session.tty, lastEvent: event, lastEventAt: Date().timeIntervalSince1970)
        state.agentPid = harness.agentPid
        let file = host.root.appendingPathComponent("state/\(harness.session.tty).json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try state.save(to: file)
    }

    /// Posts a message straight into the fake's inbox (as a worker's tool server or the hook's peer would), `age`
    /// seconds old: past the wake-up's quiet, it's woken for at the next look.
    func post(_ text: String, from sender: SteerMessage.Sender, to harness: NodeHarness, age: TimeInterval = 60) throws {
        let pid = try #require(harness.agentPid)
        try SteerInbox.post(SteerMessage(text: text, from: sender, agentPid: pid, at: Date().timeIntervalSince1970 - age),
                            tty: harness.session.tty, root: host.root)
    }

    /// What waits in the fake's inbox for it.
    func pending(_ harness: NodeHarness) -> [SteerMessage] {
        SteerInbox.pending(tty: harness.session.tty, root: host.root).filter { $0.agentPid == harness.agentPid }
    }

    /// The engine sends `text` to the project's lead: whether it reached the lead's inbox (false: held).
    func deliver(_ text: String, from sender: SteerMessage.Sender, action: String? = nil) async -> Bool? {
        let went = Locked<Bool?>(nil)
        engine.deliver(text, from: sender, project: project, action: action) { went.value = $0 }
        _ = await eventually(timeout: 120) { went.value != nil }
        return went.value
    }

    /// The engine's message for session `id`.
    func tell(_ text: String, session id: UUID) async -> SessionDelivery? {
        let said = Locked<SessionDelivery?>(nil)
        engine.tell(text, from: .system("a test"), session: id) { said.value = $0 }
        _ = await eventually(timeout: 120) { said.value != nil }
        return said.value
    }

    /// One of the engine's looks (what its 3 s clock asks).
    func look() { queue.async { self.engine.look() } }

    /// Keys typed into the session as they are (not a paste): what a person types there.
    func keys(_ text: String, into harness: NodeHarness) {
        link.type([HostInput.Write(bytes: Array(text.utf8), delay: 0)], into: harness.session.id)
    }

    /// The first step after the first `after` that `matches`, once it comes (nil when it never does).
    func step(after: Int, sourceLocation: SourceLocation = #_sourceLocation, _ matches: @escaping (WakeStep) -> Bool) async -> WakeStep? {
        _ = await eventually(timeout: 120) { self.steps.value.dropFirst(after).contains(where: matches) }
        let found = steps.value.dropFirst(after).first(where: matches)
        if found == nil { Issue.record("no such step; the steps: \(steps.value)", sourceLocation: sourceLocation) }
        return found
    }

    /// Whether `step` is something typed, and what.
    static func typed(_ step: WakeStep) -> String? {
        if case .typed(_, let text) = step { return text } else { return nil }
    }

    /// Whether `step` is a refusal to type, and why.
    static func refused(_ step: WakeStep) -> String? {
        if case .notTyped(_, let why) = step { return why } else { return nil }
    }

    /// The prompts the fake took: its transcript's user lines whose content is text.
    func prompts(_ harness: NodeHarness) -> [String] {
        harness.transcript.compactMap { line in
            guard line["type"] as? String == "user", let message = line["message"] as? [String: Any] else { return nil }
            return message["content"] as? String
        }
    }

    /// What the hook handed the fake: its transcript's added context.
    func handed(_ harness: NodeHarness) -> String {
        harness.transcript.compactMap { line -> String? in
            guard let attachment = line["attachment"] as? [String: Any], attachment["type"] as? String == "hook_additional_context" else { return nil }
            return (attachment["content"] as? [String])?.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// Everything asked of the reads queue and the engine's queue so far has run (twice over: a read hands its result
    /// to the engine's queue, which may ask another).
    func drained() async {
        await offPool {
            for _ in 0..<3 {
                self.engine.reads.queue.sync {}
                self.queue.sync {}
            }
        }
    }
}
