import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The Team view's lanes: where each task is now, from the board and what its sessions are doing.
struct LeadLanesTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func task(_ slug: String, _ status: LeadTask.Status, title: String? = nil, since: TimeInterval = 42 * 60, created: Double = 0) -> LeadTask {
        var task = LeadTask(id: slug, slug: slug, title: title ?? slug, contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""),
                            status: status)
        task.createdAt = now.timeIntervalSince1970 - 10_000 + created
        task.since = now.timeIntervalSince1970 - since
        task.worktree = "/r/.vibeswitcher/worktrees/\(slug)"
        if status != .planned {
            task.worker = "w-\(slug)"
            task.attempts = 1
            task.startedAt = task.createdAt + 1
        }
        return task
    }

    static let working = LaneSeen(live: true, needsYou: false, working: true, activity: "Running swift test", detail: nil, since: now - 30)
    static let idle = LaneSeen(live: true, needsYou: false, working: false, activity: nil, detail: nil, since: now - 30)
    static let ended = LaneSeen(live: false, needsYou: false, working: false, activity: nil, detail: nil, since: now - 30)

    func lane(_ task: LeadTask, _ seen: [String: LaneSeen] = [:]) -> LeadLane { LeadLanes.lane(task, queued: nil, seen: seen) }

    @Test func aRunningTaskIsLiveInWork() {
        var task = Self.task("fix", .running)
        task.checkpoints = [LeadCheckpoint(text: "Parser done", at: Self.now.timeIntervalSince1970 - 300)]
        let lane = lane(task, ["w-fix": Self.working])
        #expect(lane.nodes == [.done, .live, .todo, .todo])
        #expect(lane.group == .live)
        #expect(lane.stateText(now: Self.now) == "Work 42m")
        #expect(lane.checkpoint?.text == "Parser done")
        #expect(lane.activity == "Running swift test")
        #expect(lane.problem == nil && !lane.isRed)
        // Between turns: no live activity, the checkpoint stays.
        #expect(self.lane(task, ["w-fix": Self.idle]).activity == nil)
    }

    @Test func aReworkedTaskSaysWhichRoundAndWhy() {
        var task = Self.task("fix", .running, since: 12 * 60)
        task.attempts = 3
        task.setback = LeadSetback(stage: .review, reason: "The test still fails")
        let lane = lane(task, ["w-fix": Self.working])
        #expect(lane.nodes == [.done, .live, .todo, .todo])
        #expect(lane.stateText(now: Self.now) == "Rework 2 · Work 12m")
        #expect(lane.problem == "The test still fails")
        #expect(!lane.isRed)
    }

    @Test func aFailedTaskWhoseWorkerIsWorkingAgainIsInWorkNotRed() {
        // Resumed without the lead (the user told it): the board still says failed.
        var task = Self.task("fix", .failed, since: 12 * 60)
        task.setback = LeadSetback(stage: .review, reason: "The test still fails")
        let lane = lane(task, ["w-fix": Self.working])
        #expect(lane.nodes == [.done, .live, .todo, .todo])
        #expect(lane.group == .live)
        #expect(lane.stateText(now: Self.now) == "Rework 1 · Work 12m")
        #expect(lane.problem == "The test still fails")
        #expect(!lane.isRed)
    }

    @Test func aFailedTaskWithNoLiveWorkerIsRedWhereItFailed() {
        var task = Self.task("fix", .failed, since: 4 * 60)
        task.setback = LeadSetback(stage: .review, reason: "Tests were deleted")
        for seen in [Self.idle, Self.ended] {
            let lane = lane(task, ["w-fix": seen])
            #expect(lane.nodes == [.done, .done, .failed, .todo])
            #expect(lane.group == .needsYou)
            #expect(lane.stateText(now: Self.now) == "Failed 4m")
            #expect(lane.problem == "Tests were deleted")
        }
        task.setback = LeadSetback(stage: .merge, reason: "Conflicts with main")
        #expect(lane(task).nodes == [.done, .done, .done, .failed])
    }

    @Test func aSessionWaitingOnYouIsRed() {
        let asking = LaneSeen(live: true, needsYou: true, working: false, activity: nil, detail: "Which database?", since: Self.now - 120)
        let lane = lane(Self.task("fix", .running), ["w-fix": asking])
        #expect(lane.nodes == [.done, .failed, .todo, .todo])
        #expect(lane.group == .needsYou)
        #expect(lane.stateText(now: Self.now) == "Needs you 2m")
        #expect(lane.problem == "Which database?")
    }

    @Test func aBlockedTaskSaysWhy() {
        var task = Self.task("fix", .blocked)
        task.blocker = "Need the API key"
        let lane = lane(task, ["w-fix": Self.idle])
        #expect(lane.nodes == [.done, .failed, .todo, .todo])
        #expect(lane.state == "Blocked")
        #expect(lane.problem == "Need the API key")
    }

    @Test func aWorkerThatEndedWithoutReportingIsRed() {
        let lane = lane(Self.task("fix", .running), ["w-fix": Self.ended])
        #expect(lane.nodes == [.done, .failed, .todo, .todo])
        #expect(lane.problem == "The worker ended without reporting.")
        // Not known (not in the list): no alarm.
        #expect(!self.lane(Self.task("fix", .running)).isRed)
    }

    @Test func reviewFollowsTheVerifier() {
        var task = Self.task("fix", .review, since: 4 * 60)
        #expect(lane(task).activity == "Waiting for the audit")
        task.verifier = "v-fix"
        let verifier = LaneSeen(live: true, needsYou: false, working: true, activity: "Reading the diff", detail: nil, since: Self.now)
        let checking = lane(task, ["v-fix": verifier])
        #expect(checking.nodes == [.done, .done, .live, .todo])
        #expect(checking.group == .review)
        #expect(checking.stateText(now: Self.now) == "Review 4m")
        #expect(checking.activity == "Reading the diff")
        #expect(checking.session(for: .review) == "v-fix")
        #expect(checking.session(for: .work) == "w-fix")
        #expect(lane(task, ["v-fix": Self.ended]).problem == "The verifier ended without a verdict.")
        task.evidence = LeadEvidence(completion: .complete, integrity: .clean, summary: "ok")
        let passed = lane(task, ["v-fix": Self.ended])
        #expect(passed.nodes == [.done, .done, .done, .live])
        #expect(passed.state == "Merge")
    }

    @Test func mergedAndQueuedShowNoClock() {
        var merged = Self.task("fix", .done)
        merged.worktree = nil
        let lane = lane(merged)
        #expect(lane.nodes == [.done, .done, .done, .done])
        #expect(lane.stateText(now: Self.now) == "Merged ✓")
        #expect(lane.group == .finished)
        let queued = LeadLanes.lane(Self.task("next", .planned), queued: 1, seen: [:])
        #expect(queued.nodes == [.done, .todo, .todo, .todo])
        #expect(queued.stateText(now: Self.now) == "Queued #1")
        var abandoned = Self.task("gone", .failed)
        abandoned.worktree = nil
        #expect(self.lane(abandoned).state == "Abandoned")
        #expect(LaneList.finishedTitle([lane, self.lane(abandoned)]) == "Merged (1) · Abandoned (1)")
    }

    @Test func lanesAreOrderedNeedsYouLiveReviewQueuedFinished() {
        var board = LeadBoard()
        var merged = Self.task("merged", .done)
        merged.worktree = nil
        var failed = Self.task("failed", .failed)
        failed.setback = LeadSetback(stage: .review, reason: "no")
        board.tasks = [merged, Self.task("queued-b", .planned, created: 20), Self.task("review", .review), Self.task("queued-a", .planned, created: 10),
                       Self.task("running", .running), failed]
        let lanes = LeadLanes.lanes(board, seen: ["w-running": Self.working])
        #expect(lanes.map(\.task.slug) == ["failed", "running", "review", "queued-a", "queued-b", "merged"])
        // Queued in the order they'll start.
        #expect(lanes.filter { $0.group == .queued }.map(\.state) == ["Queued #1", "Queued #2"])
        // The lead row's summary counts the board's tasks, not its sessions.
        #expect(LeadLanes.summary(lanes) == "team: 1 needs you · 1 working · 1 in review · 2 queued")
        #expect(LeadLanes.summary([]) == "team: none running")
    }

    @Test func voiceOverReadsTheLane() {
        var task = Self.task("fix", .running, title: "Pipeline lanes in the Team view")
        task.checkpoints = [LeadCheckpoint(text: "View model done", at: Self.now.timeIntervalSince1970)]
        #expect(lane(task).spoken(now: Self.now) == "Pipeline lanes in the Team view: Work, 42 minutes, View model done")
        var merged = Self.task("m", .done, title: "Menus")
        merged.since = nil
        #expect(lane(merged).spoken(now: Self.now).hasPrefix("Menus: Merged"))
    }

    @Test func reduceMotionStillsTheRing() {
        #expect(LeadLanes.liveRing(reduceMotion: false) == .pulsing)
        #expect(LeadLanes.liveRing(reduceMotion: true) == .still)
    }

    @Test func windowRowsSayWhatTheSessionsDo() {
        let id = UUID()
        let hosted = HostSession(id: id, tty: "ttys0", childPID: 1, cwd: "/r/.vibeswitcher/worktrees/fix", command: "claude", label: "Worker: Fix",
                                 agent: "claude", title: "Worker: Fix", startedAt: Self.now - 10, cols: 120, rows: 40, exit: nil)
        let seen = LeadLanes.seen([WindowRow(content: .hosted(hosted), project: "fix")], now: Self.now)
        // Started, its agent not shown up yet: being briefed, not idle.
        #expect(seen[id.uuidString]?.live == true)
        #expect(seen[id.uuidString]?.working == true)
        #expect(seen[id.uuidString]?.activity == "Starting…")
    }

    @Test func endedSessionsOfFinishedTasksAreHistory() {
        func row(_ slug: String, exit: Bool) -> WindowRow {
            let info = HostSession(id: UUID(), tty: "ttys0", childPID: 1, cwd: "/r/.vibeswitcher/worktrees/\(slug)", command: "claude", label: "Worker: \(slug)",
                                   agent: "claude", title: slug, startedAt: Self.now - 10, cols: 120, rows: 40,
                                   exit: exit ? HostSession.Exit(status: 129, at: Self.now - 5) : nil)
            return WindowRow(content: .hosted(info), project: slug)
        }
        var board = LeadBoard()
        var merged = Self.task("merged", .done)
        merged.worktree = nil
        board.tasks = [merged, Self.task("running", .running)]
        let boards = ["/r": board]
        #expect(LeadLanes.isHistory(row("merged", exit: true), boards: boards, now: Self.now))
        #expect(!LeadLanes.isHistory(row("running", exit: true), boards: boards, now: Self.now))
        #expect(!LeadLanes.isHistory(row("merged", exit: false), boards: boards, now: Self.now))
    }
}
