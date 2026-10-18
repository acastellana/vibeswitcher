import Foundation
import Testing
@testable import VibeCore

/// Decisions with a timer: the lead proposes an answer, the user can pick another or hold it, and when the timer runs
/// out unanswered the lead is told, once, to go ahead, and it's recorded as the lead's decision.
struct LeadDecisionTimerTests: LeadTeamFixture {
    let vault = Self.newVault()

    func repo() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("timer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    func decisions(_ root: String) -> String {
        (try? String(contentsOfFile: root + "/.vibeswitcher/decisions.md", encoding: .utf8)) ?? ""
    }

    func occurrences(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }

    /// A question asked at `at` proposing SQLite with a 10-minute timer.
    @discardableResult
    func askTimed(_ store: BoardStore, at: Double, decideIn: Int? = nil) throws -> LeadQuestion {
        try store.update { board in
            board.ask("Postgres or SQLite for the local cache?", options: ["Postgres", "SQLite"], priority: nil,
                      whyNow: "The cache task starts next", proposal: "SQLite", decideIn: decideIn, at: at)
        }
    }

    // MARK: Expiry

    @Test func theDeadlineIsAnAbsoluteTimeWithTenMinutesByDefault() throws {
        var board = LeadBoard()
        let asked = board.ask("Q?", options: ["a", "b"], priority: nil, whyNow: nil, proposal: "a", at: 1_000)
        #expect(asked.decideIn == 10)
        #expect(asked.decideBy == 1_600.0)
        #expect(asked.isCounting)
        let short = board.ask("Q2?", options: ["a", "b"], priority: nil, whyNow: nil, proposal: "b", decideIn: 3, at: 1_000)
        #expect(short.decideBy == 1_180.0)
        #expect(short.decideInText == "3 min")
        // No proposal, no timer.
        let plain = board.ask("Q3?", options: ["a"], priority: nil, whyNow: nil, at: 1_000)
        #expect(plain.decideBy == nil && !plain.isCounting)
    }

    @Test func expiryDeliversOnceAndRecordsTheLeadsDecision() throws {
        let root = try repo()
        let store = BoardStore(root: root)
        let asked = try askTimed(store, at: 1_000)

        #expect(try store.runTimers(now: 1_000 + 599).isEmpty)
        #expect(store.load().questions[0].isOpen)

        let fired = try store.runTimers(now: 1_000 + 600)
        #expect(fired.count == 1)
        let message = try #require(fired.first?.message)
        #expect(message.hasPrefix("No answer in 10 min: going with your proposal ‘SQLite’"))
        #expect(message.contains(asked.short))

        let question = store.load().questions[0]
        #expect(question.state == .autoDecided)
        #expect(question.autoDecidedAt == 1_600)
        #expect(!question.isOpen && !question.isCounting)
        #expect(store.load().openQuestions.isEmpty)
        // Recorded as the lead's decision, the way record_decision writes it, and in its reports.
        let written = decisions(root)
        #expect(written.contains("Postgres or SQLite for the local cache? → SQLite"))
        #expect(written.contains("10 min timer"))
        // So the Team tab's decisions feed, which reads `decisions()`, shows it.
        #expect(store.decisions().map(\.text) == ["Postgres or SQLite for the local cache? → SQLite"])
        #expect(store.decisions().first?.why.contains("10 min timer") == true)
        #expect(store.load().reports?.filter { $0.about == "timer" }.map(\.text) == [message])

        // Again: nothing more, however often the board is watched.
        for later in [1_601.0, 2_000, 100_000] { #expect(try store.runTimers(now: later).isEmpty) }
        #expect(occurrences("→ SQLite", in: decisions(root)) == 1)
        #expect(store.load().reports?.count == 1)
    }

    @Test func expiryDeliversOnceAcrossARelaunch() throws {
        let root = try repo()
        // Asked while the app ran; then it quit before the deadline.
        try askTimed(BoardStore(root: root), at: 1_000)
        // The deadline survives on disk as an absolute time.
        let reread = try BoardStore(root: root).read()
        #expect(reread.questions[0].decideBy == 1_600)
        #expect(reread.questions[0].proposal == "SQLite")

        // Relaunched after the deadline: a new store (as a new app would make) runs it out, once.
        let relaunched = BoardStore(root: root)
        let fired = try relaunched.runTimers(now: 5_000)
        #expect(fired.map(\.message.isEmpty) == [false])
        #expect(fired[0].message.hasPrefix("No answer in 10 min: going with your proposal ‘SQLite’"))
        // And relaunched again: already decided, nothing to tell.
        #expect(try BoardStore(root: root).runTimers(now: 6_000).isEmpty)
        #expect(occurrences("→ SQLite", in: decisions(root)) == 1)
        #expect(BoardStore(root: root).load().questions[0].state == .autoDecided)
    }

    @Test func twoWatchersRacingStillDeliverOnce() throws {
        let root = try repo()
        try askTimed(BoardStore(root: root), at: 1_000)
        let counts = Counter()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let fired = (try? BoardStore(root: root).runTimers(now: 2_000)) ?? []
            counts.add(fired.count)
        }
        #expect(counts.total == 1)
        #expect(occurrences("→ SQLite", in: decisions(root)) == 1)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var total = 0
        func add(_ n: Int) { lock.lock(); total += n; lock.unlock() }
    }

