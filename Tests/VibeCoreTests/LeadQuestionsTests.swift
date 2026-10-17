import Foundation
import Testing
@testable import VibeCore

/// The lead's questions as a queue: asked, revised (keeping their history), withdrawn, answered against the version
/// the user saw, and ordered by priority then age.
struct LeadQuestionsTests: LeadTeamFixture {
    let vault = Self.newVault()

    func repo() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("questions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    // MARK: The state machine

    @Test func aRevisionKeepsTheIdAndTheEarlierWording() throws {
        var board = LeadBoard()
        let asked = board.ask("Base branch: main or develop?", options: ["main", "develop"], priority: .blocking, whyNow: "Workers start from it", at: 100)
        let revised = try board.revise(asked.short, text: "Base branch: main or release/2.0?", options: ["main", "release/2.0"],
                                       note: "develop was retired yesterday", at: 200)
        #expect(revised.id == asked.id)
        #expect(revised.version == 2)
        #expect(revised.text == "Base branch: main or release/2.0?")
        #expect(revised.lastRevision?.note == "develop was retired yesterday")
        #expect(revised.lastRevision?.at == 200)
        #expect(revised.wording(1).text == "Base branch: main or develop?")
        #expect(revised.wording(1).options == ["main", "develop"])
        #expect(revised.wording(2).text == revised.text)
        #expect(board.questions.count == 1)
        // The same wording again is no revision.
        #expect(throws: BoardError.self) { try board.revise(asked.id, text: revised.text, options: nil, note: "again") }
    }

    @Test func anAnswerToAnOlderVersionSaysWhichOne() throws {
        var board = LeadBoard()
        let asked = board.ask("Postgres or SQLite?", options: [], priority: nil, whyNow: nil, at: 100)
        // The user's card showed version 1; the lead revised it before the answer landed.
        try board.revise(asked.id, text: "Postgres, SQLite or DuckDB?", options: nil, note: "DuckDB came up in the spike", at: 200)
        let outcome = board.answer(asked.id, with: "SQLite", saw: 1, at: 300)
        guard case .answered(let question, let saw) = outcome else { Issue.record("\(outcome)"); return }
        #expect(saw == 1)
        #expect(question.state == .answered)
        #expect(question.answeredVersion == 1)
        let message = try #require(outcome.message(given: "SQLite"))
        #expect(message.contains("version 1 of 2"))
        #expect(message.contains("Postgres or SQLite?"))
        #expect(message.contains("Postgres, SQLite or DuckDB?"))
        #expect(message.contains("SQLite"))

        // Answering the current version reads as a plain answer.
        var other = LeadBoard()
        let plain = other.ask("Ship it?", options: ["yes", "no"], priority: nil, whyNow: nil)
        let current = other.answer(plain.id, with: "yes", saw: 1)
        #expect(current.message(given: "yes") == "Answer to your question \(plain.short) “Ship it?”: yes")
        // Twice is once.
        guard case .alreadyAnswered = other.answer(plain.id, with: "no", saw: 1) else { Issue.record("answered twice"); return }
        #expect(other.questions[0].answer == "yes")
    }

    @Test func aWithdrawnQuestionTakesALateAnswerAsANote() throws {
        var board = LeadBoard()
        let asked = board.ask("Which test command?", options: [], priority: .blocking, whyNow: nil)
        #expect(board.blockingQuestions == 1)
        try board.withdraw(asked.short, reason: "Settled: configure found swift test")
        #expect(board.openQuestions.isEmpty)
        #expect(board.blockingQuestions == 0)
        #expect(board.questions[0].state == .withdrawn)
        // Closed now: no more revising or withdrawing.
        #expect(throws: BoardError.self) { try board.revise(asked.id, text: "x", options: nil, note: "n") }
        #expect(throws: BoardError.self) { try board.withdraw(asked.id, reason: "again") }

        let late = board.answer(asked.id, with: "swift test", saw: 1)
        guard case .withdrawn(let question) = late else { Issue.record("\(late)"); return }
        #expect(question.state == .withdrawn)
        #expect(question.answer == "swift test")
        #expect(question.withdrawReason == "Settled: configure found swift test")
        let message = try #require(late.message(given: "swift test"))
        #expect(message.contains("withdrawn") && message.contains("Settled: configure found swift test"))
        // Still withdrawn: never back in the queue.
        #expect(board.openQuestions.isEmpty)
    }

    @Test func openQuestionsArePriorityThenAge() {
        var board = LeadBoard()
        let later = board.ask("Colour of the badge?", options: [], priority: .whenever, whyNow: nil, at: 10)
        let older = board.ask("Rename the app?", options: [], priority: nil, whyNow: nil, at: 20)
        let newer = board.ask("Drop macOS 13?", options: [], priority: .important, whyNow: nil, at: 30)
        let urgent = board.ask("Force-push main?", options: [], priority: .blocking, whyNow: nil, at: 40)
        let answered = board.ask("Answered", options: [], priority: .blocking, whyNow: nil, at: 5)
        _ = board.answer(answered.id, with: "ok", saw: 1)
        #expect(board.openQuestions.map(\.id) == [urgent.id, older.id, newer.id, later.id])
        #expect(board.blockingQuestions == 1)
    }

    @Test func idsMatchByAUniquePrefix() throws {
        var board = LeadBoard()
        board.questions = [LeadQuestion(id: "2DB85777-AAAA", text: "a", options: []), LeadQuestion(id: "2DB8FFFF-BBBB", text: "b", options: [])]
        #expect(try board.questionIndex("2db85777") == 0)
        #expect(throws: BoardError.self) { try board.questionIndex("2DB8") }
        #expect(throws: BoardError.self) { try board.questionIndex("nope") }
    }

    @Test func oldBoardsLoadWithImportantQuestionsAndNoHistory() throws {
        let json = #"{"tasks":[],"questions":[{"id":"2DB85777","text":"Base branch?","options":["main"],"askedAt":5}],"updates":[]}"#
        let board = try JSONDecoder().decode(LeadBoard.self, from: Data(json.utf8))
        let question = try #require(board.questions.first)
        #expect(question.rank == .important)
        #expect(question.priority == nil)
        #expect(question.revisions == nil)
        #expect(question.version == 1)
        #expect(question.isOpen)
        #expect(board.openQuestions.count == 1)
        // And what's written reads back.
        var changed = board
        try changed.revise("2DB85777", text: "Base branch, now?", options: nil, note: "n")
        let again = try JSONDecoder().decode(LeadBoard.self, from: JSONEncoder().encode(changed))
        #expect(again == changed)
    }

    // MARK: The tools

    @Test func onlyTheLeadGetsTheQuestionTools() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let questionTools: Set<String> = ["ask_user", "revise_question", "withdraw_question", "questions"]
        let lead = try issued(.lead, task: nil, root: root, runtime)
        #expect(Set(lead.tools.map(\.name)).isSuperset(of: questionTools))
        let ask = try #require(lead.tools.first { $0.name == "ask_user" })
        #expect(ask.properties["priority"]?.options == ["blocking", "important", "whenever"])
        #expect(ask.properties["why_now"] != nil)

        try BoardStore(root: root).update { board in board.ask("Q?", options: [], priority: nil, whyNow: nil) }
        let id = BoardStore(root: root).load().questions[0].id
        for role in [LeadLaunch.Role.worker, .verifier] {
            let seat = try issued(role, task: "t", root: root, runtime, session: "own-\(role.rawValue)")
            #expect(Set(seat.tools.map(\.name)).isDisjoint(with: questionTools))
            for name in questionTools {
                let refused = seat.call(name, ["id": id, "reason": "r", "note": "n", "text": "t", "question": "q"])
                #expect(refused.isError, "\(role) \(name)")
            }
        }
        #expect(BoardStore(root: root).load().questions[0].isOpen)
        #expect(BoardStore(root: root).load().questions.count == 1)
    }

