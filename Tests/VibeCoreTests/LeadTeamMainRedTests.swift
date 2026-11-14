import Foundation
import Testing
@testable import VibeCore

/// A team task's members hear what its worker would (docs/process/reviews/team-on-one-task-design.md, "Integration";
/// T8): main's red and green notices go to each live member once (`LeadTeamMember.mainRedTold`, one per member), a
/// member started during the red has it in its brief, and one that wasn't running hears it with its next message;
/// "main moved and touched your files" tells the integrator to merge main in and the other members to merge the team
/// branch in. And (T11's hand-over) a team task's receipt, read through `receiptUsage`, lists each member's minutes
/// (counted per member by `LeadBoard.noteWork`) and tokens.
extension LeadTakePartTests {
    static let failure = MergeBatchTests.failure
    static let sessions = ["session-1", "session-2", "session-3"]

    /// The main red and green notices a session got.
    func redNews(_ team: Team, to session: String) -> [String] {
        team.runtime.steered.filter { $0.target == session && ($0.text.hasPrefix("main is red") || $0.text.hasPrefix("main is green again")) }.map(\.text)
    }

    func mainIsRed(_ team: Team) {
        let head = Git.run(["rev-parse", "main"], in: team.root).output
        _ = team.lead.mainIsRed((["breaks()"], true, Self.failure), rerun: Self.failure, slug: "other", onto: head, workflow: team.lead.workflow)
    }

    func brief(_ team: Team, _ name: String) throws -> String {
        try String(contentsOf: vault.runFolder(root: team.root, name: name).appendingPathComponent("prompt.md"), encoding: .utf8)
    }

    // MARK: Main red and green

    @Test func eachLiveMemberIsToldOnceThatMainIsRedAndOnceThatItsGreenAgain() throws {
        let team = try team()
        mainIsRed(team)
        for session in Self.sessions {
            let said = redNews(team, to: session)
            #expect(said.count == 1 && said[0].contains("breaks() fail on main itself") && said[0].contains("They aren't yours to fix"), "\(session): \(said)")
        }
        // One claim per member, on the board.
        let red = try #require(task(team)?.team)
        #expect(task(team)?.mainRedTold == ["breaks()"] && red.dropFirst().allSatisfy { $0.mainRedTold == ["breaks()"] }, "\(red)")
        // The same red again, and the lead's loop passes: nothing more.
        mainIsRed(team)
        team.lead.deliverWalls()
        #expect(Self.sessions.allSatisfy { redNews(team, to: $0).count == 1 })

        let head = Git.run(["rev-parse", "main"], in: team.root).output
        team.lead.noteMainGreen(.passed(head), rerun: nil)
        team.lead.noteMainGreen(.passed(head), rerun: nil)
        team.lead.deliverWalls()
        for session in Self.sessions {
            let said = redNews(team, to: session)
            #expect(said.count == 2 && said[1].hasPrefix("main is green again"), "\(session): \(said)")
        }
        #expect(task(team)?.team?.allSatisfy { $0.mainRedTold == nil } == true)
        // Only the team's own sessions were ever messaged (and the lead, agent:<pid>, told of the red).
        let targets = Set(team.runtime.steered.map(\.target)).filter { $0 != "agent:\(team.runtime.me.pid)" }
        #expect(targets == Set(Self.sessions), "\(targets)")
    }

