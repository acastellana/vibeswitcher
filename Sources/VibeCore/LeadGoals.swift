import Foundation

/// A project's goal (the web design of 2026-11-23, "Goals (new in the node)"): the lead keeps three to five, in plain
/// words, each with one line on what "done" means, and every task belongs to one (`LeadTask.goalID`). The user's roadmap
/// is drawn from them. Kept on the board (`LeadBoard.goals`, in their order), the lead's own records: no new trust.
public struct LeadGoal: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable, CaseIterable {
        case open, done
    }

    /// A slug of its first title, kept when it is renamed.
    public var id: String
    public var title: String
    /// What "done" means for it, in one line.
    public var done: String
    public var state: State
    public var createdAt: Double
    /// When it was closed, while it is.
    public var closedAt: Double?

    public init(id: String, title: String, done: String, state: State = .open, createdAt: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.title = title
        self.done = done
        self.state = state
        self.createdAt = createdAt
    }
}

extension LeadTask {
    /// Not finished: planned, running, in review, blocked, failed or kept (what a goal still waits on).
    public var unfinished: Bool { [.planned, .running, .review, .blocked, .failed, .kept].contains(status) }
}

extension LeadBoard {
    /// The most open goals a project keeps: a ninth is refused (close or merge one).
    public static let mostOpenGoals = 8
    /// The unfinished tasks from which a project with no goals has its lead told to set some (`LeadGoals.nudge`).
    public static let goalsNudgeTasks = 5
    /// How often, at most, that is told.
    public static let goalsNudgeEvery: Double = 86_400

    public var openGoals: [LeadGoal] { (goals ?? []).filter { $0.state == .open } }

    public func goal(_ id: String) -> LeadGoal? { (goals ?? []).first { $0.id == id } }

    /// The unfinished tasks with no open goal (none, or a goal closed or gone), while the project has an open goal: what
    /// the lead is reminded of. Empty when it has none (`LeadGoals.nudge` says that instead).
    public var unsorted: [LeadTask] {
        guard !openGoals.isEmpty else { return [] }
        return tasks.filter { task in task.unfinished && task.goalID.flatMap { goal($0) }?.state != .open }
    }
}

/// The goals' words for the lead: the reminder at its next step, the status line, the board's grouping.
public enum LeadGoals {
    /// The line every lead tool's result carries (but the goal tools') while a task is unsorted.
    public static func unsortedLine(_ board: LeadBoard) -> String? {
        let unsorted = board.unsorted
        guard !unsorted.isEmpty else { return nil }
        let named = unsorted.prefix(8).map(\.slug).joined(separator: ", ") + (unsorted.count > 8 ? ", …" : "")
        return "Goals: \(unsorted.count) open task\(unsorted.count == 1 ? " has" : "s have") no goal (\(named)): give each one with update_task(task, goal_id)."
    }

    /// The line a project with no goals and `goalsNudgeTasks` unfinished tasks or more gets at the lead's next step, then
    /// at most once a day (`goalsNudgeEvery`), until a goal is added: nil when it isn't due.
    public static func nudge(_ board: LeadBoard, now: Double) -> String? {
        guard (board.goals ?? []).isEmpty, board.tasks.filter(\.unfinished).count >= LeadBoard.goalsNudgeTasks,
              board.goalsNudgedAt.map({ now - $0 >= LeadBoard.goalsNudgeEvery }) ?? true else { return nil }
        return noGoals
    }

    public static let noGoals = "This project has no goals yet: add 3 to 5 with add_goal, in plain words, and give each task one; the user's roadmap is drawn from them."

    /// `status`'s line about goals: none set, or the open ones with their tasks to go.
    public static func statusLine(_ board: LeadBoard) -> String {
        let open = board.openGoals
        guard !open.isEmpty else { return "Goals: none set (add_goal)." }
        let parts = open.map { goal in
            let mine = board.tasks.filter { $0.goalID == goal.id }
            return "\(goal.title) (\(mine.filter(\.unfinished).count) to go of \(mine.count))"
        }
        return "Goals: " + parts.joined(separator: "; ") + "."
    }

