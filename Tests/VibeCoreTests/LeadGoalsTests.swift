import Foundation
import Testing
@testable import VibeCore

/// A project's goals (the web design of 2026-11-23, "Goals (new in the node)", `LeadGoals.swift`): the lead's tools to
/// keep them, each task's goal, the reminder while a task has none (and, with none set on a busy project, once a day),
/// the board's grouping and `status`'s line, and a board file with goals read by a build before them, and back.
struct LeadGoalsTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo() throws -> String {
        let url = temp.url("goals")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    func add(_ lead: LeadToolset, _ title: String, goal: String? = nil) -> MCPToolResult {
        var arguments: [String: Any] = ["title": title, "goal": "\(title) works", "acceptance": ["swift test"]]
        if let goal { arguments["goal_id"] = goal }
        return lead.call("add_task", arguments)
    }

    @Test func goalsAreAddedRenamedOrderedClosedAndGivenToTasks() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        let added = lead.call("add_goal", ["title": "Launch the paid plans", "done": "Pricing is live for new sign-ups"])
        #expect(!added.isError && added.text.contains("Added goal launch-the-paid-plans"), "\(added.text)")
        #expect(!lead.call("add_goal", ["title": "Uploads never lose a file", "done": "A failed upload retries once"]).isError)
        let board = { BoardStore(root: root).load() }
        #expect(board().goals?.map(\.id) == ["launch-the-paid-plans", "uploads-never-lose-a"])

        // A task with a goal, one moved to another, one cleared; unknown and closed goals refused.
        #expect(!add(lead, "Pricing copy", goal: "launch-the-paid-plans").isError)
        #expect(board().task("pricing-copy")?.goalID == "launch-the-paid-plans")
        let unknown = add(lead, "Other", goal: "no-such-goal")
        #expect(unknown.isError && unknown.text.contains("No goal no-such-goal"), "\(unknown.text)")
        #expect(board().task("other") == nil, "nothing added")
        #expect(lead.call("update_task", ["task": "pricing-copy", "goal_id": "uploads-never-lose-a"]).text == "pricing-copy's goal: uploads-never-lose-a.")
        #expect(board().task("pricing-copy")?.goalID == "uploads-never-lose-a")
        // With another change in the same call: both made.
        let both = lead.call("update_task", ["task": "pricing-copy", "goal_id": "launch-the-paid-plans", "title": "Pricing page copy"])
        #expect(!both.isError && board().task("pricing-copy")?.goalID == "launch-the-paid-plans" && board().task("pricing-copy")?.title == "Pricing page copy", "\(both.text)")

