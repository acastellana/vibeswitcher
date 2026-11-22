import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The feature plugins' core (docs/superpowers/specs/2026-11-22-v2-feature-plugins.md, step 1): the registry and its
/// declarations, on and off kept in the host's vault (the user's voice, recorded; a session's file write turns nothing
/// on), the one reader of stamped requests, a plugin's card as data drawn after the core's checks, an answer routed
/// through the core's checks before the plugin acts, and a plugin turned off: its cards withdrawn, its folder dropped
/// unread, nothing drawn, nothing in `hello` or `status`. A probe plugin on a scratch host, its requests filed as
/// `vs-shell` files them (`ShellAsk`) into its own folder.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct PluginsTests {
    private let scratch = Scratch()

    /// A plugin for tests: requests filed as shell requests in `probe-requests`, a card per request from a live session,
    /// `run` (acts) and `decline`; what it was asked to do, kept.
    final class Probe: FeaturePlugin, @unchecked Sendable {
        let info: PluginInfo
        let performed = Locked<[String]>([])
        let withdrawnRequests = Locked<[String]>([])
        let blankFacts: Bool
        init(id: String = "probe", defaultOn: Bool = false, unavailable: String? = nil, blankFacts: Bool = false) {
            info = PluginInfo(id: id, title: "Probes", summary: "A probe for tests.", defaultOn: defaultOn,
                              commands: [.init(name: "vs-probe", about: "files a probe")], tools: ["probe_tool"], folder: "\(id)-requests",
                              brief: ["Ask for a probe with vs-probe."])
            self.unavailable = unavailable
            self.blankFacts = blankFacts
        }
        let unavailable: String?
        func availability() -> String? { unavailable }

        func look(_ desk: PluginDesk, done: @escaping () -> Void) {
            desk.stamped({ ShellAsk.filed(in: $0) }) { requests in
                let live = desk.live
                for request in requests where desk.card(request: request.id) == nil {
                    guard let asker = live[request.session] else { continue }
                    _ = desk.draw(Self.card(request, asker: PluginDesk.asker(asker), id: self.info.id, blank: self.blankFacts),
                                  root: request.cwd, at: request.created)
                }
                done()
            }
        }

        static func card(_ request: ShellRequest, asker: String, id: String = "probe", blank: Bool = false) -> PluginCard {
            PluginCard(plugin: id, request: request.id, session: "\(NodeIds.node):\(request.session)", asker: asker,
                       title: "A probe asked for", noun: "probe request", ask: "asks for a probe",
                       summary: "asks to probe `\(request.command)`",
                       facts: [.init(name: "folder", label: "in the folder", value: blank ? request.cwd + "\u{3000}" : request.cwd, folder: true)],
                       body: .init(name: "command", label: "probing exactly this", note: "as you", text: request.command),
                       context: request.label.isEmpty ? nil : .init(name: "label", label: "named", text: request.label),
                       expiresAt: request.expiresAt,
                       actions: [.init(word: "run", label: "Run", acts: true, short: "runs it", does: "runs the probe, as you", verb: "run a probe",
                                       marks: "starting"),
                                 .init(word: "decline", label: "Decline", acts: false, short: "declines it", does: "declines the probe",
                                       verb: "decline a probe", marks: "declined")],
                       waiting: "nothing runs until you answer run")
        }

        func perform(_ word: String, on card: CardStore.Card, desk: PluginDesk,
                     then: @escaping (Result<NodeWire.Value, LeadEngine.CardFailure>) -> Void) {
            performed.mutate { $0.append(word) }
            guard let request = card.plugin?.request else { return then(.failure(.gone("no request"))) }
            desk.change(request: request, state: word == "run" ? "ran" : "declined", outcome: word == "run" ? "Ran" : "Declined",
                        closed: word == "run" ? "ran" : "declined")
            then(.success(.object(["outcome": .string(word == "run" ? "ran" : "declined"), "notice": .null])))
        }

        func withdrawn(_ card: PluginCard, desk: PluginDesk) { withdrawnRequests.mutate { $0.append(card.request) } }
    }

    // MARK: Helpers

    private func file(_ world: CardWorld, folder: String = "probe-requests", command: [String] = ["echo", "probe"],
                      label: String = "probe") async throws -> (asker: HostSession, request: ShellRequest) {
        let asker = try await world.host.spawn("exec /bin/sleep 600", cwd: world.repo, label: "Asker")
        let session = asker.id.uuidString.lowercased()
        let vault = world.host.book.vault(folder: scratch.url("asker-vault-\(UUID().uuidString.prefix(6))"), as: { .session(session) }, userOpened: true)
        let into = world.host.root.appendingPathComponent(folder, isDirectory: true)
        let filed = await offPool { ShellAsk.run(["run", "--label", label, "--"] + command, cwd: world.repo, folder: into, vault: vault) }
        try #require(filed.status == 0, "\(filed)")
        let request = try #require(ShellAsk.filed(in: into).requests.first { $0.session == session })
        try #require(await eventually(timeout: 60) { world.queue.sync { world.engine.link.sessions.contains { $0.id == asker.id && $0.isLive } } })
        return (asker, request)
    }

    private func look(_ world: CardWorld) async {
        let done = Locked(false)
        world.queue.async { world.engine.lookAtPlugins { done.value = true } }
        _ = await eventually(timeout: 60) { done.value }
    }

    private func card(_ world: CardWorld, _ request: ShellRequest) -> CardStore.Card? {
        world.queue.sync { world.engine.cards.cards.values.first { $0.plugin?.request == request.id } }
    }

    private func turn(_ world: CardWorld, _ id: String, on: Bool) async -> NodeWire.Reply? {
        await world.ask(on ? "plugin.on" : "plugin.off", ["plugin": .string(id)])
    }

    // MARK: The declarations and the vault

    @Test func aDeclarationIsCheckedAndTheVaultKeepsOnAndOffForTheAppAlone() throws {
        #expect(PluginInfo(id: "probe", title: "P", summary: "s", defaultOn: false).refusal == nil)
        #expect(PluginInfo(id: "Probe", title: "P", summary: "s", defaultOn: false).refusal != nil, "an id the vault won't keep")
        #expect(PluginInfo(id: "probe", title: "P", summary: "s", defaultOn: false, life: 3600).refusal != nil, "a long life with no reason")
        #expect(PluginInfo(id: "probe", title: "P", summary: "s", defaultOn: false, life: 3600, lifeWhy: "a chain is slow").refusal == nil)
        #expect(PluginInfo(id: "probe", title: "P", summary: "s", defaultOn: false, folder: "../x").refusal != nil)
        #expect(PluginRegistry.standard().allSatisfy { $0.info.refusal == nil })

        var book: LeadVaultV2.Book?
        #expect(LeadVaultV2.answer(.setPlugin(id: "probe", on: true), from: .session("s"), book: &book, on: true)
                    == .refused("Only VibeSwitcher records and reads the user's actions."))
        #expect(LeadVaultV2.answer(.setPlugin(id: "../x", on: true), from: .app, book: &book, on: true) != .plugins(["../x": true]))
        #expect(LeadVaultV2.answer(.setPlugin(id: "probe", on: true), from: .app, book: &book, on: true) == .plugins(["probe": true]))
        #expect(LeadVaultV2.answer(.plugins, from: .app, book: &book, on: true) == .plugins(["probe": true]))
        // Kept with the vault's state, and read back by a build that saved none.
        let data = try JSONEncoder().encode(try #require(book))
        #expect(try JSONDecoder().decode(LeadVaultV2.Book.self, from: data).plugins == ["probe": true])
        #expect(try JSONDecoder().decode(LeadVaultV2.Book.self, from: Data("{}".utf8)).plugins == [:])
    }

    /// `plugin on` and `off` are the user's voice, recorded in the vault before they act; the vault keeps what they set,
    /// and a session that writes `plugins.json` (or anything under the root) turns nothing on.
    @Test func onAndOffAreTheUsersAndAFileWriteTurnsNothingOn() async throws {
        let probe = Probe()
        let world = try await CardWorld.make(scratch, plugins: [probe])
        defer { world.stop() }
        let listed = try #require(await world.ask("plugin.list", action: nil))
        let entry = try #require(listed.result?["plugins"]?.array?.first)
        #expect(entry["id"]?.string == "probe" && entry["on"]?.bool == false && entry["known"]?.bool == true, "\(entry)")
        let lines = PluginListText.lines(listed.result?["plugins"]?.array ?? [])
        #expect(lines.contains("probe  Probes  off (its default)") && lines.contains("  adds for agents: vs-probe: files a probe"), "\(lines)")

        // A forged mirror, and a forged vault-looking file: nothing is on.
        let mirror = world.host.root.appendingPathComponent("plugins.json")
        try Data(#"{"known":true,"on":["probe"]}"#.utf8).write(to: mirror)
        await withCheckedContinuation { done in world.queue.async { world.engine.askPlugins { done.resume() } } }
        #expect(world.queue.sync { world.engine.plugins.isOn("probe") } == false)

        // Not the user's voice: refused, nothing kept.
        let session = try await world.host.spawn("exec /bin/sleep 600", cwd: world.repo, label: "Agent")
        let fromSession = try #require(await world.ask("plugin.on", ["plugin": .string("probe")], from: CardWorld.toolServer(of: session)))
        #expect(fromSession.error?.code == NodeWire.Code.voice.rawValue, "\(fromSession)")
        #expect(try world.world.link.vaultV2.plugins() == [:])

        let on = try #require(await turn(world, "probe", on: true))
        #expect(on.ok && on.result?["on"]?.bool == true, "\(on)")
        #expect(try world.world.link.vaultV2.plugins() == ["probe": true])
        #expect(await world.actions().contains { $0.kind == "plugin.on" && $0.subject == "probe" }, "recorded as the user's action")
        #expect(world.queue.sync { world.engine.plugins.isOn("probe") })
        // The mirror says it for the agents' commands.
        #expect(await eventually(timeout: 30) { PluginGate.mirror(at: mirror)?.on == ["probe"] })
        #expect(PluginGate.refusal("probe", command: "vs-probe", at: mirror) == nil)
        // In `hello` and `status`.
        let hello = world.queue.sync { world.requests.hello(peer: nil) }
        #expect(hello.plugins == .array([.object(["id": .string("probe"), "title": .string("Probes")])]))
        let status = try #require(await world.ask("status", action: nil))
        #expect(status.result?["plugins"]?.array?.compactMap { $0["id"]?.string } == ["probe"])

        let off = try #require(await turn(world, "probe", on: false))
        #expect(off.ok && off.result?["on"]?.bool == false, "\(off)")
        #expect(await eventually(timeout: 30) { PluginGate.refusal("probe", command: "vs-probe", at: mirror)?.contains("doesn't have probe on") == true })
        #expect(world.queue.sync { world.requests.hello(peer: nil) }.plugins == .array([]))
        // A plugin this build doesn't have, and one that can't run here.
        let unknown = try #require(await turn(world, "nope", on: true))
        #expect(unknown.error?.code == NodeWire.Code.gone.rawValue, "\(unknown)")
    }

    @Test func aPluginThatCantRunHereIsntTurnedOn() async throws {
        let world = try await CardWorld.make(scratch, plugins: [Probe(defaultOn: true, unavailable: "no probe tool on this system")])
        defer { world.stop() }
        let on = try #require(await turn(world, "probe", on: true))
        #expect(on.error?.code == NodeWire.Code.refused.rawValue && on.error?.message.contains("no probe tool") == true, "\(on)")
        let listed = try #require(await world.ask("plugin.list", action: nil))
        #expect(PluginListText.lines(listed.result?["plugins"]?.array ?? []).contains { $0.contains("can't run on this node: no probe tool") })
        #expect(world.queue.sync { world.engine.plugins.isOn("probe") } == false)
    }

    // MARK: The card

    /// A stamped request is a card of data, shown whole by every renderer; an answer goes through the core's checks
    /// (its words only, the card's code, once) before the plugin acts.
    @Test func aStampedRequestIsAPluginCardAndTheCoreChecksAnAnswerFirst() async throws {
        let probe = Probe(defaultOn: true)
        let world = try await CardWorld.make(scratch, plugins: [probe])
        defer { world.stop() }
        let (_, request) = try await file(world, command: ["make", "probe"])
        await look(world)
        let card = try #require(card(world, request))
        #expect(card.kind == .plugin && card.isOpen && !card.isBlocking && card.root == world.repo)
        #expect(WireSchema.check(card.value, as: "card", strict: true) == nil, "\(card.value)")
        let lines = CardText.lines(card.value)
        #expect(lines.first?.contains("  probe  ") == true, "the plugin where the kind goes: \(lines)")
        #expect(lines.contains("  in the folder: \(world.repo)") && lines.contains("    | make probe"), "\(lines)")
        #expect(lines.contains("  probing exactly this (an agent's words; 1 line, 10 bytes, every line shown), as you:"), "\(lines)")
        #expect(lines.contains("  named: probe"), "\(lines)")
        // `status` says it waits, with the lines that answer it.
        let status = try #require(await world.ask("status", action: nil))
        let notices = status.result?["notices"]?.array?.compactMap(\.string) ?? []
        #expect(notices.contains { $0.hasPrefix("a probe request waits for you: Asker asks to probe `make probe`.") && $0.contains("vibeswitcher answer \(card.id) run") }, "\(notices)")

        let other = try #require(await world.answer(card, "maybe"))
        #expect(other.error?.code == NodeWire.Code.badArgs.rawValue && other.error?.message.contains("run or decline") == true, "\(other)")
        let wrong = try #require(await world.answer(card, "run", code: "ZZZZ"))
        #expect(wrong.error?.code == NodeWire.Code.voice.rawValue, "\(wrong)")
        #expect(probe.performed.value.isEmpty, "nothing acted")

        let ran = try #require(await world.answer(card, " RUN\n"))
        #expect(ran.ok && ran.result?["outcome"]?.string == "ran", "\(ran)")
        #expect(probe.performed.value == ["run"])
        let again = try #require(await world.answer(card, "run"))
        #expect(!again.ok, "\(again)")
        #expect(probe.performed.value == ["run"], "once")
        let closed = try #require(self.card(world, request))
        #expect(!closed.isOpen && closed.plugin?.state == "ran" && closed.plugin?.outcome == "Ran")
        #expect(await world.actions().contains { $0.kind == "answer" && $0.subject == card.id })
    }

    /// The core refuses what isn't shown whole: a value that draws as blank, a body past what a card holds, a request the
    /// host didn't stamp. A request dated past the clock isn't given.
    @Test func whatIsntShownWholeIsntDrawn() async throws {
        let world = try await CardWorld.make(scratch, plugins: [Probe(defaultOn: true, blankFacts: true)])
        defer { world.stop() }
        let (_, request) = try await file(world)
        await look(world)
        #expect(card(world, request) == nil, "a fact holding U+3000")
        var shown = Probe.card(request, asker: "Asker")
        #expect(shown.refusal == nil)
        shown.body = .init(name: "command", label: "x", text: String(repeating: "a\n", count: PluginCard.bodyLinesAtMost + 1))
        #expect(shown.refusal?.contains("more than a card shows whole") == true)
        shown = Probe.card(request, asker: "Asker")
        shown.context = .init(name: "label", label: "named", text: "ok\u{200B}")
        #expect(shown.refusal?.contains("U+200B") == true)
        shown = Probe.card(request, asker: "Asker")
        shown.context = .init(name: "label", label: "named", text: String(repeating: "w", count: 1000))
        #expect(shown.drawn.context?.text.count == PluginCard.contextAtMost + 2, "the agent's words cut, marked")

        // Unstamped: never given to the plugin.
        let asker = try await world.host.spawn("exec /bin/sleep 600", cwd: world.repo, label: "Forger")
        let forged = ShellRequest(session: asker.id.uuidString, cwd: world.repo, command: "echo forged", label: "forged", createdAt: Date())
        let bytes = try forged.encoded()
        let folder = world.host.root.appendingPathComponent("probe-requests", isDirectory: true)
        try ShellAsk.file(forged, stamp: WalletStamp(session: forged.session, digest: WalletStamp.digest(bytes), seal: String(repeating: "0", count: 64)), in: folder)
        let read = PluginDesk.read(folder: folder, parse: { ShellAsk.filed(in: $0) }, trusted: [:], vault: world.host.vault, now: Date(),
                                   plugin: "probe", note: { _ in })
        #expect(read.requests.map(\.id) == [request.id], "only the stamped one")
        let early = PluginDesk.read(folder: folder, parse: { ShellAsk.filed(in: $0) }, trusted: [:], vault: world.host.vault,
                                    now: request.created.addingTimeInterval(-PluginDesk.aheadAtMost - 60), plugin: "probe", note: { _ in })
        #expect(early.requests.isEmpty, "dated ahead of the clock")
    }

    @Test func anActingAnswerPastItsTimeIsRefused() async throws {
        let probe = Probe(defaultOn: true)
        let world = try await CardWorld.make(scratch, plugins: [probe])
        defer { world.stop() }
        let (_, request) = try await file(world)
        await look(world)
        let card = try #require(card(world, request))
        world.queue.sync { world.engine.pluginNow = { request.expiresAt.addingTimeInterval(1) } }
        let late = try #require(await world.answer(card, "run"))
        #expect(late.error?.code == NodeWire.Code.refused.rawValue && late.error?.message.contains("expired") == true, "\(late)")
        #expect(probe.performed.value.isEmpty)
        let declined = try #require(await world.answer(card, "decline"))
        #expect(declined.ok, "a decline isn't an act: \(declined)")
    }

    // MARK: Off leaves no trace

    /// Dropping an off plugin's files touches its folder only: a folder (or a parent) that is a link drops nothing, a
    /// folder inside is left, and only the shapes a command files go.
    @Test func droppingTouchesItsFolderOnlyAndFollowsNoLink() throws {
        let root = scratch.url("drop-root")
        let mine = root.appendingPathComponent("probe-requests", isDirectory: true)
        try FileManager.default.createDirectory(at: mine.appendingPathComponent("inner"), withIntermediateDirectories: true)
        for name in ["a.json", "a.seal", ".a.answer", "notes.txt"] { try Data("x".utf8).write(to: mine.appendingPathComponent(name)) }
        #expect(LeadEngine.dropUnread(root: root, relative: "probe-requests") == 3)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: mine.path)) == ["inner", "notes.txt"])

        let users = scratch.url("users-folder")
        try FileManager.default.createDirectory(at: users, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: users.appendingPathComponent("keep.json"))
        let linked = scratch.url("linked-root")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("probe-requests"), withDestinationURL: users)
        #expect(LeadEngine.dropUnread(root: linked, relative: "probe-requests") == 0)
        try FileManager.default.createDirectory(at: linked.appendingPathComponent("deep"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("deep/x"), withDestinationURL: users.deletingLastPathComponent())
        #expect(LeadEngine.dropUnread(root: linked, relative: "deep/x/users-folder") == 0, "a parent that is a link")
        #expect(FileManager.default.fileExists(atPath: users.appendingPathComponent("keep.json").path))
    }

    /// Turned off with a card open: the card closes as withdrawn and the plugin is told; while off, what is filed is
    /// dropped unread, nothing is drawn or answered, and nothing of it is in `hello`, `status`'s notices or the list's on.
    @Test func offWithdrawsItsCardsAndLeavesNoTrace() async throws {
        let probe = Probe(defaultOn: true)
        let world = try await CardWorld.make(scratch, plugins: [probe])
        defer { world.stop() }
        let (_, request) = try await file(world)
        await look(world)
        let card = try #require(card(world, request))

        let off = try #require(await turn(world, "probe", on: false))
        #expect(off.ok && off.result?["withdrawn"]?.int == 1, "\(off)")
        let withdrawn = try #require(self.card(world, request))
        #expect(!withdrawn.isOpen && withdrawn.plugin?.state == PluginCard.withdrawnState && withdrawn.closed?.contains("withdrawn") == true)
        #expect(probe.withdrawnRequests.value == [request.id])
        let late = try #require(await world.answer(card, "run"))
        #expect(!late.ok, "\(late)")
        #expect(probe.performed.value.isEmpty)

        // Filed while off: dropped unread at the next look, no card.
        let (_, second) = try await file(world, label: "while-off")
        let folder = world.host.root.appendingPathComponent("probe-requests", isDirectory: true)
        try #require(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(second.id).json").path))
        await look(world)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(second.id).json").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(second.id).seal").path))
        #expect(self.card(world, second) == nil)
        let status = try #require(await world.ask("status", action: nil))
        #expect(!(status.result?["notices"]?.array?.compactMap(\.string) ?? []).contains { $0.contains("probe") })
        #expect(status.result?["plugins"] == .array([]))
        #expect(world.queue.sync { world.requests.hello(peer: nil) }.plugins == .array([]))
    }
}
