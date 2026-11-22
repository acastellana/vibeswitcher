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
                              settings: [.init(key: "depth", title: "Probe depth", about: "How deep a probe goes.", form: "count", defaultValue: "1")],
                              brief: ["Ask for a probe with vs-probe."])
            self.unavailable = unavailable
            self.blankFacts = blankFacts
        }
        let unavailable: String?
        func availability() -> String? { unavailable }

        func look(_ desk: PluginDesk, done: @escaping () -> Void) {
            desk.stamped({ try ShellRequest.parse($0) }) { requests in
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
                       facts: [.init(name: "folder", label: "in the folder", value: blank ? request.cwd + "\u{3000}" : request.cwd, folder: true, decisive: true)],
                       body: .init(name: "command", label: "probing exactly this", note: "as you", text: request.command),
                       context: request.label.isEmpty ? nil : .init(name: "label", label: "named", text: request.label),
                       expiresAt: request.expiresAt,
                       actions: [.init(word: "run", label: "Run", acts: true, short: "runs it", does: "runs the probe, as you", verb: "run a probe",
                                       marks: "starting"),
                                 .init(word: "decline", label: "Decline", acts: false, short: "declines it", does: "declines the probe",
                                       verb: "decline a probe", marks: "declined")],
                       waiting: "nothing runs until you answer run")
        }

        /// Called as `perform` starts (a test's look at what holds then).
        var onPerform: (() -> Void)?
        /// A page `run` opens instead of acting, and what came of it.
        var pageSpec: PluginPage.Spec?
        let pageAnswers = Locked<[Data]>([])
        let pageEnded = Locked<Bool?>(nil)

        func check(setting name: String, value: String?) -> Result<String?, PluginRefusal> {
            guard name == "depth" else { return .failure(PluginRefusal("no setting \(name)")) }
            guard let value else { return .success(nil) }
            return Int(value).map { (1...9).contains($0) } == true ? .success(value) : .failure(PluginRefusal("1 to 9"))
        }

        func perform(_ word: String, on card: CardStore.Card, desk: PluginDesk, act: PluginAct,
                     then: @escaping (Result<NodeWire.Value, LeadEngine.CardFailure>) -> Void) {
            onPerform?()
            performed.mutate { $0.append(word) }
            guard let request = card.plugin?.request else { return then(.failure(.gone("no request"))) }
            if let page = pageSpec, word == "run" {
                // A page for the answer: the core serves it; the plugin hears the bytes.
                return act.openPage(page, take: { [weak self] bytes in
                    let taken = bytes == Data(#"{"ok":true}"#.utf8)
                    if taken { self?.pageAnswers.mutate { $0.append(bytes) } }
                    return taken
                }, ended: { [weak self] taken in self?.pageEnded.value = taken }) { opened in
                    switch opened {
                    case .success(let url): then(.success(.object(["outcome": .string("page"), "say": .array([.string(url.absoluteString)])])))
                    case .failure(let why): then(.failure(.refused(why.description)))
                    }
                }
            }
            desk.change(request: request, state: word == "run" ? "ran" : "declined", outcome: word == "run" ? "Ran" : "Declined",
                        closed: word == "run" ? "ran" : "declined")
            then(.success(.object(["outcome": .string(word == "run" ? "ran" : "declined"), "notice": .null])))
        }

        func withdrawn(_ card: PluginCard, desk: PluginDesk) -> String? {
            withdrawnRequests.mutate { $0.append(card.request) }
            return nil
        }
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
        // A record in the shape a build before the one field wrote (its own fields), as a handover carries it: kept.
        let old = Data(#"{"actions":[],"seals":{},"plugins":{"shell":false},"settledRequests":{"shell:abc":12.5},"pluginSettings":{"probe.depth":"3"}}"#.utf8)
        let kept = try JSONDecoder().decode(LeadVaultV2.Book.self, from: old)
        #expect(kept.plugins == ["shell": false] && kept.settledRequests == ["shell:abc": 12.5] && kept.pluginSettings == ["probe.depth": "3"])
        let again = try JSONDecoder().decode(LeadVaultV2.Book.self, from: JSONEncoder().encode(kept))
        #expect(again == kept && again.plugins == ["shell": false], "written in the one field, read back the same")
        // A vault's serialized state from a build with the old shape, as a handover hands it over: restored, kept.
        var saved = try #require(try JSONSerialization.jsonObject(with: LeadVault.Book(restoring: nil).serialized) as? [String: Any])
        saved["v2"] = try JSONSerialization.jsonObject(with: old)
        let restored = LeadVault.Book(restoring: try JSONSerialization.data(withJSONObject: saved))
        #expect(restored.v2 { $0?.plugins } == ["shell": false] && restored.v2 { $0?.settledRequests["shell:abc"] } == 12.5)
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
        #expect(lines.contains { $0.hasPrefix("probe  Probes  off (at its default since the session host's vault began") } && lines.contains("  adds for agents: vs-probe: files a probe"), "\(lines)")

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
        #expect(lines.contains("  named (the agent's words): \u{201C}probe\u{201D}"), "the renderer marks the agent's words: \(lines)")
        // `status` says it waits, with the lines that answer it.
        let status = try #require(await world.ask("status", action: nil))
        let notices = status.result?["notices"]?.array?.compactMap(\.string) ?? []
        #expect(notices.contains { $0.hasPrefix("a probe request waits for you: Asker asks for a probe (in the folder \(world.repo)); its command, the agent's words: \u{201C}make probe\u{201D}.") && $0.contains("vibeswitcher answer \(card.id) run") }, "\(notices)")

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

    }

    /// Rule 1 is the desk's, before any plugin's decoder runs: the bytes read here (no link followed), the stamp's digest
    /// of those bytes, the host's own stamp, the stamp's session the request's, a live session the user opened.
    @Test func theDeskHoldsRuleOneBeforeAnyDecoder() async throws {
        let world = try await CardWorld.make(scratch, plugins: [Probe(defaultOn: true)])
        defer { world.stop() }
        let (asker, request) = try await file(world)
        let folder = world.host.root.appendingPathComponent("probe-requests", isDirectory: true)
        let opened = Set(world.queue.sync { world.engine.desk(world.engine.plugins.plugins[0]).live.keys })
        #expect(opened.contains(asker.id.uuidString.lowercased()))
        let decoded = Locked(0)
        let decode: (Data) throws -> ShellRequest = { decoded.mutate { $0 += 1 }; return try ShellRequest.parse($0) }
        let read = { (opened: Set<String>, now: Date) in
            PluginDesk.read(folder: folder, decode: decode, trusted: [:], vault: world.host.vault, opened: opened, now: now, plugin: "probe", note: { _ in }).requests
        }
        #expect(read(opened, Date()).map(\.ask.id) == [request.id])

        // Not the host's stamp; a stamp for other bytes; a link in the request's place: none decoded.
        let forger = try await world.host.spawn("exec /bin/sleep 600", cwd: world.repo, label: "Forger")
        let forged = ShellRequest(session: forger.id.uuidString, cwd: world.repo, command: "echo forged", label: "forged", createdAt: Date())
        let bytes = try forged.encoded()
        try ShellAsk.file(forged, stamp: WalletStamp(session: forged.session, digest: WalletStamp.digest(bytes), seal: String(repeating: "0", count: 64)), in: folder)
        let swapped = ShellRequest(session: asker.id.uuidString, cwd: world.repo, command: "echo swapped", label: "", createdAt: Date())
        try FileManager.default.copyItem(at: folder.appendingPathComponent("\(request.id).seal"), to: folder.appendingPathComponent("\(swapped.id).seal"))
        try swapped.encoded().write(to: folder.appendingPathComponent("\(swapped.id).json"))
        let linked = UUID().uuidString.lowercased()
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("\(linked).json"), withDestinationURL: folder.appendingPathComponent("\(request.id).json"))
        try FileManager.default.copyItem(at: folder.appendingPathComponent("\(request.id).seal"), to: folder.appendingPathComponent("\(linked).seal"))
        decoded.value = 0
        let opened2 = opened.union([forger.id.uuidString.lowercased()])
        #expect(read(opened2, Date()).map(\.ask.id) == [request.id], "only the stamped one, whole")
        #expect(decoded.value == 1, "nothing else reached the decoder")

        // Its session not one the user opened (ended, or a team's worker): not decoded at all.
        decoded.value = 0
        #expect(read([], Date()).isEmpty && decoded.value == 0)
        let worker = try await world.host.spawn("exec /bin/sleep 600", cwd: world.repo, label: "Worker: fix-login")
        // A label is anyone's to give: the roster says who is a team's, so a session named "Worker: …" the user opened asks.
        let desk = world.queue.sync { world.engine.desk(world.engine.plugins.plugins[0]) }
        #expect(world.queue.sync { desk.opened(worker) && desk.opened(asker) })
        #expect(read(opened, request.created.addingTimeInterval(-PluginDesk.aheadAtMost - 60)).isEmpty, "dated ahead of the clock")
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

    // MARK: The review of step 1

    /// Rule 4 and rule 7 at the desk: no expiry or one past the plugin's declared life, an action that leaves it waiting,
    /// a plugin that is off, a settled request: not drawn. An open card past its expiry is closed by the core.
    @Test func theDeskDrawsOnlyWhatRulesFourAndSevenLet() async throws {
        let probe = Probe(defaultOn: true)
        let world = try await CardWorld.make(scratch, plugins: [probe])
        defer { world.stop() }
        let (asker, request) = try await file(world)
        // Read (the desk keeps its stamp), its card forgotten and unsettled: each draw below is judged afresh.
        await look(world)
        let desk = world.queue.sync { world.engine.desk(probe) }
        world.queue.sync {
            desk.forget(request: request.id, closed: "x")
            world.engine.pluginSettled.remove("probe:\(request.id)")
        }
        let asked = Probe.card(request, asker: PluginDesk.asker(asker))
        var card = asked
        card.expiresAt = nil
        #expect(world.queue.sync { desk.draw(card, root: world.repo, at: request.created) }.failure?.description.contains("declared life") == true)
        card.expiresAt = request.created.addingTimeInterval(probe.info.life + 60)
        #expect(world.queue.sync { desk.draw(card, root: world.repo, at: request.created) }.failure != nil)
        card = asked
        card.actions[0].marks = PluginCard.waitingState
        #expect(card.refusal?.contains("would leave it waiting") == true)
        card = asked
        card.request = UUID().uuidString.lowercased()
        #expect(world.queue.sync { desk.draw(card, root: world.repo, at: request.created) }.failure?.description.contains("no stamped request") == true)

        // Drawn, then past its expiry: the core closes it, settled; never drawn again, by this server or the next.
        let again = try world.queue.sync { try desk.draw(asked, root: world.repo, at: request.created).get() }
        await withCheckedContinuation { done in
            world.queue.async {
                world.engine.pluginNow = { request.expiresAt.addingTimeInterval(1) }
                world.engine.expirePluginCards()
                done.resume()
            }
        }
        let expired = try #require(world.card(again.id))
        #expect(!expired.isOpen && expired.plugin?.state == "expired", "\(expired)")
        world.queue.sync { desk.forget(request: request.id, closed: "gone") }
        world.queue.sync { world.engine.pluginNow = Date.init }
        #expect(world.queue.sync { desk.draw(asked, root: world.repo, at: request.created) }.failure?.description.contains("settled") == true)
        #expect(await eventually(timeout: 30) { (try? world.world.link.vaultV2.settledRequests())?.contains("probe:\(request.id)") == true })

        // Off: nothing drawn, whatever a look that hopped queues brings.
        _ = await turn(world, "probe", on: false)
        var fresh = asked
        fresh.request = UUID().uuidString.lowercased()
        #expect(world.queue.sync { desk.draw(fresh, root: world.repo, at: request.created) }.failure?.description.contains("off") == true)
    }

    /// Lines by scalars (CRLF is two), control characters refused but a tab and a line feed, the asker's name checked for
    /// control characters only.
    @Test func linesAreScalarsAndControlsAreRefused() {
        let request = ShellRequest(session: UUID().uuidString, cwd: "/home/u/site", command: "true", label: "", createdAt: Date())
        var card = Probe.card(request, asker: "Claude ✍️")
        #expect(card.refusal == nil, "an emoji's variation selector in a session's name refuses nothing")
        card.body = .init(name: "command", label: "x", text: "a\r\nb")
        #expect(card.body.lines.count == 2 && card.body.size == "2 lines, 4 bytes")
        #expect(card.refusal?.contains("control character (U+000D)") == true, "\(String(describing: card.refusal))")
        card.body = .init(name: "command", label: "x", text: "a\tb\nc")
        #expect(card.refusal == nil)
        card.body = .init(name: "command", label: "x", text: "a\u{1B}[2Jb")
        #expect(card.refusal?.contains("U+001B") == true)
        card = Probe.card(request, asker: "evil\u{1B}]0;x")
        #expect(card.refusal?.contains("asker") == true)
        #expect(PluginText.size("a\r\nb") == "2 lines, 4 bytes")
    }

    /// A fresh vault after the host's restart: each plugin back at its default, and the list and the restart notice say so.
    @Test func afterAHostRestartEachIsAtItsDefaultAndSaysSo() async throws {
        let world = try await CardWorld.make(scratch, plugins: [Probe(defaultOn: true)])
        defer { world.stop() }
        world.queue.sync { world.engine.hostRestart = EngineState.Restart(at: Date().timeIntervalSince1970, before: 1, gone: []) }
        let listed = try #require(await world.ask("plugin.list", action: nil))
        let lines = PluginListText.lines(listed.result?["plugins"]?.array ?? [])
        #expect(lines.contains { $0.hasPrefix("probe  Probes  on (at its default since the session host's vault began") }, "\(lines)")
        #expect(LeadEngine.resetByRestart.contains("the feature plugins turned on or off"))
        // Set again by the user: no longer "since the restart".
        _ = await turn(world, "probe", on: false)
        let again = try #require(await world.ask("plugin.list", action: nil))
        #expect(!PluginListText.lines(again.result?["plugins"]?.array ?? []).contains { $0.contains("since the session host's restart") })
    }

    /// A page lists only the plugins that are on; the user's terminal lists them all. The Mac's dialog words on and off.
    @Test func aPageListsOnlyWhatIsOnAndTheMacDialogWordsOnAndOff() async throws {
        let world = try await CardWorld.make(scratch, plugins: [Probe(defaultOn: false), Probe(id: "other", defaultOn: true)])
        defer { world.stop() }
        _ = try #require(await world.ask("plugin.list", action: nil))
        let page = try #require(await world.ask("plugin.list", action: nil, from: NodeLive.webPeer))
        #expect(page.result?["plugins"]?.array?.compactMap { $0["id"]?.string } == ["other"], "\(page)")
        let all = try #require(await world.ask("plugin.list", action: nil))
        #expect(all.result?["plugins"]?.array?.compactMap { $0["id"]?.string } == ["probe", "other"])
        let action = UUID().uuidString.lowercased()
        let text = world.queue.sync { world.requests.approvalCard(NodeWire.Request(id: "d", kind: "plugin.on", args: ["plugin": .string("probe")], action: action)) }
        #expect((try? text.get())?.contains("turn Probes (probe) on for this node") == true, "\(text)")
        let unknown = world.queue.sync { world.requests.approvalCard(NodeWire.Request(id: "d", kind: "plugin.off", args: ["plugin": .string("nope")], action: action)) }
        #expect((try? unknown.get()) == nil)
    }
}

