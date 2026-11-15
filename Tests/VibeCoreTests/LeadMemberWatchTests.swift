import Foundation
import Testing
@testable import VibeCore

/// The witness watches each live member of a team task, not only its integrator (the task's worker): a member that sits
/// idle or stops without saying its part is done is told to the lead by name; not inside a wait on a teammate's answer
/// (`LeadTeamMember.waits`), nor once its part is done. A plain task is told as before. The clock is the `now` passed in.
struct LeadMemberWatchTests {
    static let now = Date(timeIntervalSince1970: 2_000_000_000)
    static var at: Double { now.timeIntervalSince1970 }

    /// A running team task: core (the integrator, worker "w1"), ui (worker "m2") and docs (worker "m3").
    static func task() throws -> LeadTask {
        var task = LeadTask(slug: "build-it", title: "Build it", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        task.status = .running
        task.worker = "w1"
        task.team = try LeadTeam.make(slug: "build-it", root: "/repo", parts: [("core", "types"), ("ui", "views"), ("docs", "docs")])
        for (index, worker) in ["w1", "m2", "m3"].enumerated() { task.team?[index].worker = worker }
        return task
    }

    /// At work a minute ago: nothing to tell.
    static let busy = LeadWitness.Seen(live: true, status: .working, activity: .working(nil), lastActivity: at - 60,
                                       shells: [], backgroundTasks: [], shellsRead: true, sleep: MacSleepLog())
    /// Between turns for 15 min, its turn over since then: idle past `LeadStall.idleAfter`, and stopped.
    static let idle = LeadWitness.Seen(live: true, status: .idle, since: now.addingTimeInterval(-15 * 60), activity: .idle(background: nil),
                                       lastActivity: at - 15 * 60, shells: [], backgroundTasks: [], shellsRead: true, sleep: MacSleepLog())

    static func events(_ task: LeadTask, _ seen: [String: LeadWitness.Seen], now: Date = now) -> [(key: String, text: String)] {
        var board = LeadBoard()
        board.tasks = [task]
        return LeadWitness.events(board: board, seen: seen, now: now)
    }

    @Test func anIdleMemberIsFlaggedByTheStallRulesNamingIt() throws {
        let task = try Self.task()
        let told = Self.events(task, ["w1": Self.busy, "m2": Self.idle, "m3": Self.busy])
        let stall = try #require(told.first { $0.key == "m2|stalled-\(Int(Self.at - 15 * 60))" })
        #expect(stall.text.hasPrefix("Member ui of build-it's team is stalled: it's between turns without having reported"), "\(stall.text)")
        #expect(stall.text.hasSuffix("Tell it what to do next with message(build-it, …, member: ui)."), "\(stall.text)")
        // Its turn over 15 min without part done: told it stopped, once (its key), by name.
        let stopped = try #require(told.first { $0.key.hasPrefix("m2|stopped-") })
        #expect(stopped.text == "Member ui of build-it's team stopped without saying its part is done. Ask it where it is with message(build-it, …, member: ui).")
        // Nothing of the busy integrator nor docs; nothing typed into anyone (events are the lead's).
        #expect(told.count == 2, "\(told)")
        // The same stall rule as the integrator's (`LeadStall.detect`), nothing else.
        #expect(LeadStall.detect(Self.idle, task: task, now: Self.now).map(\.reason) == [.idle])
    }

    @Test func aMemberInsideItsPeerWaitDeadlineIsntFlaggedAndIsAfterIt() throws {
        var task = try Self.task()
        task.team?[1].waits = [LeadPeerWait(post: 2, on: "@core", until: Self.at + 5 * 60)]
        let seen = ["w1": Self.busy, "m2": Self.idle, "m3": Self.busy]
        #expect(Self.events(task, seen).isEmpty, "\(Self.events(task, seen))")
        // Past it: the usual rules, from its last activity.
        let after = Self.now.addingTimeInterval(5 * 60)
        let told = Self.events(task, seen, now: after).map(\.text)
        #expect(told.contains { $0.hasPrefix("Member ui of build-it's team is stalled") }, "\(told)")
        #expect(told.contains { $0.hasPrefix("Member ui of build-it's team stopped without saying its part is done") }, "\(told)")
    }

    @Test func aMemberWhosePartIsDoneIsntFlagged() throws {
        let seen = ["w1": Self.busy, "m2": Self.idle, "m3": Self.busy]
        // By part_done (its handoff)…
        var task = try Self.task()
        task.team?[1].handoff = LeadPartHandoff(commit: "abc", changed: "views", caveats: "none", verify: "test", at: Self.at - 20 * 60)
        #expect(Self.events(task, seen).isEmpty)
        // …or a progress of its that says so.
        task = try Self.task()
        task.checkpoints = [LeadCheckpoint(text: "ui: part done, the views pass their tests", at: Self.at - 20 * 60)]
        #expect(Self.events(task, seen).isEmpty)
        // docs's part isn't done: it's told.
        #expect(Self.events(task, ["w1": Self.busy, "m2": Self.idle, "m3": Self.idle]).allSatisfy { $0.text.hasPrefix("Member docs of build-it's team") })
    }

    @Test func aMemberWaitingForInputOrStalledSilentIsToldByName() throws {
        let task = try Self.task()
        var input = Self.idle
        input.status = .needsInput
        input.activity = nil
        input.detail = "Run: ls"
        let silent = LeadWitness.Seen(live: true, status: .working, activity: .working(nil), lastActivity: Self.at - 20 * 60,
                                      shells: [], backgroundTasks: [], shellsRead: true, sleep: MacSleepLog())
        let told = Self.events(task, ["w1": Self.busy, "m2": input, "m3": silent])
        #expect(told.contains { $0.key.hasPrefix("m2|input-") && $0.text.hasPrefix("Member ui of build-it's team is waiting for input") && $0.text.contains("member: ui") }, "\(told)")
        #expect(told.contains { $0.key.hasPrefix("m3|stalled-") && $0.text.hasPrefix("Member docs of build-it's team is stalled: it reads as working")
                && $0.text.contains("message(build-it, …, member: docs)") }, "\(told)")
    }

    /// A member is watched while its members are at work (`LeadTask.deadlinesRun`) and its session lives: one whose
    /// session ended is `endedMembers`' to tell.
    @Test func aMemberIsWatchedWhileTheTeamIsAtWorkAndItLives() throws {
        var task = try Self.task()
        var gone = Self.idle
        gone.live = false
        #expect(Self.events(task, ["w1": Self.busy, "m2": gone]).isEmpty)
        // Blocked on the lead (its integrator reported blocked), its members still at work: watched as when running.
        task.status = .blocked
        let told = Self.events(task, ["w1": Self.busy, "m2": Self.idle]).map(\.text)
        #expect(told.contains { $0.hasPrefix("Member ui of build-it's team is stalled") }, "\(told)")
        #expect(told.contains { $0.hasPrefix("Member ui of build-it's team stopped without saying its part is done") }, "\(told)")
        // Stopped by the lead (stop_worker ends its members too), or under audit: not.
        task.stopped = "w1"
        #expect(!Self.events(task, ["m2": Self.idle]).contains { $0.text.hasPrefix("Member") })
        task.stopped = nil
        task.status = .review
        #expect(!Self.events(task, ["m2": Self.idle]).contains { $0.text.hasPrefix("Member") })
    }

    /// A member whose agent quit, its shell left open, still counts as live (so `endedMembers` passes it over and
    /// start_worker won't start it again): it's told here, once, by name.
    @Test func aMemberWhoseAgentQuitIsToldEnded() throws {
        let task = try Self.task()
        var quit = Self.idle
        quit.agentQuit = true
        let told = Self.events(task, ["w1": Self.busy, "m2": quit, "m3": Self.busy])
        #expect(told.map(\.key) == ["m2|ended"], "\(told)")
        #expect(told.first?.text.hasPrefix("Member ui of build-it's team ended without saying its part is done: its agent quit and left the session's shell open.") == true, "\(told)")
        #expect(told.first?.text.contains("start_worker(build-it)") == true)
        // Not once its part is done.
        var done = task
        done.team?[1].handoff = LeadPartHandoff(commit: "abc", changed: "views", caveats: "none", verify: "test", at: Self.at - 20 * 60)
        #expect(Self.events(done, ["w1": Self.busy, "m2": quit, "m3": Self.busy]).isEmpty)
    }

    @Test func aPlainTaskIsToldAsBefore() throws {
        var task = try Self.task()
        task.team = nil
        #expect(task.watched == task.members && task.memberSessions.isEmpty)
        let told = Self.events(task, ["w1": Self.idle, "m2": Self.idle])
        #expect(told.map(\.key).sorted() == ["w1|stalled-\(Int(Self.at - 15 * 60))", "w1|stopped-\(Int(Self.at - 15 * 60))"], "\(told)")
        #expect(told.allSatisfy { $0.text.hasPrefix("The worker on build-it") })
    }

    /// What the witness watches for a team task: its worker, verifier and finders, and each other member's worker.
    @Test func theWatchedSessionsAreTheRolesAndEachMembersWorker() throws {
        var task = try Self.task()
        task.verifier = "v1"
        #expect(task.memberSessions.map(\.member.name) == ["ui", "docs"])
        #expect(task.watched == ["w1", "v1", "m2", "m3"])
        task.team?[2].worker = nil
        #expect(task.watched == ["w1", "v1", "m2"])
    }

    /// The Team view's "waiting on @x" comes from the board's waits, only while their deadline runs.
    @Test func waitingOnReadsTheWaitsWhoseDeadlineRuns() throws {
        var task = try Self.task()
        task.team?[1].waits = [LeadPeerWait(post: 2, on: "@core @docs", until: Self.at + 60), LeadPeerWait(post: 4, on: "@all", until: Self.at + 120),
                               LeadPeerWait(post: 1, on: "@docs", until: Self.at - 1)]
        #expect(task.waitingOn(member: "ui", now: Self.at) == ["core", "docs", "all"])
        #expect(task.waitingOn(member: "ui", now: Self.at + 60) == ["all"])
        #expect(task.waitingOn(member: "ui", now: Self.at + 120).isEmpty)
        #expect(task.waitingOn(member: "docs", now: Self.at).isEmpty)
    }
}