    @Test func theLeadAsksRevisesAndWithdraws() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        let asked = lead.call("ask_user", ["question": "Base branch and test_command?", "priority": "blocking", "why_now": "Workers can't start without them"])
        #expect(!asked.isError, "\(asked.text)")
        #expect(lead.call("ask_user", ["question": "x", "priority": "urgent"]).isError)
        let id = try #require(BoardStore(root: root).load().questions.first?.id)
        #expect(asked.text.contains(String(id.prefix(8))))
        #expect(BoardStore(root: root).load().questions[0].whyNow == "Workers can't start without them")

        #expect(lead.call("revise_question", ["id": String(id.prefix(8)), "text": "Base branch?"]).isError)  // no note
        #expect(lead.call("revise_question", ["id": String(id.prefix(8)), "note": "n"]).isError)  // nothing to change
        let revised = lead.call("revise_question", ["id": String(id.prefix(8)), "text": "Which base branch?", "note": "test_command is set now"])
        #expect(!revised.isError, "\(revised.text)")
        #expect(BoardStore(root: root).load().questions[0].version == 2)

        let listed = lead.call("questions", [:]).text
        #expect(listed.contains("Which base branch?") && listed.contains("Base branch and test_command?") && listed.contains("test_command is set now"))

        #expect(lead.call("withdraw_question", ["id": id]).isError)  // no reason
        let withdrawn = lead.call("withdraw_question", ["id": id, "reason": "Settled with configure"])
        #expect(!withdrawn.isError, "\(withdrawn.text)")
        #expect(lead.call("withdraw_question", ["id": id, "reason": "again"]).isError)
        #expect(!lead.call("status", [:]).text.contains("Which base branch?"))
        let after = lead.call("questions", [:]).text
        #expect(after.contains("Withdrawn:") && after.contains("Settled with configure"))
        #expect(lead.call("revise_question", ["id": "nope", "text": "x", "note": "n"]).isError)
    }

    @Test func statusShowsAgeAndPriorityAndFlagsOldQuestions() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        let now = Date().timeIntervalSince1970
        try BoardStore(root: root).update { board in
            board.ask("Fresh one?", options: [], priority: .whenever, whyNow: nil, at: now - 5 * 60)
            board.ask("Old one?", options: [], priority: .blocking, whyNow: nil, at: now - 2 * 3_600)
            let revised = board.ask("Old but revised?", options: [], priority: nil, whyNow: nil, at: now - 3 * 3_600)
            try board.revise(revised.id, text: "Old but revised lately?", options: nil, note: "n", at: now - 10 * 60)
        }
        let status = lead.call("status", [:]).text
        let lines = status.components(separatedBy: "\n")
        let old = try #require(lines.first { $0.contains("Old one?") })
        let fresh = try #require(lines.first { $0.contains("Fresh one?") })
        let revised = try #require(lines.first { $0.contains("Old but revised lately?") })
        #expect(old.contains("blocking") && old.contains("2 h") && old.contains("still relevant?"))
        #expect(fresh.contains("whenever") && fresh.contains("5 min") && !fresh.contains("still relevant?"))
        // Reworded ten minutes ago: re-checked, not stale.
        #expect(revised.contains("important") && revised.contains("revised 10 min ago") && !revised.contains("still relevant?"))
        // Most important first.
        #expect(try #require(lines.firstIndex(of: old)) < (try #require(lines.firstIndex(of: revised))))
        #expect(try #require(lines.firstIndex(of: revised)) < (try #require(lines.firstIndex(of: fresh))))
        #expect(status.contains("3 questions"))
    }
}