// MARK: The second review of steps 1 and 2

extension PluginsTests {
    /// A request swapped under its id after its card was drawn isn't read again; the card's session, name and filing time
    /// are the stamped request's, whatever the plugin's card says; an answered card never waits again.
    @Test func aCardIsTiedToTheStampedRequestItWasDrawnFrom() async throws {
        let probe = Probe(defaultOn: true)
        let world = try await CardWorld.make(scratch, plugins: [probe])
        defer { world.stop() }
        let (asker, request) = try await file(world)
        await look(world)
        let card = try #require(card(world, request))
        #expect(card.plugin?.session == NodeIds.session(host: asker.id) && card.plugin?.asker == "Asker")
        let digest = try #require(world.queue.sync { world.engine.pluginDrawn["probe:\(request.id)"] })
        let folder = world.host.root.appendingPathComponent("probe-requests", isDirectory: true)
        let read = PluginDesk.read(folder: folder, decode: { try ShellRequest.parse($0) }, trusted: [:], vault: world.host.vault,
                                   opened: [asker.id.uuidString.lowercased()], drawn: ["probe:\(request.id)": String(repeating: "f", count: 64)],
                                   now: Date(), plugin: "probe", note: { _ in })
        #expect(read.requests.isEmpty, "bytes other than the ones drawn from: dropped")
        #expect(digest.count == 64)

        // The plugin's word for the asker counts for nothing.
        let desk = world.queue.sync { world.engine.desk(probe) }
        var claimed = Probe.card(request, asker: "Someone Else")
        claimed.session = "\(NodeIds.node):\(UUID().uuidString.lowercased())"
        world.queue.sync { desk.forget(request: request.id, closed: "x") }
        world.queue.sync { world.engine.pluginSettled.remove("probe:\(request.id)") }
        let drawn = try world.queue.sync { try desk.draw(claimed, root: world.repo, at: Date().addingTimeInterval(9_999)).get() }
        #expect(drawn.plugin?.session == NodeIds.session(host: asker.id) && drawn.plugin?.asker == "Asker" && drawn.at == request.created)
        // Answered: never back to waiting.
        let ran = try #require(await world.answer(drawn, "decline"))
        #expect(ran.ok, "\(ran)")
        world.queue.sync { desk.change(request: request.id, state: PluginCard.waitingState, outcome: nil) }
        #expect(world.card(drawn.id)?.plugin?.isWaiting == false)
    }

