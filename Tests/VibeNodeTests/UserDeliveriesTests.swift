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
        #expect(marks(world)?["answers"]?[question]?["delivered"] == .null && marks(world)?["answers"]?[question]?["replaceable"]?.bool == true,
                "\(String(describing: marks(world)))")
        #expect(marks(world)?["told"]?.array?.count == 1 && marks(world)?["told"]?.array?.first?["delivered"] == .null)
        #expect(marks(world)?["told"]?.array?.first?["text"] == nil, "a tell's mark carries no words")

        // The lead's hook takes them; the next look marks both.
        #expect(harness.hookTakes())
        world.world.look()
        #expect(await eventually(timeout: 60) {
            marks(world)?["answers"]?[question]?["delivered"]?.string != nil && marks(world)?["told"]?.array?.first?["delivered"]?.string != nil
        }, "\(String(describing: marks(world)))")
        // The board's answered question carries it, and the lead's value its tells.
        let lead = try #require(world.queue.sync { world.engine.leads.leads[NodeIds.project(root: world.repo)] })
        let value = world.queue.sync { world.requests.leadValue(lead) }
        #expect(value["told"]?.array?.first?["delivered"]?.string != nil, "\(value)")
        let fields = BoardRecords.fields(board: try BoardStore(root: world.repo).load(), read: .init(), now: Date(),
                                         delivered: marks(world)?["answers"]?.object ?? [:])
        let item = try #require(fields["answered"]?.array?.first { $0["id"]?.string == question })
        #expect(item["delivered"]?.string != nil && item["replaceable"]?.bool == false && item["card"]?.string == asked.card.id, "\(item)")
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
        // The mark says so too: no page offers to change it now.
        #expect(marks(world)?["answers"]?[asked.card.question?.id ?? ""]?["replaceable"]?.bool == false)
        let question = try #require(asked.card.question?.id)
        #expect(try BoardStore(root: world.repo).load().questions.first { $0.id == question }?.answer == "Yes")
        #expect(world.card(asked.card.id)?.question?.answer == "Yes")
    }

    /// The answer is on the lead's board as well (the review of a5a5da80, S1): one tool call of the lead's that doesn't
    /// take the inbox line (it may read the board) makes it the lead's: `delivered`, the line and the board as they were.
    @Test func aReplaceAfterTheLeadTookAStepIsRefusedDelivered() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await world.world.lead(idle: false)
        let asked = try await world.asked("Ship it?", options: ["Yes", "No"], lead: harness.session)
        _ = try #require(await world.answer(asked.card, "Yes"))
        try #require(await eventually(timeout: 60) { userLines(world, harness).contains { $0.text.contains("Ship it?") } })
        let question = try #require(asked.card.question?.id)
        #expect(marks(world)?["answers"]?[question]?["replaceable"]?.bool == true, "\(String(describing: marks(world)))")
        try world.world.hook(harness, "PostToolUse")
        let refused = try #require(await world.ask("answer.replace", ["card": .string(asked.card.id), "code": .string(asked.card.code),
                                                                      "text": .string("No")]))
        #expect(refused.error?.code == NodeWire.Code.delivered.rawValue && refused.error?.message.contains("took a step") == true, "\(refused)")
        #expect(userLines(world, harness).contains { $0.text.contains("Ship it?") }, "the line is the lead's still")
        #expect(marks(world)?["answers"]?[question]?["replaceable"]?.bool == false)
        #expect(try BoardStore(root: world.repo).load().questions.first { $0.id == question }?.answer == "Yes")
        #expect(world.card(asked.card.id)?.question?.answer == "Yes")
    }

    /// Its lead's hooks said nothing when the answer reached the board: whether it read it there can't be told, so no
    /// replace; and a look marks a step taken since without a replace asking.
    @Test func anAnswerWhoseLeadsStepsCantBeToldIsntReplaceable() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await world.world.lead(idle: false)
        let file = world.world.host.root.appendingPathComponent("state/\(harness.session.tty).json")
        try FileManager.default.removeItem(at: file)
        let asked = try await world.asked("Ship it?", options: ["Yes", "No"], lead: harness.session)
        _ = try #require(await world.answer(asked.card, "Yes"))
        try #require(await eventually(timeout: 60) { userLines(world, harness).contains { $0.text.contains("Ship it?") } })
        let question = try #require(asked.card.question?.id)
        #expect(marks(world)?["answers"]?[question]?["replaceable"]?.bool == false, "\(String(describing: marks(world)))")
        let refused = try #require(await world.ask("answer.replace", ["card": .string(asked.card.id), "code": .string(asked.card.code),
                                                                      "text": .string("No")]))
        #expect(refused.error?.code == NodeWire.Code.delivered.rawValue && refused.error?.message.contains("can't be told") == true, "\(refused)")

        // A second question, its lead's hooks there: a step, then a look, and its mark stops offering a replace.
        try world.world.hook(harness, "PreToolUse")
        let again = try await world.asked("And the docs?", options: ["Yes", "No"], lead: harness.session)
        _ = try #require(await world.answer(again.card, "Yes"))
        try #require(await eventually(timeout: 60) { userLines(world, harness).contains { $0.text.contains("And the docs?") } })
        let second = try #require(again.card.question?.id)
        #expect(marks(world)?["answers"]?[second]?["replaceable"]?.bool == true, "\(String(describing: marks(world)))")
        try world.world.hook(harness, "PostToolUse")
        world.world.look()
        #expect(await eventually(timeout: 60) { marks(world)?["answers"]?[second]?["replaceable"]?.bool == false })
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
                                                         "when": .string("interrupt")]))
        #expect(sent.ok && sent.result?["when"]?.string == "interrupt", "\(sent)")
        try await harness.waitFor { harness.agent["mode"] as? String == "idle" }
        let transcript = try String(contentsOf: harness.files.transcript, encoding: .utf8)
        #expect(transcript.contains("stop and keep the old name"), "the words weren't typed in after the Esc")

        // The vault's roster says who is a team's, not the label (the review of a5a5da80, S3): a verifier labelled
        // "Notes" is refused; a session the user labelled "Worker: …" isn't.
        let verifier = try await NodeHarness.start(on: world.host, fake: world.world.fake, cwd: world.repo, label: "Notes")
        let (repo, rostered) = (world.repo, verifier.session.id.uuidString)
        world.queue.sync {
            world.requests.teamRoster = { _ in [LeadVault.RosterEntry(root: repo, session: rostered, role: .verifier, task: "parser", holds: true)] }
        }
        let refused = try #require(await world.ask("send", ["session": .string(NodeIds.session(host: verifier.session.id)), "text": .string("stop"),
                                                            "when": .string("interrupt")]))
        #expect(!refused.ok && refused.error?.message.contains("worker or verifier") == true, "\(refused)")
        #expect(!((try? String(contentsOf: verifier.files.transcript, encoding: .utf8)) ?? "").contains("stop"))
        // Between turns, an interrupt sends no Esc, and says so (S4).
        let named = try await NodeHarness.start(on: world.host, fake: world.world.fake, cwd: world.repo, label: "Worker: write-the-parser")
        let plain = try #require(await world.ask("send", ["session": .string(NodeIds.session(host: named.session.id)), "text": .string("rename it"),
                                                          "when": .string("interrupt")]))
        #expect(plain.ok && plain.result?["when"]?.string == "step" && plain.result?["said"]?.string?.contains("no Esc") == true, "\(plain)")
        try await named.waitFor { ((try? String(contentsOf: named.files.transcript, encoding: .utf8)) ?? "").contains("rename it") }
        // The roster not answering: it can't be told, so no interrupt.
        world.queue.sync { world.requests.teamRoster = { _ in throw LeadVault.Refused("down") } }
        let unknown = try #require(await world.ask("send", ["session": .string(NodeIds.session(host: named.session.id)), "text": .string("stop"),
                                                            "when": .string("interrupt")]))
        #expect(!unknown.ok && unknown.error?.message.contains("can't be told") == true, "\(unknown)")
    }

    /// An interrupt into a session whose screen shows a question: no Esc (it would dismiss the question), nothing typed.
    @Test func anInterruptOntoAQuestionTypesNothing() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await world.world.lead(idle: false)
        harness.tell(["op": "permission", "command": "rm -rf build"])
        try await harness.screenShows { $0.contains("rm -rf build") }
        let sent = try #require(await world.ask("send", ["session": .string(NodeIds.session(host: harness.session.id)), "text": .string("go on"),
                                                         "when": .string("interrupt")]))
        #expect(!sent.ok && sent.error?.message.contains("nothing typed") == true, "\(sent)")
        #expect(harness.agent["mode"] as? String == "permission")
    }

    /// `when` (`SendWhen`): what each asks of which agent, and what is done; the ways a page is offered.
    @Test func whenResolvesByAgentAndVersion() throws {
        let new = [2, 1, 331], old = [2, 1, 200]
        #expect(SendWhen.resolve(.now, agent: .claude, version: new) == (.now, nil))
        #expect(SendWhen.resolve(.now, agent: .claude, version: [2, 1, 275]).way == .now)
        let older = SendWhen.resolve(.now, agent: .claude, version: old)
        #expect(older.way == .step && older.said?.contains("Claude Code 2.1.200, before 2.1.275") == true, "\(older)")
        let unknown = SendWhen.resolve(.now, agent: .claude, version: nil)
        #expect(unknown.way == .step && unknown.said?.contains("can't tell") == true)
        #expect(SendWhen.resolve(.after, agent: .claude, version: new).way == .step)
        #expect(SendWhen.resolve(.after, agent: .codex, version: nil) == (.after, nil))
        #expect(SendWhen.resolve(.interrupt, agent: .codex, version: nil) == (.interrupt, nil))
        #expect(SendWhen.ways(agent: .claude, version: new) == [.step, .now, .interrupt])
        #expect(SendWhen.ways(agent: .claude, version: old) == [.step, .interrupt])
        #expect(SendWhen.ways(agent: .codex, version: nil) == SendWhen.allCases)
        #expect(SendWhen.ways(agent: nil, version: nil).isEmpty)
        // The version from the path the program resolves to (Claude Code's `…/claude/versions/2.1.331`).
        let versions = scratch.url("versions")
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
        try Data().write(to: versions.appendingPathComponent("2.1.331"))
        let link = scratch.url("claude")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: versions.appendingPathComponent("2.1.331").path)
        #expect(AgentVersion.of(path: link.path) == new)
        #expect(AgentVersion.parse("2.1") == nil && AgentVersion.parse("python3.12") == nil)
    }

    /// The consent each `when` shows (the terminal's prompt and the Mac's dialog say the same): how it is delivered,
    /// the stopping of a turn said first; and the vault's record carries `when` with the rest of the request.
    @Test func theConsentSaysHowItIsDelivered() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await world.world.lead(idle: true)
        let session = NodeIds.session(host: harness.session.id)
        var texts: [String: String] = [:]
        for when in [nil] + SendWhen.allCases.map(Optional.some) {
            var args: [String: NodeWire.Value] = ["session": .string(session), "text": .string("keep it")]
            if let when { args["when"] = .string(when.rawValue) }
            let request = NodeWire.Request(id: "r", kind: "send", args: args, action: UUID().uuidString.lowercased())
            texts[when?.rawValue ?? "none"] = try world.queue.sync { try world.requests.approvalCard(request).get() }
        }
        #expect(texts["none"]?.contains("type into") == true && texts["none"]?.contains("next step") == false, "\(texts)")
        #expect(texts["step"]?.contains("at its next step") == true, "\(texts)")
        #expect(texts["now"]?.contains("now: what it runs goes to the background, or its turn stops") == true, "\(texts)")
        #expect(texts["after"]?.contains("after its turn") == true, "\(texts)")
        #expect(texts["interrupt"]?.contains("stop the turn of") == true && texts["interrupt"]?.contains("(Esc), then type into it") == true, "\(texts)")
        #expect(texts.values.allSatisfy { $0.contains("keep it") })
        // The record: the request's arguments whole, `when` among them.
        let action = UUID().uuidString.lowercased()
        let args: [String: NodeWire.Value] = ["session": .string(session), "text": .string("keep it"), "when": .string("after")]
        let sent = try #require(await world.ask("send", args, action: action))
        #expect(sent.ok, "\(sent)")
        let recorded = try await offPool { try world.world.link.vaultV2.userAction(action, kind: "send") }
        #expect(recorded?.digest == LeadVaultV2.digest(String(decoding: NodeWire.line(args), as: UTF8.self)), "\(String(describing: recorded))")
    }

    /// `now` into a Claude Code from 2.1.275 (a fake launched from `…/versions/2.1.331`) while it works: typed and Enter
    /// (queued), then Ctrl+X Ctrl+S, which sends what is queued in this turn. One launched from 2.1.200: step, said.
    @Test func nowUsesClaudesOwnSendNowFrom2_1_275() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        func versioned(_ version: String) throws -> FakeClaude.Install {
            let folder = scratch.url("claude-\(version)/versions")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let link = folder.appendingPathComponent(version)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: world.world.fake.launcher.path)
            return FakeClaude.Install(launcher: link, folder: world.world.fake.folder)
        }
        let harness = try await NodeHarness.start(on: world.host, fake: try versioned("2.1.331"))
        harness.tell(["op": "work"])
        try await harness.screenShows { $0.contains("esc to interrupt") }
        let sent = try #require(await world.ask("send", ["session": .string(NodeIds.session(host: harness.session.id)), "text": .string("use the lexer"),
                                                         "when": .string("now")]))
        #expect(sent.ok && sent.result?["when"]?.string == "now" && sent.result?["said"] == nil, "\(sent)")
        try await harness.waitFor { (harness.agent["sentNow"] as? Int) == 1 }
        #expect(((try? String(contentsOf: harness.files.transcript, encoding: .utf8)) ?? "").contains("use the lexer"))
        // A team's worker by the vault's roster gets no send-now: at its next step, said (the review of a5a5da80, S2).
        let (repo, rostered) = (world.repo, harness.session.id.uuidString)
        world.queue.sync {
            world.requests.teamRoster = { _ in [LeadVault.RosterEntry(root: repo, session: rostered, role: .worker, task: "parser", holds: true)] }
        }
        let worker = try #require(await world.ask("send", ["session": .string(NodeIds.session(host: harness.session.id)), "text": .string("and the parser"),
                                                           "when": .string("now")]))
        #expect(worker.ok && worker.result?["when"]?.string == "step" && worker.result?["said"]?.string?.contains("worker or verifier") == true, "\(worker)")
        // Typed in and queued for after its turn (its hooks said nothing here, so no steer).
        try await harness.screenShows { $0.contains("and the parser") }
        #expect((harness.agent["sentNow"] as? Int) == 1, "no second send-now")
        world.queue.sync { world.requests.teamRoster = { try $0.roster() } }

        let older = try await NodeHarness.start(on: world.host, fake: try versioned("2.1.200"))
        let fell = try #require(await world.ask("send", ["session": .string(NodeIds.session(host: older.session.id)), "text": .string("use the lexer"),
                                                         "when": .string("now")]))
        #expect(fell.ok && fell.result?["when"]?.string == "step" && fell.result?["said"]?.string?.contains("before 2.1.275") == true, "\(fell)")
        // An older page's `now: true` is `when: now`.
        let legacy = try #require(await world.ask("send", ["session": .string(NodeIds.session(host: older.session.id)), "text": .string("again"),
                                                           "now": .bool(true)]))
        #expect(legacy.result?["when"]?.string == "step", "\(legacy)")
    }
}
