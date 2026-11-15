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