    /// An acting answer is settled in the vault, confirmed, before the plugin acts; until the vault said which requests
    /// are settled, nothing is drawn.
    @Test func anActingAnswerIsSettledBeforeItActs() async throws {
        let probe = Probe(defaultOn: true)
        let world = try await CardWorld.make(scratch, plugins: [probe])
        defer { world.stop() }
        let (_, request) = try await file(world)
        await look(world)
        let card = try #require(card(world, request))
        let settledFirst = Locked<Bool?>(nil)
        let key = "probe:\(request.id)"
        probe.onPerform = { settledFirst.value = world.engine.pluginSettled.contains(key) }
        let ran = try #require(await world.answer(card, "run"))
        #expect(ran.ok && settledFirst.value == true, "\(ran)")
        #expect(try world.world.link.vaultV2.settledRequests().contains(key))

        let desk = world.queue.sync { world.engine.desk(probe) }
        world.queue.sync { world.engine.pluginSettledKnown = false }
        var other = Probe.card(request, asker: "Asker")
        other.request = UUID().uuidString.lowercased()
        #expect(world.queue.sync { desk.draw(other, root: world.repo, at: Date()) }.failure?.description.contains("settled") == true)
    }

    /// Turned off while an answer acts on a card: the words say what is true.
    @Test func offWhileAnsweredSaysWhatIsTrue() async throws {
        let probe = Probe(defaultOn: true)
        let world = try await CardWorld.make(scratch, plugins: [probe])
        defer { world.stop() }
        let (_, request) = try await file(world)
        await look(world)
        world.queue.sync {
            guard var card = world.engine.cards.cards.values.first(where: { $0.plugin?.request == request.id }) else { return }
            card.plugin?.state = "starting"
            world.engine.cards.put(card)
        }
        _ = await turn(world, "probe", on: false)
        let closed = try #require(card(world, request))
        #expect(closed.closed?.contains("while it was being answered") == true && closed.closed?.contains("nothing ran") == false, "\(String(describing: closed.closed))")
    }