    /// The board's task lines (`lines`, in board order, each for its task) grouped under the goals: each open goal in
    /// its order, then the done ones, each with its tasks; then "Unsorted". Unchanged with no goals.
    public static func grouped(_ board: LeadBoard, lines: [(task: LeadTask, line: String)]) -> [String] {
        let goals = board.goals ?? []
        guard !goals.isEmpty else { return lines.map(\.line) }
        var out: [String] = []
        var placed = Set<String>()
        for goal in goals.filter({ $0.state == .open }) + goals.filter({ $0.state == .done }) {
            let mine = lines.filter { $0.task.goalID == goal.id }
            out.append("\nGoal \(goal.id) [\(goal.state.rawValue)]: \(goal.title) — done means: \(goal.done)" + (mine.isEmpty ? " (no tasks)" : ""))
            out += mine.map(\.line)
            placed.formUnion(mine.map(\.task.id))
        }
        let rest = lines.filter { !placed.contains($0.task.id) }
        if !rest.isEmpty {
            out.append("\nUnsorted (no goal):")
            out += rest.map(\.line)
        }
        return out
    }

    /// A goal's title or done line, checked: one line, not empty, at most `textLimit` characters.
    static func text(_ given: Any?, _ name: String) throws -> String? {
        guard let given, !(given is NSNull) else { return nil }
        guard let text = (given as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw LeadToolset.Problem(text: "\(name) is a line of plain words. Nothing was changed.")
        }
        guard !text.contains("\n"), text.count <= textLimit else {
            throw LeadToolset.Problem(text: "\(name) is one line of \(textLimit) characters at most. Nothing was changed.")
        }
        return text
    }

    static let textLimit = 200
}

extension LeadToolset {
    /// add_task's and update_task's `goal_id`.
    static var goalIDProperty: MCPToolInfo.Property {
        MCPToolInfo.Property(type: "string", description: "The project's goal this task serves (its id, as status and board show it; add_goal makes one). Empty clears it")
    }

    /// `add_goal(title, done)`: a goal at the end of the order, open. Refused past `mostOpenGoals` open ones.
    func addGoal(_ arguments: [String: Any]) throws -> MCPToolResult {
        guard let title = try LeadGoals.text(arguments["title"], "title"), let done = try LeadGoals.text(arguments["done"], "done") else {
            throw Problem(text: "A goal needs a title and done (what done means, in one line). Nothing was changed.")
        }
        let goal = try store.update { board -> LeadGoal in
            guard board.openGoals.count < LeadBoard.mostOpenGoals else {
                throw Problem(text: "Not added: this project has \(LeadBoard.mostOpenGoals) open goals, the most it keeps. Close one (update_goal(goal, state: done)) "
                              + "or merge two (move one's tasks with update_task(task, goal_id), then close it). Nothing was changed.")
            }
            let goal = LeadGoal(id: Slug.make(title, taken: Set((board.goals ?? []).map(\.id))), title: title, done: done)
            board.goals = (board.goals ?? []) + [goal]
            return goal
        }
        try? store.appendProgress("Goal \(goal.id) added: \(title)")
        let board = store.load()
        return MCPToolResult(text: "Added goal \(goal.id) (\(title)), \(board.openGoals.count) open. Give tasks to it with add_task or update_task(task, goal_id: \(goal.id)).")
    }