    // MARK: Hold, answers

    @Test func holdStopsTheTimerAndLeavesAnOrdinaryOpenQuestion() throws {
        let root = try repo()
        let store = BoardStore(root: root)
        let asked = try askTimed(store, at: 1_000)
        let held = try store.update { board in try board.hold(asked.id, at: 1_100) }
        #expect(held.heldAt == 1_100)
        #expect(held.isOpen && !held.isCounting)
        #expect(try store.runTimers(now: 10_000).isEmpty)
        #expect(store.load().questions[0].state == .open)
        #expect(decisions(root).isEmpty)
        // Held is held: not twice, and not a question without a timer.
        #expect(throws: BoardError.self) { try store.update { board in try board.hold(asked.id) } }
        let plain = try store.update { board in board.ask("Plain?", options: [], priority: nil, whyNow: nil) }
        #expect(throws: BoardError.self) { try store.update { board in try board.hold(plain.id) } }
        // It's answered as any other.
        var board = store.load()
        let outcome = board.answer(asked.id, with: "Postgres", saw: 1)
        guard case .answered = outcome else { Issue.record("\(outcome)"); return }
        #expect(outcome.message(given: "Postgres")?.contains("Postgres") == true)
    }

    @Test func anAnswerBeforeTheDeadlineWins() throws {
        let root = try repo()
        let store = BoardStore(root: root)
        let asked = try askTimed(store, at: 1_000)
        let outcome = try store.update { board in board.answer(asked.id, with: "Postgres", saw: 1, at: 1_300) }
        guard case .answered(let question, _) = outcome else { Issue.record("\(outcome)"); return }
        #expect(question.state == .answered && !question.isCounting)
        #expect(outcome.message(given: "Postgres") == "Answer to your question \(asked.short) “\(asked.text)”: Postgres")
        #expect(try store.runTimers(now: 10_000).isEmpty)
        #expect(store.load().questions[0].answer == "Postgres")
        #expect(store.load().questions[0].autoDecidedAt == nil)
        #expect(decisions(root).isEmpty)
    }

    @Test func aLateAnswerReachesTheLeadAsANote() throws {
        let root = try repo()
        let store = BoardStore(root: root)
        let asked = try askTimed(store, at: 1_000)
        _ = try store.runTimers(now: 1_700)

        var board = store.load()
        let late = board.answer(asked.id, with: "Postgres", saw: 1, at: 1_800)
        guard case .afterAutoDecision(let question) = late else { Issue.record("\(late)"); return }
        #expect(question.state == .autoDecided)
        #expect(question.answer == "Postgres")
        let message = try #require(late.message(given: "Postgres"))
        #expect(message.contains("would have chosen otherwise: Postgres"))
        #expect(message.contains("‘SQLite’") && message.contains(asked.short))
        // Once is once.
        guard case .alreadyAnswered = board.answer(asked.id, with: "SQLite", saw: 1) else { Issue.record("answered twice"); return }

        // A late answer that agrees says so.
        var other = store.load()
        let agreeing = other.answer(asked.id, with: "sqlite", saw: 1)
        #expect(agreeing.message(given: "sqlite")?.contains("they agree") == true)
    }

    // MARK: Revisions and the stack

    @Test func aRevisionRestartsTheTimerOrDropsItWithItsProposal() throws {
        var board = LeadBoard()
        let asked = board.ask("Cache: Postgres or SQLite?", options: ["Postgres", "SQLite"], priority: nil, whyNow: nil, proposal: "SQLite", at: 1_000)
        let reworded = try board.revise(asked.id, text: "Local cache: Postgres or SQLite?", options: nil, note: "it's the local one", at: 1_400)
        #expect(reworded.isCounting && reworded.decideBy == 1_400 + 600)
        let without = try board.revise(asked.id, text: nil, options: ["Postgres", "DuckDB"], note: "SQLite is out", at: 1_500)
        #expect(!without.isCounting && without.proposal == nil && without.decideBy == nil)
        #expect(board.expire(now: 100_000).isEmpty)
    }