    /// `plugin list` says since when a plugin is at its default from the vault's own record, never a file of the node's.
    @Test func atItsDefaultSinceTheVaultsRecordBegan() async throws {
        let world = try await CardWorld.make(scratch, plugins: [Probe(defaultOn: true)])
        defer { world.stop() }
        try Data(#"{"hostRestart":null}"#.utf8).write(to: world.host.root.appendingPathComponent("engine.json"))
        let listed = try #require(await world.ask("plugin.list", action: nil))
        let since = try world.world.link.vaultV2.recordSince()
        #expect(listed.result?["plugins"]?.array?.first?["defaultSince"] == .date(since), "\(listed)")
        #expect(PluginListText.lines(listed.result?["plugins"]?.array ?? []).contains { $0.contains("at its default since the session host's vault began") })
        _ = await turn(world, "probe", on: false)
        let set = try #require(await world.ask("plugin.list", action: nil))
        #expect(set.result?["plugins"]?.array?.first?["defaultSince"] == .null)
    }

    /// A Run-card shell's name is an agent's, marked so; a flooded folder can't hide the others' requests for long: junk
    /// is removed, and what is read a look is bounded.
    @Test func anAgentsNameIsMarkedAndAFloodIsBounded() async throws {
        let request = ShellRequest(session: UUID().uuidString, cwd: "/home/u/site", command: "make", label: "build", createdAt: Date())
        let spawn = ShellAsk.spawnRequest(request)
        let shell = HostSession(id: UUID(), tty: "ttypts9", childPID: 1, cwd: "/home/u/site", command: spawn.command, label: "Shell: build", agent: nil,
                                title: "", startedAt: Date(), cols: 80, rows: 24, exit: nil)
        #expect(PluginDesk.asker(shell) == "a shell an agent asked for, named by it \u{201C}Shell: build\u{201D}")

        let world = try await CardWorld.make(scratch, plugins: [Probe(defaultOn: true)])
        defer { world.stop() }
        let (asker, real) = try await file(world)
        let folder = world.host.root.appendingPathComponent("probe-requests", isDirectory: true)
        for _ in 0..<(PluginDesk.readAtMost + 6) {
            try Data("{}".utf8).write(to: folder.appendingPathComponent("\(UUID().uuidString.lowercased()).json"))
        }
        let opened: Set<String> = [asker.id.uuidString.lowercased()]
        let read = { PluginDesk.read(folder: folder, decode: { try ShellRequest.parse($0) }, trusted: [:], vault: world.host.vault, opened: opened,
                                     now: Date(), plugin: "probe", note: { _ in }).requests.map(\.ask.id) }
        var found = read()
        if found.isEmpty { found = read() }
        #expect(found == [real.id], "the junk removed, the real one read within two looks")
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".json") }
        #expect(left == ["\(real.id).json"], "\(left.count) left")
    }
}

