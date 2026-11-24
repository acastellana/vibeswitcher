import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The user's answers and tells on their way to a lead (`UserDeliveries.swift`, 2026-11-24): read marks once the lead's
/// hook takes them; `answer.replace` and `tell.retract` only while the lead hasn't had them (pulled from its inbox under
/// the inbox's lock, refused `delivered` when the lead took them first); `send` with `interrupt` into a working Claude:
/// Esc, its idle prompt, then the words, one unit. Against a scratch host and a fake Claude lead (mid-turn, so what is
/// sent waits in its inbox until its hook takes it).
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct UserDeliveriesTests {
    private let scratch = Scratch()

    func marks(_ world: CardWorld) -> NodeWire.Value? { world.queue.sync { world.engine.deliveryMarks.values[world.repo] } }

    func userLines(_ world: CardWorld, _ harness: NodeHarness) -> [SteerMessage] { world.world.pending(harness).filter { $0.from == .user } }

    @Test func aTakenAnswerAndTellAreMarkedDelivered() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await world.world.lead(idle: false)
        let asked = try await world.asked("Ship it?", options: ["Yes", "No"], lead: harness.session)
        let answered = try #require(await world.answer(asked.card, "Yes"))
        #expect(answered.ok, "\(answered)")
        try #require(await eventually(timeout: 60) { userLines(world, harness).contains { $0.text.contains("Ship it?") } })
        let told = try #require(await world.ask("tell", ["folder": .string(world.repo), "text": .string("and keep the old name")]))
        #expect(told.ok, "\(told)")
        try #require(await eventually(timeout: 60) { userLines(world, harness).contains { $0.text.contains("keep the old name") } })
        let question = try #require(asked.card.question?.id)
        #expect(marks(world)?["answers"]?[question] == .null, "\(String(describing: marks(world)))")
        #expect(marks(world)?["told"]?.array?.count == 1 && marks(world)?["told"]?.array?.first?["delivered"] == .null)
        #expect(marks(world)?["told"]?.array?.first?["text"] == nil, "a tell's mark carries no words")

        // The lead's hook takes them; the next look marks both.
        #expect(harness.hookTakes())
        world.world.look()
        #expect(await eventually(timeout: 60) {
            marks(world)?["answers"]?[question]?.string != nil && marks(world)?["told"]?.array?.first?["delivered"]?.string != nil
        }, "\(String(describing: marks(world)))")
        // The board's answered question carries it, and the lead's value its tells.
        let lead = try #require(world.queue.sync { world.engine.leads.leads[NodeIds.project(root: world.repo)] })
        let value = world.queue.sync { world.requests.leadValue(lead) }
        #expect(value["told"]?.array?.first?["delivered"]?.string != nil, "\(value)")
        let fields = BoardRecords.fields(board: try BoardStore(root: world.repo).load(), read: .init(), now: Date(),
                                         delivered: marks(world)?["answers"]?.object ?? [:])
        let item = try #require(fields["answered"]?.array?.first { $0["id"]?.string == question })
        #expect(item["delivered"]?.string != nil, "\(item)")
        #expect(WireSchema.check(item, as: "board.question") == nil)
    }

    @Test func anAnswerReplacedBeforeTheLeadHasItGoesInItsPlace() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await world.world.lead(idle: false)
        let asked = try await world.asked("Ship it?", options: ["Yes", "No"], lead: harness.session)
        let first = UUID().uuidString.lowercased()
        _ = try #require(await world.answer(asked.card, "Yes", action: first))
        try #require(await eventually(timeout: 60) { userLines(world, harness).contains { $0.text.contains("Ship it?") } })
        let pulled = try #require(userLines(world, harness).first).id
        let second = UUID().uuidString.lowercased()
        let replaced = try #require(await world.ask("answer.replace", ["card": .string(asked.card.id), "code": .string(asked.card.code),
                                                                       "text": .string("No, wait for the audit")], action: second))
        #expect(replaced.ok && replaced.result?["outcome"]?.string == "replaced", "\(replaced)")
        // The first is out of the inbox (its seal retired at the next look), the new one there in its place.
        #expect(await eventually(timeout: 60) { userLines(world, harness).contains { $0.text.contains("No, wait for the audit") } })
        let lines = userLines(world, harness)
        #expect(!lines.contains { $0.id == pulled } && lines.filter { $0.text.contains("Ship it?") }.count == 1, "\(lines)")
        #expect(lines.first?.text.contains("replaces an earlier answer") == true)
        #expect(world.queue.sync { world.engine.withdrawnUser.contains(pulled) || world.engine.postedUser[pulled] == nil })
        // The board, the card and the vault say the new one, the vault marking it as replacing the first.
        let question = try #require(asked.card.question?.id)
        #expect(try BoardStore(root: world.repo).load().questions.first { $0.id == question }?.answer == "No, wait for the audit")
        #expect(world.card(asked.card.id)?.question?.answer == "No, wait for the audit")
        let recorded = try await offPool { try world.world.link.vaultV2.userAction(second, kind: LeadEngine.replacesKind) }
        #expect(recorded?.subject == first, "\(String(describing: recorded))")
    }

    /// The race: the lead's hook takes the answer between the engine's last look (which saw it waiting) and the
    /// replacement's pull: nothing is left to pull under the inbox's lock, so `delivered`, nothing replaced.
    @Test func aReplaceAfterTheLeadTookTheAnswerIsRefusedDelivered() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await world.world.lead(idle: false)
        let asked = try await world.asked("Ship it?", options: ["Yes", "No"], lead: harness.session)
        _ = try #require(await world.answer(asked.card, "Yes"))
        try #require(await eventually(timeout: 60) { userLines(world, harness).contains { $0.text.contains("Ship it?") } })
        #expect(harness.hookTakes())
        let refused = try #require(await world.ask("answer.replace", ["card": .string(asked.card.id), "code": .string(asked.card.code),
                                                                      "text": .string("No")]))
        #expect(refused.error?.code == NodeWire.Code.delivered.rawValue, "\(refused)")
        #expect(userLines(world, harness).isEmpty, "\(userLines(world, harness))")
        let question = try #require(asked.card.question?.id)
        #expect(try BoardStore(root: world.repo).load().questions.first { $0.id == question }?.answer == "Yes")
        #expect(world.card(asked.card.id)?.question?.answer == "Yes")
    }

    /// A message partly handed (a long one's first part went) or named by a wake-up prompt is the lead's: the inbox's
    /// conditional withdrawal leaves it, under the lock.
    @Test func aPartlyHandedOrWokenMessageIsntPulled() throws {
        let root = scratch.url("inbox-root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sealer = SteerSeal.scratch(root)
        let unless = { (message: SteerMessage) in message.handedOver != nil || message.wokenAt != nil }
        for (index, (name, change)) in [("handed", { (m: inout SteerMessage) in m.handedOver = 10 }), ("woken", { (m: inout SteerMessage) in m.wokenAt = 1 }),
                                        ("plain", { (_: inout SteerMessage) in })].enumerated() {
            let tty = "ttys90\(index)"
            var message = SteerMessage(id: name, text: String(repeating: "x", count: 40), from: .user, agentPid: 7)
            change(&message)
            try SteerInbox.post(message, tty: tty, root: root, sealer: sealer)
            let pulled = SteerInbox.withdraw(id: name, tty: tty, root: root, unless: unless)
            #expect((pulled != nil) == (name == "plain"), "\(name)")
            #expect(SteerInbox.pending(tty: tty, root: root).contains { $0.id == name } == (name != "plain"), "\(name)")
        }
    }

    @Test func anApprovalsAnswerIsNeverReplaced() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await world.world.lead(idle: false)
        let commit = String(repeating: "c", count: 40)
        let asked = try await world.asked("Merge it?", options: ["Approve \(commit)", "Not yet"], lead: harness.session)
        #expect(asked.card.kind == .approval)
        let refused = try #require(await world.ask("answer.replace", ["card": .string(asked.card.id), "code": .string(asked.card.code),
                                                                      "text": .string("Not yet")]))
        #expect(!refused.ok && refused.error?.message.contains("answer.replace doesn't take it") == true, "\(refused)")
    }

    @Test func aTellIsRetractedOnlyBeforeTheLeadHasIt() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await world.world.lead(idle: false)
        let first = UUID().uuidString.lowercased()
        _ = try #require(await world.ask("tell", ["folder": .string(world.repo), "text": .string("drop the parser")], action: first))
        try #require(await eventually(timeout: 60) { userLines(world, harness).contains { $0.text.contains("drop the parser") } })
        let retracted = try #require(await world.ask("tell.retract", ["action": .string(first)]))
        #expect(retracted.ok && retracted.result?["retracted"]?.bool == true, "\(retracted)")
        #expect(!userLines(world, harness).contains { $0.text.contains("drop the parser") })
        #expect(marks(world)?["told"]?.array?.isEmpty == true, "a retracted tell has no mark")
        // Once more: nothing of it is on its way.
        let again = try #require(await world.ask("tell.retract", ["action": .string(first)]))
        #expect(again.error?.code == NodeWire.Code.gone.rawValue, "\(again)")
        // Taken by the lead first: delivered.
        let second = UUID().uuidString.lowercased()
        _ = try #require(await world.ask("tell", ["folder": .string(world.repo), "text": .string("keep the lexer")], action: second))
        try #require(await eventually(timeout: 60) { userLines(world, harness).contains { $0.text.contains("keep the lexer") } })
        #expect(harness.hookTakes())
        let late = try #require(await world.ask("tell.retract", ["action": .string(second)]))
        #expect(late.error?.code == NodeWire.Code.delivered.rawValue, "\(late)")
    }

    /// `send` with `interrupt` into a working Claude lead: Esc stops its turn, its idle prompt comes back, and the words
    /// go in as the user's turn, one unit. Into a worker: refused, nothing typed.
    @Test func anInterruptStopsTheTurnThenTypesTheWords() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await world.world.lead(idle: false)
        harness.tell(["op": "work"])
        try await harness.screenShows { $0.contains("esc to interrupt") }
        let session = NodeIds.session(host: harness.session.id)
        let sent = try #require(await world.ask("send", ["session": .string(session), "text": .string("stop and keep the old name"),
                                                         "interrupt": .bool(true)]))
        #expect(sent.ok && sent.result?["interrupted"]?.bool == true, "\(sent)")
        try await harness.waitFor { harness.agent["mode"] as? String == "idle" }
        let transcript = try String(contentsOf: harness.files.transcript, encoding: .utf8)
        #expect(transcript.contains("stop and keep the old name"), "the words weren't typed in after the Esc")

        let worker = try await NodeHarness.start(on: world.host, fake: world.world.fake, cwd: world.repo, label: "Worker: write-the-parser")
        let refused = try #require(await world.ask("send", ["session": .string(NodeIds.session(host: worker.session.id)), "text": .string("stop"),
                                                            "interrupt": .bool(true)]))
        #expect(!refused.ok && refused.error?.message.contains("worker or verifier") == true, "\(refused)")
        #expect(!((try? String(contentsOf: worker.files.transcript, encoding: .utf8)) ?? "").contains("stop"))
    }

    /// An interrupt into a session whose screen shows a question: no Esc (it would dismiss the question), nothing typed.
    @Test func anInterruptOntoAQuestionTypesNothing() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await world.world.lead(idle: false)
        harness.tell(["op": "permission", "command": "rm -rf build"])
        try await harness.screenShows { $0.contains("rm -rf build") }
        let sent = try #require(await world.ask("send", ["session": .string(NodeIds.session(host: harness.session.id)), "text": .string("go on"),
                                                         "interrupt": .bool(true)]))
        #expect(!sent.ok && sent.error?.message.contains("nothing typed") == true, "\(sent)")
        #expect(harness.agent["mode"] as? String == "permission")
    }
}
