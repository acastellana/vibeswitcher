import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The lead's questions as the server's cards (the engine plan's E6, EN-D10; the security architecture document's S3):
/// made only from the lead's tool server's post, sealed by the host as that project's lead's, from the session the vault
/// binds to its lead role and not from branch code; never read back from `board.json`. `questions` lists them, closed
/// ones too with `all`, and every untrusted field reaches the terminal inert.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct QuestionCardTests {
    private let scratch = Scratch()

    /// The app's `LeadChatQuestionTests.closedQuestionsJoinTheConversationWhereTheyClosed`, as the cards list: with
    /// `all`, a withdrawn question is listed where it closed with its reason, an answered one with its answer, and a late
    /// answer's notice is shown on it; without, only the open one.
    @Test func closedQuestionsAreListedWithWhatBecameOfALateAnswer() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.sleepingLead()
        let withdrawn = try await world.asked("Keep the review badges?", lead: lead)
        let answered = try await world.asked("Ship it?", lead: lead)
        let open = try await world.asked("Blue or red?", options: ["Blue", "Red"], lead: lead)
        let gone = try BoardStore(root: world.repo).update { try $0.withdraw(withdrawn.question.id, reason: "User asked to re-ask it.") }
        #expect(try #require(await world.post(gone, op: .withdraw, lead: lead)).ok)
        #expect(try #require(await world.answer(answered.card, "Yes")).ok)

        let listed = try #require(await world.ask("questions"))
        #expect(listed.result?["cards"]?.array?.compactMap { $0["id"]?.string } == [open.card.id], "\(listed)")
        let all = try #require(await world.ask("questions", ["all": .bool(true)]))
        let cards = all.result?["cards"]?.array ?? []
        #expect(cards.compactMap { $0["id"]?.string } == [withdrawn.card.id, answered.card.id, open.card.id])
        let text = cards.flatMap(CardText.lines).joined(separator: "\n")
        #expect(text.contains("closed: withdrawn: User asked to re-ask it."), "\(text)")
        #expect(text.contains("closed: answered: Yes"), "\(text)")

        // A late answer's notice shows on it.
        let late = try #require(await world.answer(withdrawn.card, "Keep them"))
        #expect(late.result?["outcome"]?.string == "withdrawn", "\(late)")
        let after = try #require(await world.ask("questions", ["all": .bool(true)]))
        let shown = (after.result?["cards"]?.array ?? []).first { $0["id"]?.string == withdrawn.card.id }
        #expect(shown?["notice"]?.string?.hasPrefix("Withdrawn before your answer") == true, "\(String(describing: shown))")
    }

    /// S3: a question written to the board by anyone (no post) is never a card.
    @Test func aQuestionWrittenToTheBoardIsNotShown() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        _ = try await world.sleepingLead()
        _ = try world.boardAsks("Approve the merge of everything?", options: ["Yes", "No"], priority: .blocking)
        await world.drained()
        let all = try #require(await world.ask("questions", ["all": .bool(true)]))
        #expect(all.result?["cards"]?.array?.isEmpty == true, "\(all)")
        let status = try #require(await world.ask("status"))
        #expect(status.result?["cards"]?["questions"]?.int == 0, "\(status)")
    }

    @Test func aPostFromAWorkersSessionIsRefused() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.sleepingLead()
        let worker = try await world.host.spawn("exec /bin/sleep 600", cwd: world.repo, label: "Worker · parser")
        let question = try world.boardAsks("Merge my branch?", options: ["Yes"])
        // Even with the lead's own seal (a copy of a post), from a worker's session.
        let reply = try #require(await world.post(question, lead: lead, facts: CardWorld.toolServer(of: worker)))
        #expect(reply.error?.code == NodeWire.Code.voice.rawValue, "\(reply)")
        #expect(reply.error?.message.contains("binds to") == true, "\(reply)")
        #expect(world.card(question: question) == nil)
        // A worker can't have the host seal it as the lead's at all.
        await #expect(throws: (any Error).self) { try await world.post(question, lead: worker) }
    }

    /// A merge's test command runs under the lead's tool server (a `BranchCode` runner): what it posts is refused.
    @Test func aPostFromBranchCodeUnderTheLeadIsRefused() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.sleepingLead()
        let question = try world.boardAsks("Approve the release?", options: ["Yes"])
        let reply = try #require(await world.post(question, lead: lead, facts: CardWorld.toolServer(of: lead, runner: true)))
        #expect(reply.error?.code == NodeWire.Code.voice.rawValue && reply.error?.message.contains("branch code") == true, "\(reply)")
        var unreadable = CardWorld.toolServer(of: lead)
        unreadable.underRunner = nil
        let again = try #require(await world.post(question, lead: lead, facts: unreadable))
        #expect(again.error?.code == NodeWire.Code.voice.rawValue, "\(again)")
        #expect(world.card(question: question) == nil)
        // The same post from the lead's tool server itself is taken.
        #expect(try #require(await world.post(question, lead: lead)).ok)
    }

    @Test func aPostFromAnotherProjectsLeadIsRefused() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.sleepingLead()
        let otherRepo = world.host.folder.appendingPathComponent("other", isDirectory: true)
        try await scratchRepository(otherRepo)
        let other = try await world.sleepingLead(root: otherRepo.resolvingSymlinksInPath().path)
        let question = try world.boardAsks("Delete the history?", options: ["Yes"])
        // Its own project's name, sealed by the host, posted for this one: the name isn't this project's lead's.
        let named = try #require(await world.post(question, lead: other, name: NodeQuestionPost.leadName(root: otherRepo.resolvingSymlinksInPath().path)))
        #expect(named.error?.code == NodeWire.Code.voice.rawValue, "\(named)")
        // This project's name it can't have sealed.
        await #expect(throws: (any Error).self) { try await world.post(question, lead: other) }
        // This project's lead's seal, from the other lead's session: not the session the vault binds here.
        let copied = try #require(await world.post(question, lead: lead, facts: CardWorld.toolServer(of: other)))
        #expect(copied.error?.code == NodeWire.Code.voice.rawValue, "\(copied)")
        #expect(world.card(question: question) == nil)
    }

    @Test func aRevisedQuestionShowsItsNewWordingAndTheAnswerSaysWhichWasAnswered() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.sleepingLead()
        let asked = try await world.asked("Use SQLite?", options: ["Yes", "No"], lead: lead)
        #expect(asked.card.question?.version == 1)
        // The user saw version 1; the lead revises before the answer comes.
        let revised = try BoardStore(root: world.repo).update { try $0.revise(asked.question.id, text: "Use SQLite or Postgres?", options: ["SQLite", "Postgres"], note: "Postgres is on the table now") }
        #expect(try #require(await world.post(revised, op: .revise, lead: lead)).ok)
        let card = try #require(world.card(asked.card.id))
        #expect(card.question?.text == "Use SQLite or Postgres?" && card.question?.version == 2)
        let shown = CardText.lines(card.value).joined(separator: "\n")
        #expect(shown.contains("Use SQLite or Postgres?") && shown.contains("Postgres is on the table now") && shown.contains("version 2"), "\(shown)")

        let reply = try #require(await world.answer(card, "Yes", version: 1))
        #expect(reply.result?["outcome"]?.string == "answered", "\(reply)")
        #expect(world.board().questions.first?.answeredVersion == 1)
        // What the lead is told says which wording was answered (held: no lead runs to take it).
        #expect(await eventually(timeout: 60) { world.held().contains { $0.from == .user } })
        let told = try #require(world.held().last)
        #expect(told.from == .user)
        #expect(told.text.contains("version 1 of 2") && told.text.contains("the user saw “Use SQLite?”"), "\(told.text)")
        // A revision of a question never posted makes no card.
        let stray = try world.boardAsks("Stray?")
        let strayRevised = try BoardStore(root: world.repo).update { try $0.revise(stray.id, text: "Stray, really?", options: nil, note: "n") }
        #expect(try #require(await world.post(strayRevised, op: .revise, lead: lead)).error?.code == NodeWire.Code.gone.rawValue)
    }

    /// A question, a commit's subject and a file name holding escape sequences and bidirectional characters reach
    /// `questions`' output stripped (`ConfigSeal.inert`).
    @Test func untrustedTextIsPrintedInert() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let escape = "\u{1B}[2J\u{1B}]0;owned\u{07}"
        let bidi = "\u{202E}txt.exe"
        let commit = try await taskBranch(world.repo, task: "change", file: "evil\(bidi)", subject: "Fix \(escape)typo\(bidi)")
        let lead = try await world.sleepingLead()
        let asked = try await world.asked("Merge? \(escape)\(bidi)", options: [LeadWorkflow.approval(of: commit), "No \(escape)"], lead: lead)
        #expect(await eventually(timeout: 60) { world.card(asked.card.id)?.approval?.files.isEmpty == false })
        let all = try #require(await world.ask("questions", ["all": .bool(true)]))
        let text = (all.result?["cards"]?.array ?? []).flatMap(CardText.lines).joined(separator: "\n")
        #expect(text.contains("Merge?") && text.contains("typo") && text.contains("evil"), "\(text)")
        let forbidden = text.unicodeScalars.filter { $0.value == 0x1B || $0.value == 0x07 || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }
        #expect(forbidden.isEmpty, "\(forbidden.map { String($0.value, radix: 16) })")
    }
}