// MARK: What the core keeps of the wallet: the page, the settings

extension PluginsTests {
    static let pageHTML = "<!doctype html><title>probe</title><script>window.x=1</script>"
    static var pageSpec: PluginPage.Spec {
        PluginPage.Spec(html: pageHTML, scripts: [PluginPage.hash("window.x=1")], styles: [], life: 60)
    }

    /// The core serves a plugin's page once on its own loopback origin: its Host and token only, its own Origin for the
    /// answer, a garbled answer refused, one taken, then gone; a page it won't serve is refused.
    @Test func aPluginsPageIsTheCoresAndTakesOneAnswer() async throws {
        #expect(PluginPage.Spec(html: "x", scripts: ["nope"], styles: [], life: 60).refusal != nil, "not a hash")
        #expect(PluginPage.Spec(html: "x", scripts: [], styles: [], life: 16 * 60).refusal != nil, "past 15 minutes")
        #expect(PluginPage.Spec(html: "x", scripts: [], styles: [], life: 60).csp.contains("script-src 'none'"), "no hashes: nothing runs")
        #expect(HostWebListen.refusal(.page, address: "127.0.0.1", port: HostWebListen.port, usersHost: true) != nil)
        #expect(HostWebListen.refusal(.page, address: "127.0.0.1", port: 0, usersHost: true) == nil)
        #expect(HostWebListen.refusal(.page, address: "0.0.0.0", port: 0, usersHost: false) != nil)

        let probe = Probe(defaultOn: true)
        probe.pageSpec = Self.pageSpec
        let world = try await CardWorld.make(scratch, plugins: [probe])
        defer { world.stop() }
        let (_, request) = try await file(world)
        await look(world)
        let card = try #require(card(world, request))
        let ran = try #require(await world.answer(card, "run"))
        let address = try #require(ran.result?["say"]?.array?.first?.string, "\(ran)")
        let url = try #require(URL(string: address))
        let port = try #require(url.port.map(UInt16.init))
        let place = "127.0.0.1:\(port)", path = String(address.dropFirst("http://\(place)".count))
        #expect(port != HostWebListen.port && path.hasSuffix("/"))
        let get = { (host: String, path: String) throws -> String? in
            let client = try WebTestClient(port: port)
            _ = client.send("GET \(path) HTTP/1.1\r\nHost: \(host)\r\n\r\n")
            return client.response().map { $0.head + "\n\n" + $0.body }
        }
        let page = try #require(try get(place, path))
        #expect(page.hasPrefix("HTTP/1.1 200") && page.contains("script-src 'sha256-") && page.contains(Self.pageHTML), "\(page)")
        #expect(try get("localhost:\(port)", path)?.hasPrefix("HTTP/1.1 421") == true)
        #expect(try get(place, "/nottoken/")?.hasPrefix("HTTP/1.1 404") == true)
        let foreign = try WebTestClient(port: port)
        #expect(foreign.upgrade(path: path + "answer", host: place, origin: "http://evil.example")?.hasPrefix("HTTP/1.1 403") == true)
        let garbled = try WebTestClient(port: port)
        try #require(garbled.upgrade(path: path + "answer", host: place, origin: "http://" + place)?.hasPrefix("HTTP/1.1 101") == true)
        _ = garbled.send(WebTestClient.text("garbage"))
        #expect(garbled.message()?.text == "refused")
        let answer = try WebTestClient(port: port)
        try #require(answer.upgrade(path: path + "answer", host: place, origin: "http://" + place)?.hasPrefix("HTTP/1.1 101") == true)
        _ = answer.send(WebTestClient.text(#"{"ok":true}"#))
        #expect(answer.message()?.text == "ok")
        #expect(await eventually(timeout: 30) { probe.pageEnded.value == true })
        #expect(probe.pageAnswers.value == [Data(#"{"ok":true}"#.utf8)])
        #expect(await eventually(timeout: 30) { (try? WebTestClient(port: port)) == nil }, "the port let go")
        #expect(world.queue.sync { world.engine.pluginPage } == nil)
    }

    /// A plugin's settings: listed under its own title while it is on, kept in the vault (a file a session writes changes
    /// nothing), checked by the plugin, absent and refused while it is off.
    @Test func aPluginsSettingsAreKeptInTheVault() async throws {
        let world = try await CardWorld.make(scratch, plugins: [Probe(defaultOn: true)])
        defer { world.stop() }
        _ = try #require(await world.ask("plugin.list", action: nil))
        let set = try #require(await world.ask("set", ["key": .string("probe_depth"), "value": .string("3")]))
        #expect(set.ok && set.result?["value"]?.string == "3" && set.result?["was"]?.string == "1", "\(set)")
        #expect(try world.world.link.vaultV2.pluginSettings() == ["probe.depth": "3"])
        let bad = try #require(await world.ask("set", ["key": .string("probe_depth"), "value": .string("99")]))
        #expect(bad.error?.code == NodeWire.Code.badArgs.rawValue, "\(bad)")
        let settings = try #require(await world.ask("settings", action: nil))
        let shown = try #require((settings.result?["node"]?["settings"]?.array ?? []).first { $0["key"]?.string == "probe_depth" })
        #expect(shown["section"]?.string == "Probes" && shown["home"]?.string == "plugin" && shown["value"]?.string == "3", "\(shown)")
        #expect(WireSchema.check(shown, as: "setting", strict: true) == nil)
        try Data("x".utf8).write(to: world.host.root.appendingPathComponent("settings.plist"))
        #expect(world.queue.sync { world.engine.pluginSettings["probe.depth"] } == "3")
        _ = await turn(world, "probe", on: false)
        let off = try #require(await world.ask("settings", action: nil))
        #expect(!(off.result?["node"]?["settings"]?.array ?? []).contains { $0["key"]?.string == "probe_depth" }, "off: no settings")
        let refused = try #require(await world.ask("set", ["key": .string("probe_depth"), "value": .string("2")]))
        #expect(!refused.ok, "\(refused)")
    }
}

extension Result {
    var failure: Failure? { if case .failure(let failure) = self { return failure } else { return nil } }
}
