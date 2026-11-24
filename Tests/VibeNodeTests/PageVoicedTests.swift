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

    /// `kind` with `args` from an acting page: its reply.
    private func fromPage(_ world: CardWorld, _ kind: String, _ args: [String: NodeWire.Value], action: String = UUID().uuidString.lowercased()) async -> NodeWire.Reply? {
        let reply = Locked<NodeWire.Reply?>(nil)
        let request = NodeWire.Request(id: UUID().uuidString, kind: kind, args: args, action: action)
        world.queue.async { world.requests.pageVoiced(request, token: Self.token, origin: Self.origin) { reply.value = $0 } }
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
        let lead = try await world.sleepingLead()
        let asked = try await world.asked("Keep the badges?", options: ["Yes", "No"], lead: lead)
        let card = try #require(world.card(asked.card.id))
        #expect(card.seen.count == 64 && card.value["seen"]?.string == card.seen)

        // A code from a page is refused: the page sends what it drew.
        let coded = try #require(await fromPage(world, "answer", ["card": .string(card.id), "code": .string(card.code), "seen": .string(card.seen), "text": .string("Yes")]))
        #expect(coded.error?.code == "bad-args", "\(coded)")
        // What it drew isn't the card now: refused, nothing recorded.
        let staleAction = UUID().uuidString.lowercased()
        let stale = try #require(await fromPage(world, "answer", ["card": .string(card.id), "seen": .string(String(repeating: "0", count: 64)), "text": .string("Yes")],
                                                action: staleAction))
        #expect(stale.error?.code == "changed", "\(stale)")
        #expect(await world.actions().allSatisfy { $0.action != staleAction })

        let action = UUID().uuidString.lowercased()
        let reply = try #require(await fromPage(world, "answer", ["card": .string(card.id), "seen": .string(card.seen), "text": .string("Yes")], action: action))
        #expect(reply.ok, "\(reply)")
        // The answer recorded as the page's (the message it sends the lead is recorded under the same action, as a
        // terminal's answer's is).
        let recorded = await world.actions().filter { $0.action == action && $0.kind == "answer" }
        #expect(recorded.count == 1, "\(recorded)")
        #expect(recorded.first?.via == ActingPages.via(token: Self.token, origin: Self.origin), "\(recorded)")
        #expect(recorded.first?.via?.hasPrefix("page \(ActingPages.digest(Self.token).prefix(12)) from http://127.0.0.1:8765") == true)
        // Answered again (a lost reply): as before, done once.
        let again = try #require(await fromPage(world, "answer", ["card": .string(card.id), "seen": .string(card.seen), "text": .string("Yes")], action: action))
        #expect(again.ok, "\(again)")
        #expect(await world.actions().filter { $0.action == action && $0.kind == "answer" }.count == 1)
    }

    /// A card that changed after the page drew it (its lead revised it) is refused: what is approved is what was shown.
    @Test func aRevisedCardIsRefusedAsChanged() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.sleepingLead()
        let asked = try await world.asked("Name it Parser?", options: ["Parser", "Reader"], lead: lead)
        let drawn = try #require(world.card(asked.card.id)).seen
        _ = try await world.revise(asked.question.id, text: "Name it Reader?", options: ["Reader", "Parser"], note: "the other way round", lead: lead)
        #expect(await eventually(timeout: 60) { world.card(asked.card.id)?.seen != drawn })
        let reply = try #require(await fromPage(world, "answer", ["card": .string(asked.card.id), "seen": .string(drawn), "text": .string("Parser")]))
        #expect(reply.error?.code == "changed", "\(reply)")
    }

    /// The confirmation seam refuses: nothing is recorded or done.
    @Test func theConfirmationSeamStopsItBeforeTheRecord() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.sleepingLead()
        let asked = try await world.asked("Ship it?", options: ["Yes", "No"], lead: lead)
        let card = try #require(world.card(asked.card.id))
        world.queue.sync { world.requests.pageVoice = Refusing() }
        let action = UUID().uuidString.lowercased()
        let reply = try #require(await fromPage(world, "answer", ["card": .string(card.id), "seen": .string(card.seen), "text": .string("Yes")], action: action))
        #expect(reply.error?.code == "voice" && reply.error?.message.contains("no touch") == true, "\(reply)")
        #expect(await world.actions().allSatisfy { $0.action != action })
        #expect(world.card(card.id)?.isOpen == true)
    }

    /// The settings a page never sets: web_acts on, the floors, the policy; web_acts off it may.
    @Test func thePageNeverSetsWhatWidensIt() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        for (key, value) in [("web_acts", "on"), ("floor_merge_policy", "auto"), ("policy", "anything")] {
            let action = UUID().uuidString.lowercased()
            let reply = try #require(await fromPage(world, "set", ["key": .string(key), "value": .string(value)], action: action))
            #expect(reply.error?.code == "voice" && reply.error?.message.contains("from a terminal") == true, "\(key): \(reply)")
            #expect(await world.actions().allSatisfy { $0.action != action })
        }
        let off = NodeWire.Request(id: "1", kind: "set", args: ["key": .string("web_acts"), "value": .string("off")])
        #expect(world.queue.sync { world.requests.pageSetRefusal(off) } == nil)
    }

    /// What a page may set, frozen: every setting declares it (`NodeSettings.Setting.page`), and a new one is the
    /// terminal's until it says otherwise; a plugin's setting is never a page's.
    @Test func whatAPageMaySetIsFrozen() {
        let sets = NodeSettings.all.filter { $0.page == .sets }.map(\.key).sorted()
        #expect(sets == ["ai_summaries", "boost", "boost_heavy_slots", "boost_load_threshold", "boost_max_sessions", "boost_max_workers",
                         "ignore_usage_limits", "lead_advisor", "lead_model", "lead_rotation", "load_threshold", "node_heavy_slots",
                         "node_max_sessions", "projects_folder", "prompt_audit", "prompt_audit_days", "worker_advisor"], "\(sets)")
        #expect(NodeSettings.all.filter { if case .offOnly = $0.page { return true } else { return false } }.map(\.key) == ["web_acts"])
        for setting in NodeSettings.all where setting.home == .floor || setting.guardRail || setting.home == .policy || setting.home == .acting {
            #expect(setting.page != .sets, "\(setting.key)")
        }
    }

    /// Each setting a page may not set, however it is spelled (its key, in other cases, each alias `set` takes for it),
    /// is refused from an acting page, and nothing is changed.
    @Test func everySpellingOfARefusedSettingIsRefused() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        for setting in NodeSettings.all where setting.page != .sets {
            let aliases = NodeSettings.aliases.filter { $0.value == setting.key }.map(\.key)
            for spelling in [setting.key, setting.key.uppercased(), setting.key.capitalized] + aliases {
                var args: [String: NodeWire.Value] = ["key": .string(spelling), "value": .string("on")]
                if setting.scope == .project { args["folder"] = .string(world.repo) }
                let reply = try #require(await fromPage(world, "set", args))
                #expect(!reply.ok, "\(spelling): \(reply)")
            }
        }
        // Nothing the page asked turned acting on, or changed a floor.
        let settings = try #require(await world.ask("settings", ["folder": .string(world.repo)], action: nil))
        #expect(settings.result?["node"]?["settings"]?.array?.first { $0["key"]?.string == "web_acts" }?["value"]?.string != "on")
    }

    /// `approve` from a page names each item as listed; a list that isn't the batch is refused before anything, and the
    /// batch's own code stands in once it matches.
    @Test func aPagesApproveNamesEveryItemAsListed() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let item = Requests.ApproveItem(kind: "hooks.install", args: [:], subject: "claude", card: nil, reasons: ["missing"])
        let id = "local:approve:" + UUID().uuidString.lowercased()
        world.queue.sync { world.requests.approveBatches.append(.init(id: id, items: [item], at: Platform.Clock.steadyDate())) }
        let request = { (seen: [String]) in
            NodeWire.Request(id: "1", kind: "approve", args: ["batch": .string(id), "seen": .array(seen.map(NodeWire.Value.string))], action: UUID().uuidString)
        }
        switch world.queue.sync(execute: { world.requests.seenStands(request(["nope"])) }) {
        case .refused(let reply): #expect(reply.error?.code == "changed", "\(reply)")
        case .go(let request): Issue.record("taken: \(request)")
        }
        switch world.queue.sync(execute: { world.requests.seenStands(request([item.seen])) }) {
        case .refused(let reply): Issue.record("refused: \(reply)")
        case .go(let request):
            #expect(request.args?["code"]?.string == NodeIds.code(card: id) && request.args?["seen"] == nil, "\(request)")
        }
    }

    /// `set web_acts on` from a terminal (the user's voice, recorded first) keeps it in the vault, says what it means,
    /// and `settings` shows it from there; off says pages read and draft again, and closes the acting pages (`onOff`).
    @Test func webActsIsSetFromATerminalAndKeptInTheVault() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let vault = MemoryVaultV2()
        let acting = ActingPages(vault: vault.client)
        let offs = Locked(0)
        acting.onOff = { offs.value += 1 }
        world.queue.sync { world.requests.actingPages = acting }
        let on = try #require(await world.ask("set", ["key": .string("web_acts"), "value": .string("on")]))
        #expect(on.ok && on.result?["value"]?.string == "on" && on.result?["was"]?.string == "off", "\(on)")
        #expect(on.result?["say"]?.array?.first?.string?.hasPrefix("Acting from the page is on.") == true, "\(on)")
        #expect(try vault.client.pageActs().on)
        let settings = try #require(await world.ask("settings", [:], action: nil))
        let shown = settings.result?["node"]?["settings"]?.array?.first { $0["key"]?.string == "web_acts" }
        #expect(shown?["value"]?.string == "on", "\(String(describing: shown))")
        let off = try #require(await world.ask("set", ["key": .string("web_acts"), "value": .string("off")]))
        #expect(off.ok && off.result?["value"]?.string == "off", "\(off)")
        #expect(offs.value == 1)
        #expect(try !vault.client.pageActs().on)
        let wrong = try #require(await world.ask("set", ["key": .string("web_acts"), "value": .string("maybe")]))
        #expect(wrong.error?.code == "bad-args", "\(wrong)")
    }
}
