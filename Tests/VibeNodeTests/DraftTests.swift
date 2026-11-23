import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// A web page's draft answer (the live plan's B5 and I3, LW-D6; the wire contract's §8): the user's words left on a card
/// in the server's memory and told to nobody. The lead hears nothing, the vault records nothing, until the user takes
/// it with `vibeswitcher answer CARD` and types the card's code (`AnswerVoiceTests`). Each case drives the server's own
/// live side (`NodeLive`, as `ServerStart` makes it) on a `CardWorld`: a page's requests through the web's screen
/// (`WebRequestScreen`) and the hub, as the listener hands them on, and its frames read from the page's transport.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct DraftTests {
    private let scratch = Scratch()

    /// The server's live side on `world`, a page on it whose token reads and drafts (`WebAccess.rights`), and a card a
    /// sleeping lead asked.
    private final class Rig: @unchecked Sendable {
        let world: CardWorld
        let live: NodeLive
        let screen: WebRequestScreen
        let page = Recorder()
        let lead: HostSession
        let card: CardStore.Card
        private let counter = Locked(0)

        init(_ world: CardWorld, lead: HostSession, card: CardStore.Card) {
            self.world = world
            self.lead = lead
            self.card = card
            // A clock that never wakes: the cases wait on frames, never on a tick.
            let clock = NodeClock(queue: world.queue, now: { 0 }, schedule: { _, _ in {} })
            live = NodeLive(requests: world.requests, sessions: nil, engine: world.engine, clock: clock, port: 0)
            let live = live
            world.queue.sync { live.start() }
            screen = WebRequestScreen(live.hub)
            screen.opened(page, rights: WebAccess.rights)
        }

        static func make(_ scratch: Scratch) async throws -> Rig {
            let world = try await CardWorld.make(scratch)
            let lead = try await world.sleepingLead()
            let card = try await world.asked("Merge the login fix now?", options: ["Yes, merge it", "Wait for the audit"], lead: lead).card
            return Rig(world, lead: lead, card: card)
        }

        func stop() { world.stop() }

        /// `kind` with `args` and `action` sent by `page` (this rig's by default): its request id.
        @discardableResult
        func send(_ kind: String, _ args: [String: NodeWire.Value], action: String? = UUID().uuidString.lowercased(), on page: Recorder? = nil) -> String {
            var next = 0
            counter.mutate { $0 += 1; next = $0 }
            let id = String(next)
            screen.text(NodeWire.message(NodeWire.Request(id: id, kind: kind, args: args, action: action)), on: page ?? self.page)
            return id
        }

        /// The reply to request `id` on `page` (this rig's by default), once it came.
        func reply(_ id: String, on page: Recorder? = nil) async throws -> NodeWire.Value {
            let page = page ?? self.page
            try #require(await eventually { page.messages.contains { $0["re"]?.string == id } }, "no reply to \(id): \(page.messages)")
            return try #require(page.messages.first { $0["re"]?.string == id })
        }

        /// A draft of `text` for `version` (the card's by default): its reply.
        func draft(_ text: String, version: Int? = nil, action: String = UUID().uuidString.lowercased()) async throws -> NodeWire.Value {
            let id = send("draft", ["card": .string(card.id), "text": .string(text), "version": .int(version ?? card.question?.version ?? 1)], action: action)
            return try await reply(id)
        }

        /// The card as the server holds it now.
        var now: CardStore.Card? { world.card(card.id) }

        /// The page follows `cards` (`s3`): the subscription's snapshot's `seq`.
        func subscribe() async throws -> Int {
            let id = send("subscribe", ["sub": .string("s3"), "collection": .string("cards")], action: nil)
            _ = try await reply(id)
            try #require(await eventually { self.page.events.contains { $0["sub"]?.string == "s3" } })
            return try #require(page.events.first { $0["sub"]?.string == "s3" }?["seq"]?.int)
        }
    }

    // MARK: The Seamless rows

    /// The ack's `applied` is the `cards` stream's `seq` at which the draft is in it, and the delta carrying it is written
    /// before the ack: a page's overlay is never dropped before the stream shows what it overlaid.
    @Test func theAckSaysTheSeqItsEffectIsAt() async throws {
        let rig = try await Rig.make(scratch)
        defer { rig.stop() }
        _ = try await rig.subscribe()
        let ack = try await rig.draft("Yes, merge it")
        #expect(ack["ok"]?.bool == true, "\(ack)")
        #expect(ack["result"]?["card"]?.string == rig.card.id, "\(ack)")
        let applied = try #require(ack["result"]?["applied"]?["cards"]?.int, "\(ack)")
        let messages = rig.page.messages
        let carrying = try #require(messages.firstIndex { message in
            message["kind"]?.string == "delta" && message["changes"]?.array?.contains { $0["value"]?["draft"]?["text"]?.string == "Yes, merge it" } == true
        }, "no delta carried the draft: \(messages)")
        #expect(messages[carrying]["seq"]?.int == applied, "\(messages[carrying]) against \(ack)")
        let acked = try #require(messages.firstIndex { $0["re"] == ack["re"] })
        #expect(carrying < acked, "the ack came before its delta: \(messages)")
        let draft = try #require(rig.now?.draft)
        #expect(draft.text == "Yes, merge it" && draft.version == rig.card.question?.version)
        #expect(WireSchema.check(ack, as: "reply.draft") == nil, "\(ack)")
        for frame in messages { #expect(WireSchema.check(frame, as: "frame") == nil, "\(frame)") }
    }

    /// The same action id again (a page retrying after its socket dropped) is answered as the first was, and not done
    /// again; sent again with other words, it is told the action was recorded with other arguments, given nothing of the
    /// first, and changes nothing.
    @Test func aRepeatedActionIsAnsweredAsBefore() async throws {
        let rig = try await Rig.make(scratch)
        defer { rig.stop() }
        let action = UUID().uuidString.lowercased()
        let first = try await rig.draft("Yes, merge it", action: action)
        #expect(first["ok"]?.bool == true, "\(first)")
        let at = try #require(rig.now?.draft?.at)
        let same = try await rig.draft("Yes, merge it", action: action)
        #expect(same["result"] == first["result"] && same["ok"] == first["ok"] && same["re"] != first["re"], "\(first) then \(same)")
        let again = try await rig.draft("Wait for the audit", action: action)
        #expect(again["ok"]?.bool == false && again["error"]?["message"]?.string == Requests.otherArguments(action: action), "\(again)")
        #expect(rig.now?.draft?.text == "Yes, merge it" && rig.now?.draft?.at == at)
    }

    // MARK: Told to nobody

    /// A draft reaches no lead and no vault: nothing is held or typed for the lead, nothing recorded as the user's, the
    /// board's question unanswered and the card open. It is the card's, in the server's memory, and nothing else.
    @Test func aDraftTellsNobody() async throws {
        let rig = try await Rig.make(scratch)
        defer { rig.stop() }
        let acting = Locked<[String]>([])
        rig.world.queue.sync { rig.world.requests.acting = { request in acting.mutate { $0.append(request.kind) } } }
        let ack = try await rig.draft("Yes, merge it")
        #expect(ack["ok"]?.bool == true, "\(ack)")
        let cleared = try await rig.reply(rig.send("draft.clear", ["card": .string(rig.card.id)]))
        #expect(cleared["ok"]?.bool == true, "\(cleared)")
        _ = try await rig.draft("Wait for the audit")
        await rig.world.drained()
        let recorded = await rig.world.actions()
        #expect(recorded.isEmpty, "the vault recorded \(recorded)")
        #expect(rig.world.held().isEmpty, "held for the lead: \(rig.world.held())")
        #expect(rig.world.board().questions.first?.answer == nil)
        #expect(rig.world.queue.sync { rig.world.requests.accepted }.isEmpty)
        #expect(acting.value.isEmpty, "acted on as a request: \(acting.value)")
        #expect(rig.now?.isOpen == true && rig.now?.draft?.text == "Wait for the audit")
    }

    // MARK: Refused

    /// A draft for a wording the lead has revised since is refused, saying so; and the revision takes off a draft made
    /// for the old wording, so `vibeswitcher answer` never takes words chosen for a question that is no longer asked.
    @Test func aDraftForAnOlderWordingIsRefused() async throws {
        let rig = try await Rig.make(scratch)
        defer { rig.stop() }
        let version = try #require(rig.card.question?.version)
        #expect(try await rig.draft("Yes, merge it")["ok"]?.bool == true)
        let question = try #require(rig.world.board().questions.first)
        let revised = try await rig.world.revise(question.id, text: "Merge the login fix now, or wait for the audit?", options: nil,
                                                 note: "named the audit", lead: rig.lead)
        try #require(revised.reply?.ok == true, "\(String(describing: revised.reply))")
        #expect(await eventually { rig.now?.question?.version == version + 1 })
        #expect(rig.now?.draft == nil, "a draft outlived the wording it was for: \(String(describing: rig.now?.draft))")
        let refused = try await rig.draft("Yes, merge it", version: version)
        #expect(refused["ok"]?.bool == false && refused["error"]?["code"]?.string == "refused", "\(refused)")
        #expect(refused["error"]?["message"]?.string?.contains("revised") == true, "\(refused)")
        #expect(rig.now?.draft == nil)
        #expect(try await rig.draft("Wait for the audit", version: version + 1)["ok"]?.bool == true)
    }

    /// On the Unix socket a draft is no one's to leave: refused `voice`, from the user's own terminal too, and nothing
    /// is kept.
    @Test func aDraftOnTheUnixSocketIsRefused() async throws {
        let rig = try await Rig.make(scratch)
        defer { rig.stop() }
        for kind in ["draft", "draft.clear"] {
            let reply = try #require(await rig.world.ask(kind, ["card": .string(rig.card.id), "text": .string("Yes, merge it"),
                                                               "version": .int(rig.card.question?.version ?? 1)]))
            #expect(reply.error?.code == NodeWire.Code.voice.rawValue, "\(kind): \(reply)")
            #expect(reply.error?.message.contains("web page") == true, "\(kind): \(reply)")
        }
        #expect(rig.now?.draft == nil)
        #expect(await rig.world.actions().isEmpty)
    }

    /// A page whose token only reads leaves no draft: the screen refuses it before the hub, and the server's own check
    /// would too.
    @Test func aTokenThatOnlyReadsLeavesNoDraft() async throws {
        let rig = try await Rig.make(scratch)
        defer { rig.stop() }
        let reader = Recorder()
        rig.screen.opened(reader, rights: [.read])
        let id = rig.send("draft", ["card": .string(rig.card.id), "text": .string("Yes"), "version": .int(1)], on: reader)
        let reply = try await rig.reply(id, on: reader)
        #expect(reply["error"]?["code"]?.string == "voice", "\(reply)")
        #expect(rig.now?.draft == nil)
    }

    /// The card named by a prefix, a draft with no action id, no text or a closed card: each refused, nothing kept.
    @Test func aDraftNeedsTheWholeCardAnActionAndText() async throws {
        let rig = try await Rig.make(scratch)
        defer { rig.stop() }
        let short = String(rig.card.id.dropFirst("local:card:".count).prefix(8))
        let prefixed = try await rig.reply(rig.send("draft", ["card": .string(short), "text": .string("Yes"), "version": .int(1)]))
        #expect(prefixed["error"]?["code"]?.string == "gone", "\(prefixed)")
        let unnamed = try await rig.reply(rig.send("draft", ["card": .string(rig.card.id), "text": .string("Yes"), "version": .int(1)], action: nil))
        #expect(unnamed["error"]?["code"]?.string == "bad-args", "\(unnamed)")
        let empty = try await rig.draft("  \n")
        #expect(empty["error"]?["code"]?.string == "bad-args", "\(empty)")
        let long = try await rig.draft(String(repeating: "a", count: Requests.draftLength + 1))
        #expect(long["error"]?["code"]?.string == "bad-args", "\(long)")
        #expect(rig.now?.draft == nil)
    }

    // MARK: Closing

    /// The user's answer (in a terminal, the code typed) closes the card and takes its draft off, in the same delta; a
    /// draft on the closed card is then `gone`.
    @Test func anAnswerClearsTheDraft() async throws {
        let rig = try await Rig.make(scratch)
        defer { rig.stop() }
        _ = try await rig.subscribe()
        #expect(try await rig.draft("Yes, merge it")["ok"]?.bool == true)
        let card = try #require(rig.now)
        let answered = try #require(await rig.world.answer(card, "Yes, merge it", version: card.draft?.version))
        #expect(answered.result?["outcome"]?.string == "answered", "\(answered)")
        #expect(rig.now?.isOpen == false && rig.now?.draft == nil)
        #expect(await eventually {
            rig.page.events.contains { event in
                event["changes"]?.array?.contains { $0["value"]?["open"]?.bool == false && $0["value"]?["draft"] == .null } == true
            }
        }, "no delta closed the card with its draft off: \(rig.page.events)")
        let late = try await rig.draft("Wait for the audit")
        #expect(late["error"]?["code"]?.string == "gone", "\(late)")
    }

    /// `draft.clear` takes the draft off, acked with the `seq` it is at.
    @Test func aClearTakesTheDraftOff() async throws {
        let rig = try await Rig.make(scratch)
        defer { rig.stop() }
        _ = try await rig.subscribe()
        #expect(try await rig.draft("Yes, merge it")["ok"]?.bool == true)
        let cleared = try await rig.reply(rig.send("draft.clear", ["card": .string(rig.card.id)]))
        let applied = try #require(cleared["result"]?["applied"]?["cards"]?.int, "\(cleared)")
        #expect(rig.now?.draft == nil && rig.now?.isOpen == true)
        let last = try #require(rig.page.events.last { $0["kind"]?.string == "delta" })
        #expect(last["seq"]?.int == applied && last["changes"]?.array?.first?["value"]?["draft"] == .null, "\(last)")
    }
}