        // Renamed (its id kept), reordered, closed (its unfinished task then unsorted), opened again.
        #expect(!lead.call("update_goal", ["goal": "launch-the-paid-plans", "title": "Launch the plans"]).isError)
        #expect(board().goal("launch-the-paid-plans")?.title == "Launch the plans")
        #expect(lead.call("order_goals", ["goals": ["uploads-never-lose-a"]]).isError, "every open goal, once")
        #expect(!lead.call("order_goals", ["goals": ["uploads-never-lose-a", "launch-the-paid-plans"]]).isError)
        #expect(board().goals?.map(\.id) == ["uploads-never-lose-a", "launch-the-paid-plans"])
        let closed = lead.call("update_goal", ["goal": "launch-the-paid-plans", "state": "done"])
        #expect(closed.text.contains("unsorted now") && board().goal("launch-the-paid-plans")?.closedAt != nil, "\(closed.text)")
        #expect(board().unsorted.map(\.slug) == ["pricing-copy"])
        let toClosed = lead.call("update_task", ["task": "pricing-copy", "goal_id": "launch-the-paid-plans"])
        #expect(toClosed.isError && toClosed.text.contains("is done"), "\(toClosed.text)")
        #expect(!lead.call("update_goal", ["goal": "launch-the-paid-plans", "state": "open"]).isError)
        #expect(board().goal("launch-the-paid-plans")?.state == .open && board().unsorted.isEmpty)
        #expect(!lead.call("update_task", ["task": "pricing-copy", "goal_id": ""]).isError)
        #expect(board().task("pricing-copy")?.goalID == nil)
    }

    @Test func aGoalWhoseTextTheRecordsLintsFailOnIsRefusedAndNothingIsWritten() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        lead.recordLints = { .all }
        let bad = lead.call("add_goal", ["title": "Ship it for \(LeadRecordTextTests.privateName)", "done": "It is live"])
        #expect(bad.isError && bad.text.contains("nothing recorded"), "\(bad.text)")
        #expect((BoardStore(root: root).load().goals ?? []).isEmpty)
        #expect(!lead.call("add_goal", ["title": "Ship it", "done": "It is live"]).isError)
        let renamed = lead.call("update_goal", ["goal": "ship-it", "done": "\(LeadRecordTextTests.privateName) says so"])
        #expect(renamed.isError, "\(renamed.text)")
        #expect(BoardStore(root: root).load().goals?.first?.done == "It is live")
    }

    @Test func atMostEightOpenGoals() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        for index in 1...LeadBoard.mostOpenGoals { #expect(!lead.call("add_goal", ["title": "Goal number \(index)", "done": "It is done"]).isError) }
        let ninth = lead.call("add_goal", ["title": "One more", "done": "It is done"])
        #expect(ninth.isError && ninth.text.contains("Close one") && ninth.text.contains("merge two"), "\(ninth.text)")
        #expect(!lead.call("update_goal", ["goal": "goal-number-1", "state": "done"]).isError)
        #expect(!lead.call("add_goal", ["title": "One more", "done": "It is done"]).isError, "room again once one is closed")
        #expect(lead.call("update_goal", ["goal": "goal-number-1", "state": "open"]).isError, "a ninth open one isn't opened again")
        #expect(lead.call("add_goal", ["title": "Two\nlines", "done": "x"]).isError)
    }

    /// While the project has a goal and a task has none, the lead's next step says so (but the goal tools); a project
    /// with no goals and five unfinished tasks is told once, then not again within a day; one with four, nothing.
    @Test func theLeadIsRemindedOfUnsortedTasksAndOfNoGoals() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        for index in 1...4 { #expect(!add(lead, "Task number \(index)").text.contains("Goals:")) }
        #expect(!lead.call("status", [:]).text.contains(LeadGoals.noGoals), "four tasks: nothing")
        #expect(lead.call("status", [:]).text.contains("Goals: none set"), "status's own line")
        let fifth = add(lead, "Task number 5")
        #expect(fifth.text.contains(LeadGoals.noGoals), "\(fifth.text)")
        #expect(!lead.call("board", [:]).text.contains(LeadGoals.noGoals), "once a day")
        _ = try BoardStore(root: root).update { $0.goalsNudgedAt = Date().timeIntervalSince1970 - LeadBoard.goalsNudgeEvery - 1 }
        #expect(lead.call("board", [:]).text.contains(LeadGoals.noGoals), "a day on, again")

        let goal = lead.call("add_goal", ["title": "Ship it", "done": "It ships"])
        #expect(!goal.text.contains("Goals:"), "not on the goal tools")
        let next = lead.call("board", [:])
        #expect(next.text.contains("Goals: 5 open tasks have no goal") && next.text.contains("update_task(task, goal_id)"), "\(next.text)")
        for index in 1...5 { _ = lead.call("update_task", ["task": "task-number-\(index)", "goal_id": "ship-it"]) }
        #expect(!lead.call("board", [:]).text.contains("Goals:"))
        #expect(lead.call("status", [:]).text.contains("Goals: Ship it (5 to go of 5)"))
    }

    /// `board` groups the tasks under the goals, in their order, then the unsorted.
    @Test func theBoardGroupsTasksUnderTheirGoals() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        _ = lead.call("add_goal", ["title": "First goal", "done": "One"])
        _ = lead.call("add_goal", ["title": "Second goal", "done": "Two"])
        _ = add(lead, "In second", goal: "second-goal")
        _ = add(lead, "Loose one")
        _ = add(lead, "In first", goal: "first-goal")
        let text = lead.call("board", [:]).text
        let order = ["Goal first-goal [open]: First goal — done means: One", "- in-first ", "Goal second-goal [open]", "- in-second ", "Unsorted (no goal):", "- loose-one "]
        let at = order.map { text.range(of: $0)?.lowerBound }
        #expect(at.allSatisfy { $0 != nil } && zip(at, at.dropFirst()).allSatisfy { $0! < $1! }, "\(text)")
    }

    /// A board with goals read by a build before them (its types with neither field) keeps what it knew; an old board
    /// reads here with none; this build's goals survive its own round trip.
    @Test func boardFilesReadBothWays() throws {
        var board = LeadBoard()
        board.goals = [LeadGoal(id: "g", title: "A goal", done: "Done", createdAt: 1)]
        board.goalsNudgedAt = 5
        var task = LeadTask(slug: "t", title: "T", contract: LeadContract(goal: "x", acceptance: ["y"], boundaries: [], context: ""))
        task.goalID = "g"
        board.tasks = [task]
        let data = try JSONEncoder().encode(board)
        // A build before goals: its board and task without the fields (a stand-in with the keys it knew).
        struct OldTask: Codable, Equatable { var id: String; var slug: String; var title: String; var status: String }
        struct OldBoard: Codable { var tasks: [OldTask]; var baseBranch: String? }
        let old = try JSONDecoder().decode(OldBoard.self, from: data)
        #expect(old.tasks == [OldTask(id: task.id, slug: "t", title: "T", status: "planned")])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["goals"] != nil && ((object["tasks"] as? [[String: Any]])?.first?["goalID"] as? String) == "g")
        // And this build reads it back whole; an old board (no goals keys) reads with none.
        let again = try JSONDecoder().decode(LeadBoard.self, from: data)
        #expect(again.goals == board.goals && again.tasks.first?.goalID == "g" && again.goalsNudgedAt == 5)
        var stripped = object
        stripped["goals"] = nil
        stripped["goalsNudgedAt"] = nil
        stripped["tasks"] = (object["tasks"] as? [[String: Any]])?.map { var task = $0; task["goalID"] = nil; return task }
        let older = try JSONDecoder().decode(LeadBoard.self, from: JSONSerialization.data(withJSONObject: stripped))
        #expect(older.goals == nil && older.tasks.first?.goalID == nil && older.unsorted.isEmpty)
        #expect(LeadGoals.statusLine(older).contains("none set"))
    }
}
