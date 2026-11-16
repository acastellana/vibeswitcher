import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The user's answers and holds (the engine plan's E6; the app's `LeadController.answer`, `hold` and the timers,
/// 1118-1201): an answer bound to the card, recorded in the host's vault before anything acts on it, then on the board,
/// and the lead told as the user's; every state-changing request in the vault first; a repeated action done once; a
/// code that isn't the card's refused.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct AnswerTests {
    private let scratch = Scratch()

    @Test func aWithdrawnQuestionsAnswerReachesTheLeadAsANote() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await world.world.lead(idle: false)
        let lead = harness.session
        let asked = try await world.asked("Keep the badges?", options: ["Yes", "No"], lead: lead)
        let gone = try BoardStore(root: world.repo).update { try $0.withdraw(asked.question.id, reason: "not needed") }
        #expect(try #require(await world.post(gone, op: .withdraw, lead: lead)).ok)
        let reply = try #require(await world.answer(asked.card, "Yes"))
        #expect(reply.result?["outcome"]?.string == "withdrawn", "\(reply)")
        #expect(reply.result?["notice"]?.string?.hasPrefix("Withdrawn before your answer: not needed") == true, "\(reply)")
        #expect(await eventually(timeout: 60) {
            world.world.pending(harness).contains { $0.from == .user && $0.text.contains("withdrawn question") && $0.text.contains("Take it as a note") }
        }, "\(world.world.pending(harness))")
    }

    @Test func anAnswerAfterTheTimerSaysTheLeadWentAhead() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.sleepingLead()
        let asked = try await world.asked("Name it Parser?", options: ["Parser", "Reader"], proposal: "Parser", decideIn: 1, lead: lead)
        world.engine.runTimers(now: Date().timeIntervalSince1970 + 120)
        #expect(await eventually(timeout: 60) { world.card(asked.card.id)?.closed?.hasPrefix("decided by its timer") == true })
        let decided = try #require(world.card(asked.card.id))
        let reply = try #require(await world.answer(decided, "Reader"))
        #expect(reply.result?["outcome"]?.string == "afterAutoDecision", "\(reply)")
        #expect(reply.result?["notice"]?.string?.hasPrefix("The timer had run out: the lead went ahead with ‘Parser’") == true, "\(reply)")
        // Recorded in the vault first, then held for the lead (none runs).
        #expect(await eventually(timeout: 60) { world.held().contains { $0.from == .user && $0.text.contains("after its timer ran out") } },
                "\(world.held())")
    }

    @Test func anAlreadyAnsweredQuestionIsntAnsweredTwice() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.sleepingLead()
        let asked = try await world.asked("Ship it?", options: ["Yes", "No"], lead: lead)
        #expect(try #require(await world.answer(asked.card, "Yes")).result?["outcome"]?.string == "answered")
        let answered = try #require(world.card(asked.card.id))
        let again = try #require(await world.answer(answered, "No"))
        #expect(again.result?["outcome"]?.string == "alreadyAnswered", "\(again)")
        #expect(again.result?["notice"]?.string == "Already answered: Yes. Your new answer wasn't sent.", "\(again)")
        #expect(world.board().questions.first?.answer == "Yes")
        await world.drained()
        #expect(world.held().filter { $0.from == .user }.count == 1, "\(world.held())")
    }

    @Test func holdStopsTheTimerAndTellsTheLeadNotToGoAhead() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.sleepingLead()
        let asked = try await world.asked("Name it Parser?", options: ["Parser", "Reader"], proposal: "Parser", decideIn: 1, lead: lead)
        let reply = try #require(await world.ask("hold", ["card": .string(asked.card.id), "code": .string(asked.card.code)]))
        #expect(reply.ok, "\(reply)")
        let held = try #require(world.board().questions.first)
        #expect(held.heldAt != nil && !held.isCounting)
        await world.drained()
        #expect(await eventually(timeout: 60) {
            world.held().contains { $0.from == .user && $0.text.contains("The user is holding your question") && $0.text.contains("don't go ahead") }
        }, "\(world.held())")
        world.engine.runTimers(now: Date().timeIntervalSince1970 + 120)
        await world.drained()
        #expect(world.board().questions.first?.state == .open)
        #expect(!world.held().contains { $0.from == .system("timer") })
        #expect(world.card(asked.card.id)?.isOpen == true)
    }

    @Test func aTimerThatRunsOutTellsTheLeadOnce() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.sleepingLead()
        let asked = try await world.asked("Name it Parser?", options: ["Parser", "Reader"], proposal: "Parser", decideIn: 1, lead: lead)
        let later = Date().timeIntervalSince1970 + 120
        world.engine.runTimers(now: later)
        #expect(await eventually(timeout: 60) { world.held().contains { $0.from == .system("timer") } })
        world.engine.runTimers(now: later + 10)
        await world.drained()
        let told = world.held().filter { $0.from == .system("timer") }
        #expect(told.count == 1, "\(world.held())")
        #expect(told.first?.text.contains("going with your proposal ‘Parser’") == true)
        #expect(world.card(asked.card.id)?.closed == "decided by its timer: Parser")
    }

    /// The answer's action and the message's digest are in the vault when the lead's inbox gets it (read on the engine's
    /// reads queue just before it's posted).
    @Test func anAnswerIsRecordedInTheVaultBeforeTheLeadIsTold() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await world.world.lead(idle: false)
        let asked = try await world.asked("Ship it?", options: ["Yes", "No"], lead: harness.session)
        let action = UUID().uuidString.lowercased()
        let client = world.world.link.vaultV2
        let recorded = Locked<[String]?>(nil)
        world.queue.sync {
            world.engine.inboxRead = { tty in
                guard tty == harness.session.tty, recorded.value == nil else { return }
                recorded.value = ((try? client.userActions()) ?? []).filter { $0.action == action }.map(\.kind)
            }
        }
        let reply = try #require(await world.answer(asked.card, "Yes", action: action))
        #expect(reply.ok, "\(reply)")
        #expect(await eventually(timeout: 60) { world.world.pending(harness).contains { $0.from == .user && $0.text.contains("Ship it?") } })
        #expect(recorded.value == ["answer", "message"], "\(String(describing: recorded.value))")
        let message = try #require(world.world.pending(harness).first { $0.from == .user })
        #expect(try await offPool { try client.holds(action: action, digest: LeadVaultV2.digest(message.text)) })
    }

    /// The E6 review: the user's message keeps the place it was sent in while the vault records it (the record runs on
    /// the engine's `work`, held up here), so what VibeSwitcher sends that lead meanwhile comes after it.
    @Test func theUsersMessageKeepsItsPlaceWhileTheVaultRecordsIt() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        _ = try await world.sleepingLead()
        let gate = DispatchSemaphore(value: 0)
        world.engine.work.async(flags: .barrier) { gate.wait() }
        world.queue.async {
            world.engine.tellAsUser("first, the user's", root: world.repo, action: UUID().uuidString.lowercased())
            world.engine.deliver(built: { "second, VibeSwitcher's" }, from: .system("test"), root: world.repo, action: nil)
        }
        let waited = await eventually(timeout: 30) { world.held().contains { $0.text.hasPrefix("second") } }
        gate.signal()
        #expect(waited, "\(world.held())")
        #expect(await eventually(timeout: 60) { world.held().count == 2 }, "\(world.held())")
        #expect(world.held().map(\.text) == ["first, the user's", "second, VibeSwitcher's"])
        #expect(world.held().first?.from == .user)
    }

    /// Each kind the server records, in the vault when it acts.
    @Test func everyAcceptedRequestIsInTheVaultBeforeItActs() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.sleepingLead()
        let client = world.world.link.vaultV2
        let seen = Locked<[String: Bool]>([:])
        world.queue.sync {
            world.requests.acting = { request in
                guard Requests.recorded.contains(request.kind), let action = request.action?.lowercased() else { return }
                seen.mutate { $0[request.kind] = ((try? client.userActions()) ?? []).contains { $0.action == action && $0.kind == request.kind } }
            }
        }
        let question = try await world.asked("Name it?", options: ["A", "B"], proposal: "A", decideIn: 5, lead: lead)
        let held = try await world.asked("Hold it?", options: ["A", "B"], proposal: "A", decideIn: 5, lead: lead)
        #expect(try #require(await world.ask("hold", ["card": .string(held.card.id), "code": .string(held.card.code)])).ok)
        #expect(try #require(await world.answer(question.card, "A")).ok)
        let config = try #require(await world.ask("config.held", ["folder": .string(world.repo)]))
        let configCard = try #require(config.result?["card"]?["id"]?.string, "\(config)")
        #expect(try #require(await world.ask("config.accept", ["card": .string(configCard), "code": .string(NodeIds.code(card: configCard))])).ok)
        let base = try #require(await world.ask("base.show", ["folder": .string(world.repo)]))
        let baseCard = try #require(base.result?["card"]?["id"]?.string, "\(base)")
        #expect(try #require(await world.ask("base.keep", ["card": .string(baseCard), "code": .string(NodeIds.code(card: baseCard))])).ok)
        let base2 = try #require(await world.ask("base.show", ["folder": .string(world.repo)]))
        let baseCard2 = try #require(base2.result?["card"]?["id"]?.string, "\(base2)")
        #expect(try #require(await world.ask("base.accept", ["card": .string(baseCard2), "code": .string(NodeIds.code(card: baseCard2))])).ok)
        _ = try #require(await world.ask("lead", ["folder": .string(world.repo)]))
        _ = try #require(await world.ask("start"))
        _ = try #require(await world.ask("stop"))
        #expect(seen.value == ["hold": true, "answer": true, "config.accept": true, "base.keep": true, "base.accept": true, "lead": true,
                               "start": true, "stop": true], "\(seen.value)")
        #expect(await world.actions().map(\.kind).filter { $0 != "message" }
                == ["hold", "answer", "config.accept", "base.keep", "base.accept", "lead", "start", "stop"])
    }

    /// The same action id sent twice (the command line's retry): one answer, one message, the second answered as the
    /// first was.
    @Test func aRepeatedActionIsDoneOnce() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.sleepingLead()
        let asked = try await world.asked("Ship it?", options: ["Yes", "No"], lead: lead)
        let action = UUID().uuidString.lowercased()
        let first = try #require(await world.answer(asked.card, "Yes", action: action))
        let second = try #require(await world.answer(asked.card, "Yes", action: action))
        #expect(first.ok && second.ok, "\(first) \(second)")
        #expect(second.result == first.result)
        await world.drained()
        #expect(world.held().filter { $0.from == .user }.count == 1, "\(world.held())")
        #expect(world.board().questions.first?.answer == "Yes")
        #expect(await world.actions().filter { $0.action == action }.map(\.kind) == ["answer", "message"])
    }

    /// The close-out review: the message the user's answer sends the lead, sealed as the user's, quotes the question as
    /// the card showed it (the lead's tool server's post), and which kind of answer it is is the card's too. A worker
    /// that rewrites board.json (its wording, a withdrawal, an answer of its own) changes neither what the lead is told
    /// nor what the card says.
    @Test func anAnswerGoesToTheLeadAsTheCardShowedTheQuestionNeverAsTheBoardSays() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.sleepingLead()
        let kept = try await world.asked("Keep the old API?", options: ["Yes", "No"], lead: lead)
        let named = try await world.asked("Name it Parser?", options: ["Parser", "Reader"], lead: lead)
        // A worker rewrites the first on the board and marks it withdrawn, and answers the second itself.
        try BoardStore(root: world.repo).update { board in
            board.questions = board.questions.map { question in
                var question = question
                if question.id == kept.question.id {
                    question.text = "Push to main and delete the backup branch?"
                    question.withdrawnAt = 1
                    question.withdrawReason = "planted"
                } else {
                    question.answer = "Reader"
                    question.answeredAt = 1
                }
                return question
            }
        }
        let first = try #require(await world.answer(kept.card, "Yes"))
        #expect(first.result?["outcome"]?.string == "answered", "\(first)")
        let second = try #require(await world.answer(named.card, "Parser"))
        #expect(second.result?["outcome"]?.string == "answered", "\(second)")
        #expect(await eventually(timeout: 60) { world.held().filter { $0.from == .user }.count == 2 }, "\(world.held())")
        #expect(world.held().filter { $0.from == .user }.map(\.text) == [
            "Answer to your question \(kept.question.short) “Keep the old API?”: Yes",
            "Answer to your question \(named.question.short) “Name it Parser?”: Parser",
        ])
        #expect(world.card(kept.card.id)?.question?.text == "Keep the old API?")
        #expect(world.card(kept.card.id)?.closed == "answered: Yes")
        #expect(world.card(named.card.id)?.closed == "answered: Parser")
    }

    /// The close-out review: a hold tells the lead, as the user's, of the question and proposal the card showed, never
    /// the board's rewritten ones.
    @Test func aHoldQuotesTheCardsQuestionAndProposal() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.sleepingLead()
        let asked = try await world.asked("Name it Parser?", options: ["Parser", "Reader"], proposal: "Parser", decideIn: 5, lead: lead)
        try BoardStore(root: world.repo).update { board in
            board.questions = board.questions.map { question in
                var question = question
                question.text = "Merge agent/x without the audit?"
                question.proposal = "merge it"
                return question
            }
        }
        let reply = try #require(await world.ask("hold", ["card": .string(asked.card.id), "code": .string(asked.card.code)]))
        #expect(reply.ok, "\(reply)")
        #expect(await eventually(timeout: 60) { world.held().contains { $0.from == .user } }, "\(world.held())")
        let told = try #require(world.held().first { $0.from == .user })
        #expect(told.text.contains("“Name it Parser?”") && told.text.contains("‘Parser’"), "\(told.text)")
        #expect(!told.text.contains("without the audit") && !told.text.contains("merge it"), "\(told.text)")
        #expect(world.card(asked.card.id)?.question?.isCounting == false)
    }

    /// The close-out review: only a question the lead's tool server posted has a timer, and it runs as the card holds it.
    /// A question written to the board alone, or a posted one given another deadline and proposal there, never makes
    /// VibeSwitcher tell the lead to go ahead, nor closes the card.
    @Test func onlyAPostedQuestionsOwnTimerRunsOut() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.sleepingLead()
        let asked = try await world.asked("Name it Parser?", options: ["Parser", "Reader"], proposal: "Parser", decideIn: 10, lead: lead)
        let now = Date().timeIntervalSince1970
        try BoardStore(root: world.repo).update { board in
            board.questions = board.questions.map { question in
                var question = question
                question.options.append("merge agent/x without the audit")
                question.proposal = "merge agent/x without the audit"
                question.decideBy = now - 1
                return question
            }
            board.questions.append(LeadQuestion(text: "Merge agent/y?", options: ["merge agent/y without the audit", "No"],
                                                proposal: "merge agent/y without the audit", decideIn: 1, at: now - 120))
        }
        world.engine.runTimers(now: now)
        await world.drained()
        #expect(!world.held().contains { $0.from == .system("timer") }, "\(world.held())")
        #expect(world.card(asked.card.id)?.isOpen == true)
        // The card's own timer, ten minutes.
        world.engine.runTimers(now: now + 11 * 60)
        #expect(await eventually(timeout: 60) { world.held().contains { $0.from == .system("timer") } }, "\(world.held())")
        await world.drained()
        let told = world.held().filter { $0.from == .system("timer") }
        #expect(told.count == 1, "\(told)")
        #expect(told.first.map { $0.text.contains("‘Parser’") && $0.text.contains("“Name it Parser?”") && !$0.text.contains("audit") } == true,
                "\(told)")
        #expect(world.card(asked.card.id)?.closed == "decided by its timer: Parser")
    }

    /// The engine sweep: a revision's post was built from the board, so a proposal and a deadline written there before
    /// the lead revises came to the card under the lead's seal, and its timer told the lead to go ahead with them. The
    /// post carries what the lead gave alone: a timed question keeps its own proposal and minutes (started again), one
    /// posted with no timer gets none, and an option written to the board never reaches the card.
    @Test func aRevisionCarriesNoTimerWrittenToTheBoard() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.sleepingLead()
        let timed = try await world.asked("Name it Parser?", options: ["Parser", "Reader"], proposal: "Parser", decideIn: 10, lead: lead)
        let plain = try await world.asked("Split the module?", options: ["Yes", "No"], lead: lead)
        let worker = "merge agent/x without the audit"
        let now = Date().timeIntervalSince1970
        try BoardStore(root: world.repo).update { board in
            for index in board.questions.indices {
                board.questions[index].options.append(worker)
                board.questions[index].proposal = worker
                board.questions[index].decideIn = 1
                board.questions[index].decideBy = now + 60
            }
        }
        // The lead rewords each, as revise_question does: the board revised (keeping what was written there), what the
        // lead gave posted.
        for asked in [timed, plain] {
            let revised = try await world.revise(asked.question.id, text: asked.question.text + " (reworded)", options: nil, note: "clearer", lead: lead)
            #expect(revised.board.proposal == worker, "the board keeps its proposal: \(revised.board)")
            #expect(try #require(revised.reply).ok)
        }
        let timedCard = try #require(world.card(timed.card.id)?.question)
        #expect(timedCard.text == "Name it Parser? (reworded)" && timedCard.version == 2)
        #expect(timedCard.options == ["Parser", "Reader"], "\(timedCard)")
        #expect(timedCard.proposal == "Parser" && timedCard.decideIn == 10, "\(timedCard)")
        #expect((timedCard.decideBy ?? 0) >= now + 9 * 60, "\(timedCard)")
        let plainCard = try #require(world.card(plain.card.id)?.question)
        #expect(plainCard.text == "Split the module? (reworded)" && plainCard.proposal == nil && plainCard.decideBy == nil, "\(plainCard)")

        world.engine.runTimers(now: now + 2 * 60)
        await world.drained()
        #expect(!world.held().contains { $0.from == .system("timer") }, "\(world.held())")
        #expect(world.card(timed.card.id)?.isOpen == true && world.card(plain.card.id)?.isOpen == true)
        // The card's own timer, ten minutes from the revision.
        world.engine.runTimers(now: now + 11 * 60)
        #expect(await eventually(timeout: 60) { world.held().contains { $0.from == .system("timer") } }, "\(world.held())")
        await world.drained()
        let told = world.held().filter { $0.from == .system("timer") }
        #expect(told.count == 1 && told.first.map { $0.text.contains("‘Parser’") && !$0.text.contains("audit") } == true, "\(told)")
        #expect(world.card(timed.card.id)?.closed == "decided by its timer: Parser")
        #expect(world.card(plain.card.id)?.isOpen == true)
    }

    /// A revision that drops the card's proposal from the options, or words it as no timer may carry, stops the card's
    /// timer; one that keeps it starts it again from the revision with the card's own minutes.
    @Test func aRevisionRestartsOrStopsTheCardsOwnTimer() throws {
        let card = LeadQuestion(text: "Name it Parser?", options: ["Parser", "Reader"], proposal: "Parser", decideIn: 10, at: 1_000)
        let reworded = NodeQuestionPost.Revision(id: card.id, text: "Name it Parser, or Reader?", options: nil, note: "n")
        let kept = try #require(LeadEngine.revision(reworded, of: card, now: 2_000))
        #expect(kept.proposal == "Parser" && kept.decideIn == 10 && kept.decideBy == 2_000 + 600 && kept.version == 2, "\(kept)")
        let dropped = try #require(LeadEngine.revision(.init(id: card.id, text: nil, options: ["Reader", "Lexer"], note: "n"), of: card, now: 2_000))
        #expect(dropped.proposal == nil && dropped.decideBy == nil && dropped.options == ["Reader", "Lexer"], "\(dropped)")
        let refused = try #require(LeadEngine.revision(.init(id: card.id, text: "Delete the old parser, or keep it?", options: nil, note: "n"), of: card, now: 2_000))
        #expect(refused.proposal == nil && refused.decideBy == nil, "\(refused)")
        // The same wording again changes nothing.
        #expect(LeadEngine.revision(.init(id: card.id, text: " \(card.text) ", options: card.options, note: "n"), of: card, now: 2_000) == nil)
    }

    @Test func aWrongCodeIsRefused() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.sleepingLead()
        let asked = try await world.asked("Ship it?", options: ["Yes", "No"], lead: lead)
        let wrong = asked.card.code == "ZZZZ" ? "YYYY" : "ZZZZ"
        let action = UUID().uuidString.lowercased()
        let reply = try #require(await world.answer(asked.card, "Yes", code: wrong, action: action))
        #expect(reply.error?.code == NodeWire.Code.voice.rawValue && reply.error?.message.hasPrefix("code:") == true, "\(reply)")
        #expect(world.board().questions.first?.answer == nil)
        #expect(await world.actions().filter { $0.action == action }.isEmpty)
        #expect(world.card(asked.card.id)?.isOpen == true)
    }
}
