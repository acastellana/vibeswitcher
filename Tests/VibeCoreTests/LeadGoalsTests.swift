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
        let goals = { GoalStore(root: root).load() }
        #expect(goals().goals.map(\.id) == ["launch-the-paid-plans", "uploads-never-lose-a"])

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
        #expect(goals().goal("launch-the-paid-plans")?.title == "Launch the plans")
        #expect(lead.call("order_goals", ["goals": ["uploads-never-lose-a"]]).isError, "every open goal, once")
        #expect(!lead.call("order_goals", ["goals": ["uploads-never-lose-a", "launch-the-paid-plans"]]).isError)
        #expect(goals().goals.map(\.id) == ["uploads-never-lose-a", "launch-the-paid-plans"])
        let closed = lead.call("update_goal", ["goal": "launch-the-paid-plans", "state": "done"])
        #expect(closed.text.contains("unsorted now") && goals().goal("launch-the-paid-plans")?.closedAt != nil, "\(closed.text)")
        #expect(goals().unsorted(board()).map(\.slug) == ["pricing-copy"])
        let toClosed = lead.call("update_task", ["task": "pricing-copy", "goal_id": "launch-the-paid-plans"])
        #expect(toClosed.isError && toClosed.text.contains("is done"), "\(toClosed.text)")
        #expect(!lead.call("update_goal", ["goal": "launch-the-paid-plans", "state": "open"]).isError)
        #expect(goals().goal("launch-the-paid-plans")?.state == .open && goals().unsorted(board()).isEmpty)
        #expect(!lead.call("update_task", ["task": "pricing-copy", "goal_id": ""]).isError)
        #expect(board().task("pricing-copy")?.goalID == nil)
    }

    @Test func aGoalWhoseTextTheRecordsLintsFailOnIsRefusedAndNothingIsWritten() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        lead.recordLints = { .all }
        let bad = lead.call("add_goal", ["title": "Ship it for \(LeadRecordTextTests.privateName)", "done": "It is live"])
        #expect(bad.isError && bad.text.contains("nothing recorded"), "\(bad.text)")
        #expect(GoalStore(root: root).load().goals.isEmpty)
        #expect(!lead.call("add_goal", ["title": "Ship it", "done": "It is live"]).isError)
        let renamed = lead.call("update_goal", ["goal": "ship-it", "done": "\(LeadRecordTextTests.privateName) says so"])
        #expect(renamed.isError, "\(renamed.text)")
        #expect(GoalStore(root: root).load().goals.first?.done == "It is live")
    }

    @Test func atMostEightOpenGoals() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        for index in 1...LeadGoalsFile.mostOpen { #expect(!lead.call("add_goal", ["title": "Goal number \(index)", "done": "It is done"]).isError) }
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
        _ = try GoalStore(root: root).update { $0.nudgedAt = Date().timeIntervalSince1970 - LeadGoalsFile.nudgeEvery - 1 }
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

    /// The goals live in goals.json beside the board, never in it (the Mac app's tests pin LeadBoard's stored
    /// properties); a task's goalID is on the board, which a build before it reads as it knew it (it passes over the key);
    /// an old board reads with no goals.
    @Test func goalsAreKeptBesideTheBoardAndFilesReadBothWays() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        _ = lead.call("add_goal", ["title": "A goal", "done": "Done"])
        _ = lead.call("add_task", ["title": "T", "goal": "x", "acceptance": ["y"], "goal_id": "a-goal"])
        let folder = BoardStore(root: root).folder
        let boardData = try Data(contentsOf: URL(fileURLWithPath: folder + "/board.json"))
        let object = try #require(try JSONSerialization.jsonObject(with: boardData) as? [String: Any])
        #expect(object["goals"] == nil && object["goalsNudgedAt"] == nil, "the board holds no goals")
        #expect(((object["tasks"] as? [[String: Any]])?.first?["goalID"] as? String) == "a-goal")
        let kept = try JSONDecoder().decode(LeadGoalsFile.self, from: Data(contentsOf: URL(fileURLWithPath: folder + "/goals.json")))
        #expect(kept.goals.map(\.id) == ["a-goal"])
        // A build before goals: its board and task without the fields (a stand-in with the keys it knew).
        struct OldTask: Codable, Equatable { var slug: String; var title: String; var status: String }
        struct OldBoard: Codable { var tasks: [OldTask]; var baseBranch: String? }
        #expect(try JSONDecoder().decode(OldBoard.self, from: boardData).tasks == [OldTask(slug: "t", title: "T", status: "planned")])
        // An old board (no goalID) reads here with none, and no goals file: none, nothing unsorted.
        var stripped = object
        stripped["tasks"] = (object["tasks"] as? [[String: Any]])?.map { var task = $0; task["goalID"] = nil; return task }
        let older = try JSONDecoder().decode(LeadBoard.self, from: JSONSerialization.data(withJSONObject: stripped))
        #expect(older.tasks.first?.goalID == nil && LeadGoalsFile().unsorted(older).isEmpty)
        #expect(LeadGoals.statusLine(older, LeadGoalsFile()).contains("none set"))
        #expect(try JSONDecoder().decode(LeadGoalsFile.self, from: Data("{}".utf8)) == LeadGoalsFile())
    }

    /// A board file a build of 2026-11-23 wrote with its goals in it (`goals`, `goalsNudgedAt`): read once, the goals
    /// moved to goals.json, and the board's next write drops them there.
    @Test func goalsInABoardFileAreMovedToTheirOwnFile() throws {
        let root = try repo()
        let store = BoardStore(root: root)
        try store.prepare()
        var task = LeadTask(slug: "t", title: "T", contract: LeadContract(goal: "x", acceptance: ["y"], boundaries: [], context: ""))
        task.goalID = "g"
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode({ var board = LeadBoard(); board.tasks = [task]; return board }())) as? [String: Any])
        object["goals"] = [["id": "g", "title": "A goal", "done": "Done", "state": "open", "createdAt": 1.0]]
        object["goalsNudgedAt"] = 5.0
        try JSONSerialization.data(withJSONObject: object).write(to: URL(fileURLWithPath: store.folder + "/board.json"))
        #expect(!FileManager.default.fileExists(atPath: store.folder + "/goals.json"))
        let goals = GoalStore(board: store).load()
        #expect(goals.goals.map(\.id) == ["g"] && goals.nudgedAt == 5)
        #expect(FileManager.default.fileExists(atPath: store.folder + "/goals.json"), "moved at the first read")
        _ = try store.update { $0.baseBranch = "main" }
        let rewritten = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: store.folder + "/board.json"))) as? [String: Any])
        #expect(rewritten["goals"] == nil && rewritten["goalsNudgedAt"] == nil)
        #expect(GoalStore(board: store).load().goals.map(\.id) == ["g"], "still the goals file's")
    }
}