    /// `update_goal(goal, title?, done?, state?)`: renamed, redefined, closed (done) or opened again.
    func updateGoal(_ arguments: [String: Any]) throws -> MCPToolResult {
        guard let id = (arguments["goal"] as? String)?.trimmingCharacters(in: .whitespaces), !id.isEmpty else {
            throw Problem(text: "Say which goal (goal: its id, as status and board show it). Nothing was changed.")
        }
        let title = try LeadGoals.text(arguments["title"], "title"), done = try LeadGoals.text(arguments["done"], "done")
        var state: LeadGoal.State?
        if let given = arguments["state"] as? String, !given.isEmpty {
            guard let wanted = LeadGoal.State(rawValue: given.lowercased()) else {
                throw Problem(text: "A goal's state is open or done, not \(given). Nothing was changed.")
            }
            state = wanted
        }
        guard title != nil || done != nil || state != nil else { throw Problem(text: "Give a title, done or state to change. Nothing was changed.") }
        let goal = try store.update { board -> LeadGoal in
            guard var goals = board.goals, let at = goals.firstIndex(where: { $0.id == id }) else {
                throw Problem(text: "No goal \(id): " + ((board.goals ?? []).isEmpty ? "this project has none yet (add_goal)." : "its goals are \((board.goals ?? []).map(\.id).joined(separator: ", ")).") + " Nothing was changed.")
            }
            if state == .open, goals[at].state == .done, board.openGoals.count >= LeadBoard.mostOpenGoals {
                throw Problem(text: "Not opened again: this project has \(LeadBoard.mostOpenGoals) open goals already; close one first. Nothing was changed.")
            }
            if let title { goals[at].title = title }
            if let done { goals[at].done = done }
            if let state, state != goals[at].state {
                goals[at].state = state
                goals[at].closedAt = state == .done ? Date().timeIntervalSince1970 : nil
            }
            board.goals = goals
            return goals[at]
        }
        try? store.appendProgress("Goal \(goal.id) changed: \(goal.title) [\(goal.state.rawValue)]")
        let left = store.load().tasks.filter { $0.goalID == goal.id && $0.unfinished }.map(\.slug)
        let note = goal.state == .done && !left.isEmpty ? " Its unfinished tasks (\(left.joined(separator: ", "))) are unsorted now: give each another goal." : ""
        return MCPToolResult(text: "Goal \(goal.id): \(goal.title) — done means: \(goal.done) [\(goal.state.rawValue)].\(note)")
    }

    /// `order_goals(goals: [ids])`: the open goals in this order, each once (the done ones follow, as they were).
    func orderGoals(_ arguments: [String: Any]) throws -> MCPToolResult {
        let given = (arguments["goals"] as? [Any])?.compactMap { $0 as? String } ?? (arguments["goals"] as? String).map { [$0] } ?? []
        let order = given.map { $0.trimmingCharacters(in: .whitespaces) }
        let goals = try store.update { board -> [LeadGoal] in
            let open = board.openGoals
            guard Set(order) == Set(open.map(\.id)), order.count == open.count else {
                throw Problem(text: "Give every open goal once, in the order wanted: \(open.map(\.id).joined(separator: ", ")). Nothing was changed.")
            }
            let byID = Dictionary(uniqueKeysWithValues: open.map { ($0.id, $0) })
            board.goals = order.compactMap { byID[$0] } + (board.goals ?? []).filter { $0.state == .done }
            return board.goals ?? []
        }
        return MCPToolResult(text: "Goals in order: " + goals.filter { $0.state == .open }.map { "\($0.id) (\($0.title))" }.joined(separator: ", ") + ".")
    }

    /// The `goal_id` given to add_task or update_task: nil when none was; .some(nil) to clear it (""); else an open goal's.
    func goalArgument(_ arguments: [String: Any], on board: LeadBoard) throws -> String?? {
        guard let given = arguments["goal_id"], !(given is NSNull) else { return nil }
        guard let text = (given as? String)?.trimmingCharacters(in: .whitespaces) else { throw Problem(text: "goal_id is a goal's id. Nothing was changed.") }
        if text.isEmpty { return .some(nil) }
        guard let goal = board.goal(text) else {
            throw Problem(text: "No goal \(text): " + ((board.goals ?? []).isEmpty ? "this project has none yet (add_goal)." : "its goals are \((board.goals ?? []).map(\.id).joined(separator: ", ")).") + " Nothing was changed.")
        }
        guard goal.state == .open else { throw Problem(text: "Goal \(text) is done: give the task an open one, or open it again (update_goal). Nothing was changed.") }
        return .some(goal.id)
    }

    /// What a lead tool's result carries about goals (but the goal tools', and `status`, whose own line says it): the
    /// unsorted tasks while any is; else, for a project with no goals and enough tasks, once a day, that it has none (the
    /// board stamps when).
    func goalsNotice(after tool: String) -> String? {
        guard !["add_goal", "update_goal", "order_goals", "status"].contains(tool) else { return nil }
        let board = store.load()
        if let line = LeadGoals.unsortedLine(board) { return line }
        let now = Date().timeIntervalSince1970
        guard let line = LeadGoals.nudge(board, now: now) else { return nil }
        _ = try? store.update { $0.goalsNudgedAt = now }
        return line
    }
}
