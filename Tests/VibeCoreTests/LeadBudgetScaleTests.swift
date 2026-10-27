import Foundation
import Testing
@testable import VibeCore

/// The time budget's bookkeeping looks only at the running tasks: hang-20261027-041428 caught `noteWork` copying and
/// comparing each of a 254-task board's tasks on the main thread at every look. The clock is the test's own.
struct LeadBudgetScaleTests {
    /// Two running tasks (workers w0 and w1, budgets of 1 and 3 min) and `others` that don't run, of every other
    /// status, some with time worked and one over its budget: the shape of a long-lived project's board.
    static func board(others: Int) -> LeadBoard {
        var board = LeadBoard()
        for (n, budget) in [1, 3].enumerated() {
            var task = LeadBudgetTests.task(budget: budget)
            task.slug = "run\(n)"
            task.worker = "w\(n)"
            board.tasks.append(task)
        }
        let statuses = LeadTask.Status.allCases.filter { $0 != .running }
        for n in 0..<others {
            var task = LeadBudgetTests.task(budget: 1, statuses[n % statuses.count])
            task.slug = "old\(n)"
            task.worker = "old\(n)"
            task.worked = Double(n * 60)
            if n % 7 == 0 { task.overBudget = LeadOverBudget(minutes: 1, at: LeadBudgetTests.t0 - 3600) }
            board.tasks.append(task)
        }
        return board
    }

    /// noteWork as it was before it looked only at the running tasks: every task, copied and compared.
    static func reference(_ board: inout LeadBoard, _ working: Set<String>, defaultMinutes: Int, now: Double) -> [String] {
        var reached: [String] = []
        for index in board.tasks.indices {
            var task = board.tasks[index]
            if task.status == .running, working.contains(task.id) {
                if let since = task.workedAt {
                    if now - since >= LeadBudget.step {
                        task.worked = (task.worked ?? 0) + min(now - since, LeadBudget.longestStep)
                        task.workedAt = now
                    }
                } else {
                    task.workedAt = now
                }
            } else {
                task.workedAt = nil
            }
            if task.status == .running, task.overBudget == nil, let minutes = LeadBudget.minutes(task, default: defaultMinutes),
               (task.worked ?? 0) >= Double(minutes) * 60 {
                task.overBudget = LeadOverBudget(minutes: minutes, at: now)
                reached.append(task.slug)
            }
            board.tasks[index] = task
        }
        return reached
    }

    /// The looks every 3 s for `seconds`, w0 working throughout and w1 for the first half: the slugs told at each,
    /// the board checked against `reference` and `notesWork` against what noteWork changed at every look.
    static func look(_ board: inout LeadBoard, for seconds: Double) -> [(at: Double, slugs: [String])] {
        var expected = board
        var told: [(at: Double, slugs: [String])] = []
        var now = LeadBudgetTests.t0
        while now <= LeadBudgetTests.t0 + seconds {
            var seen = ["w0": LeadBudgetTests.working, "w1": LeadBudgetTests.working]
            if now - LeadBudgetTests.t0 > seconds / 2 { seen["w1"] = LeadBudgetTests.waiting }
            let working = LeadBudget.working(board: board, seen: seen)
            let notes = board.notesWork(working, defaultMinutes: 120, now: now)
            let before = board
            let noted = board.noteWork(working, defaultMinutes: 120, now: now)
            let reached = Self.reference(&expected, working, defaultMinutes: 120, now: now)
            #expect(noted.reached.map(\.slug) == reached)
            #expect(noted.changed == (board != before))
            #expect(notes == noted.changed)
            #expect(board == expected)
            if !reached.isEmpty { told.append((now, reached)) }
            now += 3
        }
        return told
    }

    @Test func aBoardOfThreeHundredTasksCostsWhatItsTwoRunningOnesDo() {
        var small = Self.board(others: 1)
        var large = Self.board(others: 298)
        #expect(large.tasks.count == 300)
        // What noteWork and notesWork copy, change and compare: the running tasks, however long the board.
        #expect(small.budgeted.count == 2)
        #expect(large.budgeted.count == 2)
        #expect(large.budgeted.map { large.tasks[$0].slug } == ["run0", "run1"])
        let others = Array(large.tasks.dropFirst(2))
        let toldSmall = Self.look(&small, for: 10 * 60)
        let toldLarge = Self.look(&large, for: 10 * 60)
        // The same budgets told at the same looks, the same time counted; the tasks that don't run untouched.
        #expect(toldLarge.map(\.at) == toldSmall.map(\.at))
        #expect(toldLarge.map(\.slugs) == [["run0"], ["run1"]], "\(toldLarge)")
        let counted = { (board: LeadBoard) in board.tasks.prefix(2).map { [$0.worked, $0.workedAt, $0.overBudget?.at] } }
        #expect(counted(large) == counted(small))
        #expect(Array(large.tasks.dropFirst(2)) == others)
        #expect(large.budgeted.count == 2)
    }

    @Test func aTaskThatStoppedRunningMidCountIsClearedOnceThenLeftAlone() {
        var board = Self.board(others: 298)
        // Moved to review between two looks, its count's start still on it.
        board.tasks[150].workedAt = LeadBudgetTests.t0 - 30
        #expect(board.budgeted.count == 3)
        Self.look(&board, for: 60)
        #expect(board.tasks[150].workedAt == nil)
        #expect(board.budgeted.count == 2)
    }
}
