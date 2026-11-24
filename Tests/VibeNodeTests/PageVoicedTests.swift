import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// An acting page's requests on a node (acting from the page, the web UI design's step 2): the click is the answer, so a
/// card's act names the card as the page drew it (`seen`), never a code, and is refused when the card changed since;
/// each act is recorded in the host's vault as the user's, marked as the page's; the confirmation seam (`PageVoice`)
/// stops everything before the record; the settings a page never sets are refused.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct PageVoicedTests {
    private let scratch = Scratch()
    static let token = "page-token-of-a-test"
    static let origin = "http://127.0.0.1:8765"

    /// The world's server with acting on (its vault in the test's memory) and one page paired while it is: that page's
    /// credentials, and its acting.
    private func acting(_ world: CardWorld) throws -> (PageCredentials, ActingPages) {
        let acting = ActingPages(vault: MemoryVaultV2().client)
        _ = try acting.set(level: "trust")
        let secret = acting.confirmed(token: Self.token, tokenEnds: Date().addingTimeInterval(3_600))
        acting.settled()
        world.queue.sync { world.requests.actingPages = acting }
        return (PageCredentials(token: Self.token, act: secret), acting)
    }

    /// `kind` with `args` from the acting page whose credentials are `page`: its reply.
    private func fromPage(_ world: CardWorld, _ page: PageCredentials, _ kind: String, _ args: [String: NodeWire.Value],
                          action: String = UUID().uuidString.lowercased()) async -> NodeWire.Reply? {
        let credentials = page
        let reply = Locked<NodeWire.Reply?>(nil)
        let request = NodeWire.Request(id: UUID().uuidString, kind: kind, args: args, action: action)
        world.queue.async { world.requests.pageVoiced(request, credentials: credentials, origin: Self.origin) { reply.value = $0 } }
        _ = await eventually(timeout: 120) { reply.value != nil }
        return reply.value
    }

    /// A refusing confirmation.
    struct Refusing: PageVoice {
        func confirm(_ request: NodeWire.Request, page: String, done: @escaping @Sendable (String?) -> Void) { done("no touch") }
    }

    @Test func aPagesAnswerNamesTheCardAsDrawnAndIsRecordedAsThePages() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let (page, _) = try acting(world)
        let lead = try await world.sleepingLead()
        let asked = try await world.asked("Keep the badges?", options: ["Yes", "No"], lead: lead)
        let card = try #require(world.card(asked.card.id))
        #expect(card.seen.count == 64 && card.value["seen"]?.string == card.seen)

        // A code from a page is refused: the page sends what it drew.
        let coded = try #require(await fromPage(world, page, "answer", ["card": .string(card.id), "code": .string(card.code), "seen": .string(card.seen), "text": .string("Yes")]))
        #expect(coded.error?.code == "bad-args", "\(coded)")
        // What it drew isn't the card now: refused, nothing recorded.
        let staleAction = UUID().uuidString.lowercased()
        let stale = try #require(await fromPage(world, page, "answer", ["card": .string(card.id), "seen": .string(String(repeating: "0", count: 64)), "text": .string("Yes")],
                                                action: staleAction))
        #expect(stale.error?.code == "changed", "\(stale)")
        #expect(await world.actions().allSatisfy { $0.action != staleAction })

        let action = UUID().uuidString.lowercased()
        let reply = try #require(await fromPage(world, page, "answer", ["card": .string(card.id), "seen": .string(card.seen), "text": .string("Yes")], action: action))
        #expect(reply.ok, "\(reply)")
        // The answer recorded as the page's (the message it sends the lead is recorded under the same action, as a
        // terminal's answer's is).
        let recorded = await world.actions().filter { $0.action == action && $0.kind == "answer" }
        #expect(recorded.count == 1, "\(recorded)")
        #expect(recorded.first?.via == ActingPages.via(token: Self.token, origin: Self.origin), "\(recorded)")
        #expect(recorded.first?.via?.hasPrefix("page \(ActingPages.digest(Self.token).prefix(12)) from http://127.0.0.1:8765") == true)
        // Answered again (a lost reply): as before, done once.
        let again = try #require(await fromPage(world, page, "answer", ["card": .string(card.id), "seen": .string(card.seen), "text": .string("Yes")], action: action))
        #expect(again.ok, "\(again)")
        #expect(await world.actions().filter { $0.action == action && $0.kind == "answer" }.count == 1)
    }

    /// A card that changed after the page drew it (its lead revised it) is refused: what is approved is what was shown.
    @Test func aRevisedCardIsRefusedAsChanged() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let (page, _) = try acting(world)
        let lead = try await world.sleepingLead()
        let asked = try await world.asked("Name it Parser?", options: ["Parser", "Reader"], lead: lead)
        let drawn = try #require(world.card(asked.card.id)).seen
        _ = try await world.revise(asked.question.id, text: "Name it Reader?", options: ["Reader", "Parser"], note: "the other way round", lead: lead)
        #expect(await eventually(timeout: 60) { world.card(asked.card.id)?.seen != drawn })
        let reply = try #require(await fromPage(world, page, "answer", ["card": .string(asked.card.id), "seen": .string(drawn), "text": .string("Parser")]))
        #expect(reply.error?.code == "changed", "\(reply)")
    }

    /// The confirmation seam refuses: nothing is recorded or done.
    @Test func theConfirmationSeamStopsItBeforeTheRecord() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let (page, _) = try acting(world)
        let lead = try await world.sleepingLead()
        let asked = try await world.asked("Ship it?", options: ["Yes", "No"], lead: lead)
        let card = try #require(world.card(asked.card.id))
        world.queue.sync { world.requests.pageVoice = Refusing() }
        let action = UUID().uuidString.lowercased()
        let reply = try #require(await fromPage(world, page, "answer", ["card": .string(card.id), "seen": .string(card.seen), "text": .string("Yes")], action: action))
        #expect(reply.error?.code == "voice" && reply.error?.message.contains("no touch") == true, "\(reply)")
        #expect(await world.actions().allSatisfy { $0.action != action })
        #expect(world.card(card.id)?.isOpen == true)
    }

    /// The settings a page never sets: web_acts raised (trust, or confirm, from trust's page: nothing above), the floors,
    /// the policy; web_acts lowered it may.
    @Test func thePageNeverSetsWhatWidensIt() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let (page, _) = try acting(world)
        for (key, value) in [("web_acts", "trust"), ("floor_merge_policy", "auto"), ("policy", "anything")] {
            let action = UUID().uuidString.lowercased()
            let reply = try #require(await fromPage(world, page, "set", ["key": .string(key), "value": .string(value)], action: action))
            #expect(reply.error?.code == "voice" && reply.error?.message.contains("from a terminal") == true, "\(key): \(reply)")
            #expect(await world.actions().allSatisfy { $0.action != action })
        }
        for value in ["off", "default", "confirm"] {
            let lower = NodeWire.Request(id: "1", kind: "set", args: ["key": .string("web_acts"), "value": .string(value)])
            #expect(world.queue.sync { world.requests.pageSetRefusal(lower) } == nil, "\(value): lower than trust")
        }
    }

    /// What a page may set, frozen: every setting declares it (`NodeSettings.Setting.page`), and a new one is the
    /// terminal's until it says otherwise; a plugin's setting is never a page's.
    @Test func whatAPageMaySetIsFrozen() {
        let sets = NodeSettings.all.filter { $0.page == .sets }.map(\.key).sorted()
        #expect(sets == ["ai_summaries", "boost", "boost_heavy_slots", "boost_load_threshold", "boost_max_sessions", "boost_max_workers",
                         "ignore_usage_limits", "lead_advisor", "lead_model", "lead_rotation", "load_threshold", "node_heavy_slots",
                         "node_max_sessions", "projects_folder", "prompt_audit", "prompt_audit_days", "worker_advisor"], "\(sets)")
        #expect(NodeSettings.all.filter { if case .lowersOnly = $0.page { return true } else { return false } }.map(\.key) == ["web_acts"])
        for setting in NodeSettings.all where setting.home == .floor || setting.guardRail || setting.home == .policy || setting.home == .acting {
            #expect(setting.page != .sets, "\(setting.key)")
        }
    }

    /// Each setting a page may not set, however it is spelled (its key, in other cases, each alias `set` takes for it),
    /// is refused from an acting page, and nothing is changed.
    @Test func everySpellingOfARefusedSettingIsRefused() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let (page, _) = try acting(world)
        for setting in NodeSettings.all where setting.page != .sets {
            let aliases = NodeSettings.aliases.filter { $0.value == setting.key }.map(\.key)
            for spelling in [setting.key, setting.key.uppercased(), setting.key.capitalized] + aliases {
                var args: [String: NodeWire.Value] = ["key": .string(spelling), "value": .string("on")]
                if setting.scope == .project { args["folder"] = .string(world.repo) }
                let reply = try #require(await fromPage(world, page, "set", args))
                #expect(!reply.ok, "\(spelling): \(reply)")
            }
        }
        // Nothing the page asked turned acting on, or changed a floor.
        let settings = try #require(await world.ask("settings", ["folder": .string(world.repo)], action: nil))
        #expect(settings.result?["node"]?["settings"]?.array?.first { $0["key"]?.string == "web_acts" }?["value"]?.string != "on")
    }

    /// `approve` from a page names each item as listed: a list that isn't the batch is refused before anything, and the
    /// batch's own code stands in once it matches; a batch that holds an item a page may not act (hooks.install), whoever
    /// listed it, is refused.
    @Test func aPagesApproveNamesEveryItemAsListedAndNeverATerminalsItem() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        // A held config whose rails an accept the vault sealed left the same: a page's to approve, as far as its card says.
        var held = CardStore.Card(root: world.repo, kind: .configHeld)
        held.config = Self.shown()
        world.queue.sync { world.engine.cards.put(held) }
        let accept = Requests.ApproveItem(kind: "config.accept", args: ["card": .string(held.id)], subject: world.repo, card: held.value, reasons: ["changed"])
        let hooks = Requests.ApproveItem(kind: "hooks.install", args: [:], subject: "claude", card: nil, reasons: ["missing"])
        func batch(_ items: [Requests.ApproveItem]) -> String {
            let id = "local:approve:" + UUID().uuidString.lowercased()
            world.queue.sync { world.requests.approveBatches.append(.init(id: id, items: items, at: Platform.Clock.steadyDate())) }
            return id
        }
        func request(_ id: String, _ seen: [String]) -> NodeWire.Request {
            NodeWire.Request(id: "1", kind: "approve", args: ["batch": .string(id), "seen": .array(seen.map(NodeWire.Value.string))], action: UUID().uuidString)
        }
        let plain = batch([accept])
        switch world.queue.sync(execute: { world.requests.seenStands(request(plain, ["nope"])) }) {
        case .refused(let reply): #expect(reply.error?.code == "changed", "\(reply)")
        case .go(let request): Issue.record("taken: \(request)")
        }
        switch world.queue.sync(execute: { world.requests.seenStands(request(plain, [accept.seen])) }) {
        case .refused(let reply): Issue.record("refused: \(reply)")
        case .go(let request): #expect(request.args?["code"]?.string == NodeIds.code(card: plain) && request.args?["seen"] == nil, "\(request)")
        }
        let mixed = batch([accept, hooks])
        switch world.queue.sync(execute: { world.requests.seenStands(request(mixed, [accept.seen, hooks.seen])) }) {
        case .refused(let reply): #expect(reply.error?.code == "voice" && reply.error?.message.contains("1 item a page may not approve") == true, "\(reply)")
        case .go(let request): Issue.record("a page approved hooks.install: \(request)")
        }
    }

    /// An acting page's `approve.list` leaves out what a page may not approve, and says how many and what runs them; a
    /// terminal's lists everything.
    @Test func aPagesApproveListLeavesOutTheTerminalsItems() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        // A held config whose rails an accept the vault sealed left the same: a page's to approve, as far as its card says.
        var held = CardStore.Card(root: world.repo, kind: .configHeld)
        held.config = Self.shown()
        world.queue.sync { world.engine.cards.put(held) }
        let accept = Requests.ApproveItem(kind: "config.accept", args: ["card": .string(held.id)], subject: world.repo, card: held.value, reasons: ["changed"])
        let hooks = Requests.ApproveItem(kind: "hooks.install", args: [:], subject: "claude", card: nil, reasons: ["missing"])
        func list(_ args: [String: NodeWire.Value]) -> NodeWire.Reply? {
            let got = Locked<NodeWire.Reply?>(nil)
            world.queue.sync {
                world.requests.listed(NodeWire.Request(id: "1", kind: "approve.list", args: args), items: [accept, hooks], own: [], engine: world.engine) { got.value = $0 }
            }
            return got.value
        }
        // What the page path marks (`pageChecks`), whatever the page sent.
        guard case .go(let marked) = world.queue.sync(execute: { world.requests.pageChecks(NodeWire.Request(id: "1", kind: "approve.list", args: [:])) }) else {
            Issue.record("approve.list refused")
            return
        }
        let fromPage = try #require(list(marked.args ?? [:]))
        #expect(fromPage.result?["items"]?.array?.compactMap { $0["kind"]?.string } == ["config.accept"], "\(fromPage)")
        #expect(fromPage.result?["terminal"]?["count"]?.int == 1 && fromPage.result?["terminal"]?["command"]?.string == "vibeswitcher approve")
        let terminal = try #require(list([:]))
        #expect(terminal.result?["items"]?.array?.compactMap { $0["kind"]?.string } == ["config.accept", "hooks.install"])
        #expect(terminal.result?["terminal"] == nil)
    }

    /// A confirmation may take seconds: what the page drew is checked again once it is given (a card changed meanwhile
    /// is refused), and so is whether the page still acts (an off meanwhile is refused).
    @Test func whatHappensDuringTheConfirmationCounts() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let (page, acting) = try acting(world)
        let lead = try await world.sleepingLead()
        let asked = try await world.asked("Ship it?", options: ["Yes", "No"], lead: lead)
        let card = try #require(world.card(asked.card.id))
        struct During: PageVoice {
            let meanwhile: @Sendable () -> Void
            func confirm(_ request: NodeWire.Request, page: String, done: @escaping @Sendable (String?) -> Void) {
                meanwhile()
                done(nil)
            }
        }
        let engine = world.engine
        world.queue.sync { world.requests.pageVoice = During { engine.cards.change(card.id) { $0.notice = "changed meanwhile" } } }
        let changed = try #require(await fromPage(world, page, "answer", ["card": .string(card.id), "seen": .string(card.seen), "text": .string("Yes")]))
        #expect(changed.error?.code == "changed", "\(changed)")
        let now = try #require(world.card(card.id))
        world.queue.sync { world.requests.pageVoice = During { _ = try? acting.set(level: "off") } }
        let off = try #require(await fromPage(world, page, "answer", ["card": .string(card.id), "seen": .string(now.seen), "text": .string("Yes")]))
        #expect(off.error?.code == "acts-ended" && off.error?.message == WebRequestScreen.notActing, "\(off)")
        #expect(world.card(card.id)?.isOpen == true)
    }

    /// `set web_acts trust` from a terminal (the user's voice, recorded first) keeps the level in the vault, says what it
    /// means and risks, and `settings` shows it from there; `confirm` is refused until its check exists; `on` is no level;
    /// off says pages read and draft again, and tells the screen at once (`onLowered`); at `confirm` (were it set) an
    /// acting page's request passes the passkey seam, which refuses it now.
    @Test func webActsIsALevelSetFromATerminalAndKeptInTheVault() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let vault = MemoryVaultV2()
        let acting = ActingPages(vault: vault.client)
        let lowered = Locked<[String]>([])
        acting.onLowered = { lowered.value.append($0) }
        world.queue.sync { world.requests.actingPages = acting }
        let trust = try #require(await world.ask("set", ["key": .string("web_acts"), "value": .string("trust")]))
        #expect(trust.ok && trust.result?["value"]?.string == "trust" && trust.result?["was"]?.string == "off", "\(trust)")
        #expect(trust.result?["say"]?.array?.first?.string?.hasPrefix("Acting from the page: trust.") == true, "\(trust)")
        #expect(trust.result?["say"]?.array?.contains { $0.string?.contains("What it risks") == true } == true)
        #expect(try vault.client.pageActs().level == "trust")
        let settings = try #require(await world.ask("settings", [:], action: nil))
        let shown = settings.result?["node"]?["settings"]?.array?.first { $0["key"]?.string == "web_acts" }
        #expect(shown?["value"]?.string == "trust", "\(String(describing: shown))")
        let confirm = try #require(await world.ask("set", ["key": .string("web_acts"), "value": .string("confirm")]))
        #expect(confirm.error?.code == "refused" && confirm.error?.message.contains("isn't built yet") == true, "\(confirm)")
        let on = try #require(await world.ask("set", ["key": .string("web_acts"), "value": .string("on")]))
        #expect(!on.ok, "\(on)")
        let off = try #require(await world.ask("set", ["key": .string("web_acts"), "value": .string("off")]))
        #expect(off.ok && off.result?["value"]?.string == "off", "\(off)")
        #expect(lowered.value == ["off"])
        #expect(try vault.client.pageActs().level == "off")
        // The passkey seam the level `confirm` uses refuses every request until it is built.
        let refused = Locked<String?>(nil)
        PasskeyNotBuilt().confirm(NodeWire.Request(id: "1", kind: "stop"), page: "p") { refused.value = $0 }
        #expect(refused.value?.contains("isn't built yet") == true)
    }

    // MARK: A held config from a page

    static let same = "the same as at your last accept (2026-11-24T00:00:00.000Z)"

    /// A held-config card's data as an accept the vault knows left it: a last accept, `test_command` the same.
    static func shown(lastAccept: Date? = Date(), rail sinceAccept: String? = same, floor: LeadReviewFloor? = LeadReviewFloor()) -> ConfigHoldStore.Shown {
        ConfigHoldStore.Shown(items: [], hashes: [:], floor: floor, rails: ["test_command": LeadVault.hash("make test")],
                              guarded: [.init(key: "test_command", value: "make test", sinceAccept: sinceAccept)], lastAccept: lastAccept)
    }

    /// From the card alone, a page may accept only what an accept the vault sealed left the same: a first accept, a
    /// changed or new rail, and a rail whose snapshot isn't sealed by this host's vault (the card's "?") are each refused.
    @Test func aPageAcceptsAHeldConfigOnlyWhenItsRailsAreTheSame() {
        #expect(ConfigHoldStore.pageNotSame(Self.shown()).isEmpty)
        #expect(ConfigHoldStore.pageNotSame(Self.shown(lastAccept: nil)) == ["no accept is recorded yet (a first accept)"])
        #expect(ConfigHoldStore.pageNotSame(Self.shown(rail: "changed since your last accept (…), from “make check”")) == ["test_command"])
        #expect(ConfigHoldStore.pageNotSame(Self.shown(rail: AcceptedSnapshot.unvouched("2026-11-24"))) == ["test_command"])
        #expect(ConfigHoldStore.pageNotSame(Self.shown(rail: nil)) == ["test_command"])
    }

    /// With the vault: the rails' hashes and the floor the recorded ones, or the page is refused (a changed rail, a
    /// changed floor, none recorded yet).
    @Test func aPageAcceptsAHeldConfigOnlyWhenTheVaultHasTheSameRailsAndFloor() throws {
        func vault(rails: [String: String]?, floor: LeadReviewFloor?) -> LeadVault {
            LeadVault(folder: scratch.url("vault-\(UUID().uuidString.prefix(6))")) { request in
                switch request {
                case .guarded: return .guarded(rails)
                case .reviewFloor: return .reviewFloor(floor)
                default: throw LeadVault.Refused("none")
                }
            }
        }
        let recorded = ["test_command": LeadVault.hash("make test")]
        #expect(try ConfigHoldStore.pageRefusal(Self.shown(), root: "/r", vault: vault(rails: recorded, floor: LeadReviewFloor())).isEmpty)
        #expect(try ConfigHoldStore.pageRefusal(Self.shown(), root: "/r", vault: vault(rails: ["test_command": LeadVault.hash("true")], floor: LeadReviewFloor()))
                == ["test_command"])
        #expect(try ConfigHoldStore.pageRefusal(Self.shown(), root: "/r", vault: vault(rails: recorded, floor: LeadReviewFloor(auditFinders: 3)))
                == ["the review floor"])
        #expect(try ConfigHoldStore.pageRefusal(Self.shown(), root: "/r", vault: vault(rails: recorded, floor: nil)) == ["the review floor"])
        #expect(try ConfigHoldStore.pageRefusal(Self.shown(), root: "/r", vault: vault(rails: nil, floor: nil)).contains("no guard rails are recorded yet"))
    }

    /// On a node: a page's accept of a first-accept card is refused before anything is recorded; one whose card says the
    /// same but whose root the vault recorded no rails for is refused when it acts (the vault asked then), the card left
    /// open; an acting page's approve list leaves such cards out and counts them for the terminal, and a batch holding
    /// one is refused.
    @Test func onANodeAPagesConfigAcceptIsTheTerminalsUnlessTheRailsAreTheSame() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let (page, _) = try acting(world)
        func card(_ shown: ConfigHoldStore.Shown) -> CardStore.Card {
            var card = CardStore.Card(root: world.repo, kind: .configHeld)
            card.config = shown
            world.queue.sync { world.engine.cards.put(card) }
            return card
        }
        let first = card(Self.shown(lastAccept: nil))
        let firstAction = UUID().uuidString.lowercased()
        let refused = try #require(await fromPage(world, page, "config.accept", ["card": .string(first.id), "seen": .string(first.seen)], action: firstAction))
        #expect(refused.error?.code == "voice" && refused.error?.message.contains("accept this one from a terminal") == true, "\(refused)")
        #expect(await world.actions().allSatisfy { $0.action != firstAction })
        let looksSame = card(Self.shown())
        let late = try #require(await fromPage(world, page, "config.accept", ["card": .string(looksSame.id), "seen": .string(looksSame.seen)]))
        #expect(late.error?.code == "refused" && late.error?.message.contains("no guard rails are recorded yet") == true, "\(late)")
        #expect(world.card(looksSame.id)?.isOpen == true)
        // The approve list and its batch.
        let changed = card(Self.shown(rail: "changed since your last accept (…)"))
        let items = [Requests.ApproveItem(kind: "config.accept", args: ["card": .string(changed.id)], subject: world.repo, card: changed.value, reasons: []),
                     Requests.ApproveItem(kind: "config.accept", args: ["card": .string(looksSame.id)], subject: world.repo, card: looksSame.value, reasons: [])]
        let got = Locked<NodeWire.Reply?>(nil)
        world.queue.sync {
            world.requests.listed(NodeWire.Request(id: "1", kind: "approve.list", args: [Requests.pageListMark: .bool(true)]), items: items, own: [],
                                  engine: world.engine) { got.value = $0 }
        }
        let listed = try #require(got.value)
        #expect(listed.result?["items"]?.array?.count == 1 && listed.result?["terminal"]?["count"]?.int == 1, "\(listed)")
        let id = "local:approve:" + UUID().uuidString.lowercased()
        world.queue.sync { world.requests.approveBatches.append(.init(id: id, items: items, at: Platform.Clock.steadyDate())) }
        let batch = NodeWire.Request(id: "2", kind: "approve", args: ["batch": .string(id), "seen": .array(items.map { .string($0.seen) })], action: UUID().uuidString)
        switch world.queue.sync(execute: { world.requests.seenStands(batch) }) {
        case .refused(let reply): #expect(reply.error?.message.contains("a page may not approve") == true, "\(reply)")
        case .go(let request): Issue.record("a page approved a changed rail: \(request)")
        }
    }
}