    @Test func aRevisionIntoARiskyQuestionDropsItsTimer() throws {
        var board = LeadBoard()
        let asked = board.ask("Keep the old fixtures?", options: ["Yes", "No"], priority: nil, whyNow: nil, proposal: "No", at: 1_000)
        #expect(asked.isCounting)
        let risky = try board.revise(asked.id, text: "Delete the old fixtures?", options: nil, note: "clearer", at: 1_100)
        #expect(!risky.isCounting && risky.proposal == nil && risky.decideBy == nil)
        #expect(board.expire(now: 100_000).isEmpty)
        // So do risky options.
        let other = board.ask("What next for add-b?", options: ["Rework", "Wait"], priority: nil, whyNow: nil, proposal: "Wait", at: 1_000)
        let outward = try board.revise(other.id, text: nil, options: ["Publish it", "Wait"], note: "it's done", at: 1_100)
        #expect(!outward.isCounting && outward.decideBy == nil)
    }

    @Test func reviseQuestionSaysWhyARiskyRewordingLostItsTimer() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("ask_user", ["question": "Keep the old fixtures?", "options": ["Yes", "No"], "proposal": "No"]).isError)
        let id = try #require(BoardStore(root: root).load().questions.first?.id)
        let revised = lead.call("revise_question", ["id": id, "text": "Delete the old fixtures?", "note": "clearer"])
        #expect(!revised.isError, "\(revised.text)")
        #expect(revised.text.contains("timer is off") && revised.text.contains("deleting or discarding"))
        let question = try #require(BoardStore(root: root).load().questions.first)
        #expect(!question.isCounting && question.decideBy == nil)
        #expect(try BoardStore(root: root).runTimers(now: Date().timeIntervalSince1970 + 100_000).isEmpty)
    }

    @Test func theStackShowsAutoDecidedOnesForAWhile() throws {
        var board = LeadBoard()
        let open = board.ask("Open?", options: [], priority: nil, whyNow: nil, at: 0)
        let timed = board.ask("Timed?", options: ["a", "b"], priority: nil, whyNow: nil, proposal: "a", at: 0)
        #expect(board.expire(now: 600).map(\.id) == [timed.id])
        #expect(board.questionStack(now: 700).map(\.id) == [open.id, timed.id])
        #expect(board.questionStack(now: 600 + LeadBoard.withdrawnShown).map(\.id) == [open.id])
        #expect(board.blockingQuestions == 0)
    }

    @Test func oldBoardsHaveNoTimers() throws {
        let json = #"{"tasks":[],"questions":[{"id":"2DB85777","text":"Base branch?","options":["main"],"askedAt":5}],"updates":[]}"#
        var board = try JSONDecoder().decode(LeadBoard.self, from: Data(json.utf8))
        #expect(!board.questions[0].isCounting)
        #expect(board.expire(now: 1_000_000).isEmpty)
        // And a timed one reads back as written.
        board.ask("Q?", options: ["a", "b"], priority: .whenever, whyNow: nil, proposal: "b", decideIn: 5, at: 10)
        _ = try board.hold(board.questions[1].id, at: 20)
        let again = try JSONDecoder().decode(LeadBoard.self, from: JSONEncoder().encode(board))
        #expect(again == board)
    }

    // MARK: Refusals

    @Test func noTimerOnRiskyQuestions() {
        func refused(_ text: String, options: [String] = ["Yes", "No"], why: String? = nil, priority: LeadQuestion.Priority? = nil) -> Bool {
            LeadQuestion.timerRefusal(text: text, options: options, whyNow: why, priority: priority) != nil
        }
        #expect(refused("Postgres or SQLite?", priority: .blocking))
        #expect(refused("Delete the old fixtures folder?"))
        #expect(refused("Discard the worker's unmerged changes on add-b?"))
        #expect(refused("Abandon the add-b task and clean up its worktree?"))
        #expect(refused("Force-push agent/add-b after the rebase?"))
        #expect(refused("Drop the branch agent/old-ui?"))
        #expect(refused("Merge add-hooks? It changes .claude/settings.json"))
        #expect(refused("Merge the task that touches CLAUDE.md?"))
        #expect(refused("Publish 2.1 to the website?"))
        #expect(refused("Push main to origin now?"))
        #expect(refused("Open a pull request upstream?"))
        #expect(refused("Email the beta testers about it?"))
        #expect(refused("Which one?", options: ["Deploy to production", "Wait"]))
        #expect(refused("Go ahead?", why: "It sends the release notes to the users"))
        // Reversible choices are fine, merges of ordinary code too.
        #expect(!refused("Postgres or SQLite for the local cache?", priority: .important))
        #expect(!refused("Name the menu item Team or Crew?", priority: .whenever))
        #expect(!refused("Merge add-b now or after add-c?"))
        #expect(!refused("Put the Hold button left or right of the countdown?"))
    }

    // MARK: The tool

    @Test func askUserTakesAProposalAndATimer() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        let ask = try #require(lead.tools.first { $0.name == "ask_user" })
        #expect(ask.properties["proposal"] != nil && ask.properties["decide_in"] != nil)
        #expect(ask.description.contains("timer") && ask.description.contains("reversible") && ask.description.contains("blocking"))

        let before = Date().timeIntervalSince1970
        let asked = lead.call("ask_user", ["question": "Postgres or SQLite for the local cache?", "options": ["Postgres", "SQLite"],
                                           "proposal": "sqlite"])
        #expect(!asked.isError, "\(asked.text)")
        #expect(asked.text.contains("‘SQLite’") && asked.text.contains("10 min"))
        let question = try #require(BoardStore(root: root).load().questions.first)
        #expect(question.proposal == "SQLite")  // spelled as the option is
        #expect(question.decideIn == 10)
        let deadline = try #require(question.decideBy)
        #expect(deadline >= before + 600 && deadline <= Date().timeIntervalSince1970 + 600)

        let short = lead.call("ask_user", ["question": "Team or Crew?", "options": ["Team", "Crew"], "proposal": "Team", "decide_in": 3, "priority": "whenever"])
        #expect(!short.isError, "\(short.text)")
        #expect(BoardStore(root: root).load().questions.last?.decideIn == 3)

        let status = lead.call("status", [:]).text
        #expect(status.contains("you go ahead with ‘SQLite’ at"))
        let listed = lead.call("questions", [:]).text
        #expect(listed.contains("proposal ‘SQLite’"))
    }

    @Test func askUserRefusesTimersItShouldNotHave() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        let blocking = lead.call("ask_user", ["question": "Postgres or SQLite?", "options": ["Postgres", "SQLite"], "proposal": "SQLite",
                                              "decide_in": 10, "priority": "blocking"])
        #expect(blocking.isError && blocking.text.contains("blocking"))
        let deleting = lead.call("ask_user", ["question": "Delete the old fixtures?", "options": ["Yes", "No"], "proposal": "Yes"])
        #expect(deleting.isError && deleting.text.contains("deleting or discarding"))
        let merging = lead.call("ask_user", ["question": "Merge add-hooks (it changes .claude/settings.json)?", "options": ["Yes", "No"], "proposal": "Yes"])
        #expect(merging.isError && merging.text.contains("sensitive"))
        let outward = lead.call("ask_user", ["question": "Publish the release notes?", "options": ["Yes", "No"], "proposal": "Yes"])
        #expect(outward.isError && outward.text.contains("outside"))
        // Malformed timers.
        #expect(lead.call("ask_user", ["question": "Q?", "options": ["a", "b"], "decide_in": 5]).isError)  // no proposal
        #expect(lead.call("ask_user", ["question": "Q?", "options": ["a", "b"], "proposal": "c"]).isError)  // not an option
        #expect(lead.call("ask_user", ["question": "Q?", "proposal": "a"]).isError)  // no options
        #expect(lead.call("ask_user", ["question": "Q?", "options": ["a", "b"], "proposal": "a", "decide_in": 0]).isError)
        #expect(lead.call("ask_user", ["question": "Q?", "options": ["a", "b"], "proposal": "a", "decide_in": 2.5]).isError)
        #expect(BoardStore(root: root).load().questions.isEmpty)
        // A blocking question without a timer is still fine.
        #expect(!lead.call("ask_user", ["question": "Delete the old fixtures?", "options": ["Yes", "No"], "priority": "blocking"]).isError)
    }

    @Test func theLeadIsToldToPreferTimersForReversibleChoices() {
        let prompt = LeadPrompts.lead(project: "acme", root: "/r", workflow: LeadWorkflow.parse("---\nmax_workers: 2\n---"))
        for needle in ["proposal", "decide_in", "reversible", "Never put a timer on a blocking question", "outward-facing", "deleting"] {
            #expect(prompt.contains(needle), "\(needle)")
        }
    }
}