    @Test func aMemberStartedDuringTheRedHasItInItsBriefAndIsntToldAgain() throws {
        let team = try team(split: false)
        mainIsRed(team)
        // The integrator runs: told at once.
        #expect(redNews(team, to: "session-1").count == 1, "\(redNews(team, to: "session-1"))")
        try commit("api.swift", "protocol API {}\n", in: team.worktree)
        #expect(!team.core.call("split", [:]).isError)
        let started = team.lead.call("start_worker", ["task": "build-it"])
        #expect(!started.isError, "\(started.text)")
        for name in ["worker-build-it--ui", "worker-build-it--docs"] {
            let text = try brief(team, name)
            #expect(text.contains("Main red: main is red: breaks() fail on main itself"), "\(name): \(text)")
        }
        #expect(task(team)?.team?.dropFirst().allSatisfy { $0.mainRedTold == ["breaks()"] } == true)
        // The red again, and the loop's pass: neither member is told what its brief said.
        mainIsRed(team)
        team.lead.deliverWalls()
        #expect(redNews(team, to: "session-2").isEmpty && redNews(team, to: "session-3").isEmpty,
                "\(redNews(team, to: "session-2")) \(redNews(team, to: "session-3"))")
        #expect(redNews(team, to: "session-1").count == 1)
    }

    @Test func aMemberThatWasntRunningHearsItWithItsNextMessage() throws {
        let team = try team()
        try BoardStore(root: team.root).update { board in board.tasks[board.taskIndex("build-it")!].status = .blocked }
        mainIsRed(team)
        #expect(Self.sessions.allSatisfy { redNews(team, to: $0).isEmpty })

        // The lead's post to ui is its next message: the red goes just before it, once.
        let posted = team.lead.call("post", ["task": "build-it", "to": ["ui"], "text": "Which file holds the views?", "needs_answer": true])
        #expect(!posted.isError, "\(posted.text)")
        let ui = team.runtime.steered.filter { $0.target == "session-2" }.map(\.text)
        #expect(ui.count == 2 && ui[0].hasPrefix("main is red") && ui[1].contains("Which file holds the views?"), "\(ui)")
        #expect(redNews(team, to: "session-3").isEmpty)
        let again = team.lead.call("post", ["task": "build-it", "to": ["ui"], "text": "And the tests?", "needs_answer": true])
        #expect(!again.isError, "\(again.text)")
        #expect(redNews(team, to: "session-2").count == 1)

        // Back to running, the lead's loop passes: nothing of its own (each pass's board write would wake it again).
        try BoardStore(root: team.root).update { board in board.tasks[board.taskIndex("build-it")!].status = .running }
        team.lead.deliverWalls()
        #expect(redNews(team, to: "session-3").isEmpty && redNews(team, to: "session-1").isEmpty)
        // docs hears it with its next message, and the integrator with the lead's.
        #expect(!team.lead.call("post", ["task": "build-it", "to": ["docs"], "text": "Ready?", "needs_answer": true]).isError)
        #expect(!team.lead.call("message", ["task": "build-it", "text": "Go on."]).isError)
        #expect(Self.sessions.dropFirst().allSatisfy { redNews(team, to: $0).count == 1 }, "\(Self.sessions.map { redNews(team, to: $0) })")
        let core = team.runtime.steered.filter { $0.target == "session-1" }.map(\.text)
        #expect(core.last?.hasPrefix("Go on.") == true && core.last?.contains("main is red") == true, "\(core)")
    }

    /// A notice that didn't go is unclaimed, and goes with the member's next message; the lead's loop never retries it
    /// on its own (a member whose box won't submit would be typed into at every pass, each pass waking the next).
    @Test func aDeliveryThatDidntGoIsUnclaimedAndGoesWithTheNextMessage() throws {
        let team = try team()
        team.runtime.delivery = .notSubmitted("main is red")
        mainIsRed(team)
        #expect(task(team)?.team?.dropFirst().allSatisfy { $0.mainRedTold == nil } == true, "\(String(describing: task(team)?.team))")
        let tries = redNews(team, to: "session-2").count
        let board = BoardStore(root: team.root)
        let written = try FileManager.default.attributesOfItem(atPath: (board.folder as NSString).appendingPathComponent("board.json"))[.modificationDate] as? Date
        team.lead.deliverWalls()
        team.lead.deliverWalls()
        #expect(redNews(team, to: "session-2").count == tries)
        #expect(try FileManager.default.attributesOfItem(atPath: (board.folder as NSString).appendingPathComponent("board.json"))[.modificationDate] as? Date == written)
        team.runtime.delivery = .steered
        #expect(!team.lead.call("post", ["task": "build-it", "to": ["ui"], "text": "Ready?", "needs_answer": true]).isError)
        #expect(task(team)?.teamMember("ui")?.mainRedTold == ["breaks()"] && task(team)?.teamMember("docs")?.mainRedTold == nil)
        let ui = team.runtime.steered.filter { $0.target == "session-2" }.map(\.text)
        #expect(ui.suffix(2).first?.hasPrefix("main is red") == true && ui.last?.contains("Ready?") == true, "\(ui)")
    }

    // MARK: Main moved and touched the team's files

    /// main changes `file`, as another task's merge would: from its old head to its new one.
    func mainMoves(_ team: Team, _ file: String) throws -> (old: String, new: String) {
        let old = Git.run(["rev-parse", "main"], in: team.root).output
        let new = try commit(file, "changed on main\n", in: team.root)
        return (old, new)
    }

    func catchUps(_ team: Team, to session: String) -> [String] {
        team.runtime.steered.filter { $0.target == session && $0.text.contains("just moved") }.map(\.text)
    }

    @Test func mainTouchingTheTeamsFilesTellsTheIntegratorToMergeMainAndTheMembersTheTeamBranch() throws {
        let team = try team()
        try commit("ui.swift", "struct UI {}\n", in: team.folder("ui"))
        // Only ui's own branch changes ui.swift: the team is told all the same.
        let moved = try mainMoves(team, "ui.swift")
        let said = team.lead.tellToCatchUp(merged: "other", from: moved.old, to: moved.new, base: "main")
        let core = catchUps(team, to: "session-1")
        #expect(core.count == 1 && core[0].contains("Merge main in now") && core[0].contains("`git merge main`") && core[0].contains("ui.swift"), "\(core)")
        for session in ["session-2", "session-3"] {
            let member = catchUps(team, to: session)
            #expect(member.count == 1, "\(session): \(member)")
            #expect(member.first?.contains("`git merge agent/build-it`") == true && member.first?.contains("ui.swift") == true, "\(member)")
            #expect(member.first?.contains("core merges main into agent/build-it") == true && member.first?.contains("`git merge main`") == false, "\(member)")
        }
        #expect(said.contains("build-it (ui.swift)") && said.contains("ui, docs"), "\(said)")

        // A file no branch of the team changes: nobody is told.
        let apart = try mainMoves(team, "elsewhere.txt")
        #expect(team.lead.tellToCatchUp(merged: "more", from: apart.old, to: apart.new, base: "main").isEmpty)
        #expect(Self.sessions.allSatisfy { catchUps(team, to: $0).count == 1 })
    }

    // MARK: The receipt (T11's hand-over)

    @Test func aTeamTasksReceiptThroughReceiptUsageListsAndSumsEachMembersMinutesAndTokens() throws {
        let team = try team()
        let home = temp.url("claude-home").path
        team.lead.claudeHome = home
        let start = try #require(task(team)).createdAt
        let tokens = ["core": (100, 1000), "ui": (20, 2000), "docs": (3, 300)]
        for (name, (input, output)) in tokens {
            let slug = name == "core" ? "build-it" : "build-it--\(name)"
            let folder = try #require(LeadReceipts.folders(root: team.root, slug: slug, home: home).first)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let lines = LeadReceiptTests.named("worker-\(slug)", session: name)
                + [LeadReceiptTests.response("m-\(name)", "claude-opus-5-5", input: input, output: output, at: start + 1)]
            try (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("\(name).jsonl"), atomically: true, encoding: .utf8)
        }
        // Each member's working time, as the witness counts it.
        let minutes = ["core": 40.0, "ui": 25.0, "docs": 10.0]
        try BoardStore(root: team.root).update { board in
            let index = board.taskIndex("build-it")!
            for at in board.tasks[index].team!.indices { board.tasks[index].team![at].worked = minutes[board.tasks[index].team![at].name]! * 60 }
        }
        let stopped = team.lead.call("stop_worker", ["task": "build-it"])
        #expect(!stopped.isError, "\(stopped.text)")
        let abandoned = team.lead.call("update_task", ["task": "build-it", "status": "abandoned", "reason": "not wanted"])
        #expect(!abandoned.isError, "\(abandoned.text)")
        let receipt = try #require(task(team)?.receipt)
        let members = try #require(receipt.members)
        #expect(members.map(\.name) == ["core", "ui", "docs"])
        for member in members {
            #expect(member.worked == minutes[member.name]! * 60, "\(member)")
            #expect(member.worker?.input == tokens[member.name]!.0 && member.worker?.output == tokens[member.name]!.1, "\(member)")
        }
        #expect(receipt.worked == 75 * 60.0)
        #expect(receipt.worker?.input == 123 && receipt.worker?.output == 3300 && receipt.worker?.sessions == 3, "\(String(describing: receipt.worker))")
        #expect(receipt.line.contains("team of 3: core 40 min worked"), "\(receipt.line)")
    }

    /// Each member's counted minutes, set as the witness would.
    func setMembersWorked(_ team: Team, _ minutes: Double) throws {
        try BoardStore(root: team.root).update { board in
            let index = board.taskIndex("build-it")!
            for at in board.tasks[index].team!.indices {
                board.tasks[index].team![at].worked = minutes * 60
                board.tasks[index].team![at].workedAt = 1000
            }
        }
    }

    /// Re-rolled or re-planned, a team task's members' time starts from zero with the task's: else its next receipt
    /// counts their earlier rounds again (audit F1).
    @Test(arguments: ["reroll", "replan"])
    func aRerollOrReplanStartsTheMembersWorkingTimeOver(_ how: String) throws {
        let team = try team()
        try setMembersWorked(team, 30)
        if how == "reroll" {
            let rerolled = team.lead.call("update_task", ["task": "build-it", "reroll": true])
            #expect(!rerolled.isError, "\(rerolled.text)")
        } else {
            #expect(!team.lead.call("stop_worker", ["task": "build-it"]).isError)
            let replanned = team.lead.call("update_task", ["task": "build-it", "status": "planned"])
            #expect(!replanned.isError, "\(replanned.text)")
        }
        var board = try BoardStore(root: team.root).read()
        BoardStore(root: team.root).budgetClock().apply(to: &board)
        let members = try #require(board.task("build-it")?.team)
        #expect(members.allSatisfy { $0.worked == nil && $0.workedAt == nil }, "\(members)")
        #expect(board.task("build-it")?.worked == nil)
    }

    // MARK: Working time, per member

    @Test func theWitnessCountsEachMembersWorkingTimeAsWellAsTheTasks() throws {
        let team = try team()
        let id = try #require(task(team)).id
        let store = BoardStore(root: team.root)
        let ui = LeadBudget.memberKey(id, member: "ui")
        // core and ui work, docs doesn't: each step counts for the task, core and ui.
        try store.noteWork([id, ui], defaultMinutes: 0, now: 1000)
        try store.noteWork([id, ui], defaultMinutes: 0, now: 1060)
        try store.noteWork([ui], defaultMinutes: 0, now: 1120)
        try store.noteWork([], defaultMinutes: 0, now: 1180)
        var board = try store.read()
        store.budgetClock().apply(to: &board)
        let counted = try #require(board.task("build-it"))
        #expect(counted.worked == 120, "\(String(describing: counted.worked))")
        #expect(counted.teamMember("core")?.worked == 60 && counted.teamMember("ui")?.worked == 120 && counted.teamMember("docs")?.worked == nil,
                "\(String(describing: counted.team))")
        #expect(counted.team?.allSatisfy { $0.workedAt == nil } == true)
        // The witness's working set names a member by its key only while its own worker works.
        let seen = Dictionary(uniqueKeysWithValues: Self.sessions.map { ($0, LeadWitness.Seen(live: true, status: .working, activity: .working(nil))) })
        #expect(LeadBudget.working(board: board, seen: seen) == [id, ui, LeadBudget.memberKey(id, member: "docs")])
    }
}
