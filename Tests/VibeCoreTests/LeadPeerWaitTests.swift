import Foundation
import Testing
@testable import VibeCore

/// No member waits on a teammate without a limit (docs/process/reviews/team-on-one-task-design.md, section 4; T9): a
/// `needs_answer` post carries a deadline (10 min by default, 20 at most); past it with no reply, the asker and the
/// lead are told once; meanwhile the asker shows as "waiting on @x" and isn't a `LeadStall`. With T5's two gaps: a
/// member whose session ended is told to the lead once, and the lead's message reaches one member. The lead's clock
/// (`usageClock`) and its look again (`usageWake`) are injected: nothing waits on the wall clock.
struct LeadPeerWaitTests {
    let fixture = LeadWallToolsTests()

    /// The looks again the lead armed (`usageWake`), not run.
    final class Wakes: @unchecked Sendable {
        private let lock = NSLock()
        private var dates: [Date] = []
        func add(_ date: Date) { lock.withLock { dates.append(date) } }
        var all: [Date] { lock.withLock { dates } }
    }

    func team(_ wakes: Wakes = Wakes()) throws -> LeadWallToolsTests.Team {
        let team = try fixture.team()
        team.lead.usageWake = { date, _ in wakes.add(date) }
        return team
    }

    func at(_ team: LeadWallToolsTests.Team, _ seconds: Double) {
        team.lead.usageClock = { Date(timeIntervalSince1970: seconds) }
    }

    /// What the asker got from VibeSwitcher about its question's deadline.
    func deadlineNotices(_ team: LeadWallToolsTests.Team, to session: String) -> [String] {
        team.runtime.steered.filter { $0.target == session && $0.text.hasPrefix("No answer from") }.map(\.text)
    }

    /// What the lead was told of a member's question's deadline (on the board, whether or not a lead runs).
    func leadNotices(_ team: LeadWallToolsTests.Team) -> [String] {
        (BoardStore(root: team.root).load().reports ?? []).map(\.text).filter { $0.contains("got no answer from") }
    }

    func question(_ team: LeadWallToolsTests.Team, _ id: Int = 1) throws -> LeadWall.Post {
        try #require(try team.lead.wallStore("build-it").posts().first { $0.id == id })
    }

    @Test func aQuestionsDeadlineIsToldToTheAskerAndTheLeadOnceAtIt() throws {
        let wakes = Wakes()
        let team = try team(wakes)
        let posted = fixture.post(team.docs, "Is Style public?", to: ["@ui"], needsAnswer: true)
        #expect(posted.text.contains("If no one replies within 10 min"), "\(posted.text)")
        let asked = try question(team)
        let until = try #require(asked.answerBy)
        #expect(until == asked.at + LeadWall.answerWait)
        #expect(fixture.task(team)?.teamMember("docs")?.waits == [LeadPeerWait(post: 1, on: "@ui", until: until)])

        // A second before it: nothing told; a look again is armed for just after it.
        at(team, until - 1)
        team.lead.deliverWalls()
        #expect(deadlineNotices(team, to: "session-3").isEmpty && leadNotices(team).isEmpty)
        #expect(wakes.all == [Date(timeIntervalSince1970: until + 1)])
        // Armed once, however many passes look.
        team.lead.deliverWalls()
        #expect(wakes.all.count == 1)

        // At it: the asker once, the lead once, and its wait is over.
        at(team, until)
        team.lead.deliverWalls()
        team.lead.deliverWalls()
        team.lead.deliverWalls()
        let told = deadlineNotices(team, to: "session-3")
        #expect(told.count == 1, "\(told)")
        #expect(told.first?.contains("No answer from @ui to your wall post #1") == true)
        #expect(told.first?.contains("go on with a stated assumption (post it") == true && told.first?.contains("ask_lead") == true)
        let lead = leadNotices(team)
        #expect(lead.count == 1 && lead.first?.contains("Member docs of build-it's team got no answer from @ui to its wall post #1") == true, "\(lead)")
        #expect(fixture.task(team)?.teamMember("docs")?.waits == nil)
        // Nobody else was told.
        #expect(team.runtime.steered.filter { $0.text.hasPrefix("No answer from") }.count == 1)
        // The lead's copy is the loop's, which the lead's own server may seal (blind check): a worker's ("worker
        // build-it") is sealed only from that worker's server, and reached the lead as an unverified sender's.
        #expect(team.runtime.steered.filter { $0.text.contains("got no answer from") }.map(\.sender) == [.system(LeadAdvance.sender)])
        #expect((BoardStore(root: team.root).load().reports ?? []).filter { $0.text.contains("got no answer from") }.map(\.about) == [LeadAdvance.sender])
    }

    /// The lead is told whether the asker was reached: an asker whose session ended, a delivery that failed, or a host
    /// that couldn't be read isn't said to be told, and the lead hears how to reach it (audit F1).
    @Test func theLeadHearsWhenTheAskerWasntReachedAtItsDeadline() throws {
        enum Way { case ended, refused, hostDown }
        for way in [Way.ended, .refused, .hostDown] {
            let team = try team()
            fixture.post(team.docs, "Is Style public?", to: ["@ui"], needsAnswer: true)
            let until = try #require(try question(team).answerBy)
            switch way {
            case .ended: try team.runtime.kill("session-3")
            case .refused: team.runtime.onSteer = { _, _, _ in throw BoardError(text: "the inbox can't be written") }
            case .hostDown: team.runtime.hostDown = "the host isn't up"
            }
            at(team, until)
            team.lead.deliverWalls()
            let lead = leadNotices(team)
            #expect(lead.count == 1, "\(way): \(lead)")
            #expect(lead.first?.contains("It was told to go on") == false, "\(way): \(lead)")
            #expect(lead.first?.contains("It wasn't told") == true && lead.first?.contains("message(build-it, member: docs)") == true, "\(way): \(lead)")
            // Once, as ever.
            team.runtime.hostDown = nil
            team.lead.deliverWalls()
            #expect(leadNotices(team).count == 1, "\(way)")
        }
        // Reached: told so.
        let team = try team()
        fixture.post(team.docs, "Is Style public?", to: ["@ui"], needsAnswer: true)
        at(team, try #require(try question(team).answerBy))
        team.lead.deliverWalls()
        #expect(leadNotices(team).first?.contains("It was told to go on with a stated assumption") == true, "\(leadNotices(team))")
    }

    /// Every pass of the lead's loop looks at the deadlines, and a write of the board starts another pass: a look with
    /// none due writes nothing (blind check).
    @Test func aLookWithNoDeadlineDueDoesntWriteTheBoard() throws {
        let team = try team()
        fixture.post(team.docs, "Is Style public?", to: ["@ui"], needsAnswer: true)
        let until = try #require(try question(team).answerBy)
        at(team, until - 1)
        team.lead.deliverWalls()
        let file = (BoardStore(root: team.root).folder as NSString).appendingPathComponent("board.json")
        let before = try FileManager.default.attributesOfItem(atPath: file)[.systemFileNumber] as? Int
        team.lead.peerDeadlines("build-it")
        team.lead.tellEndedMembers()
        let after = try FileManager.default.attributesOfItem(atPath: file)[.systemFileNumber] as? Int
        #expect(before != nil && before == after)
    }

    @Test func aReplyBeforeTheDeadlineSendsNeither() throws {
        let team = try team()
        fixture.post(team.docs, "Is Style public?", to: ["@ui", "@core"], needsAnswer: true)
        let until = try #require(try question(team).answerBy)
        // The asker's own follow-up isn't an answer: it still waits.
        fixture.post(team.docs, "(I mean the type, not the file.)", to: ["@ui"], replyTo: 1)
        #expect(fixture.task(team)?.teamMember("docs")?.waits?.map(\.post) == [1])
        // A teammate's reply closes it.
        fixture.post(team.ui, "Yes, public.", to: ["@docs"], replyTo: 1)
        #expect(fixture.task(team)?.teamMember("docs")?.waits == nil)
        at(team, until + 60)
        team.lead.deliverWalls()
        team.lead.deliverWalls()
        #expect(deadlineNotices(team, to: "session-3").isEmpty)
        #expect(leadNotices(team).isEmpty)
    }

    /// A task that left running (its integrator reported done and it's under audit, or it's done or stopped) has its
    /// questions' waits dropped, unsaid: a deadline typed into a worker under audit would start a turn on the audited
    /// branch, and the lead would hear of a finished task (blind check).
    @Test func aTaskThatLeftRunningTellsNoDeadline() throws {
        let wakes = Wakes()
        let team = try team(wakes)
        fixture.post(team.docs, "Is Style public?", to: ["@ui"], needsAnswer: true)
        let until = try #require(try question(team).answerBy)
        try BoardStore(root: team.root).update { board in
            if let index = board.taskIndex("build-it") { board.tasks[index].status = .review }
        }
        at(team, until - 1)
        team.lead.deliverWalls()
        #expect(wakes.all.isEmpty, "\(wakes.all)")
        at(team, until + 60)
        team.lead.deliverWalls()
        #expect(deadlineNotices(team, to: "session-3").isEmpty)
        #expect(leadNotices(team).isEmpty, "\(leadNotices(team))")
        #expect(fixture.task(team)?.team?.allSatisfy { $0.waits == nil } == true)
    }

    /// A task blocked on the lead (its integrator reported blocked or over_budget) keeps its members at work, and the
    /// wall flowing: their deadlines run on, told at them, and they show as waiting. One the lead stopped (stop_worker
    /// ends its members too) has them dropped unsaid (audit F6).
    @Test func aTaskBlockedOnTheLeadStillTellsItsDeadlinesUnlessStopped() throws {
        for stopped in [false, true] {
            let wakes = Wakes()
            let team = try team(wakes)
            fixture.post(team.docs, "Is Style public?", to: ["@ui"], needsAnswer: true)
            let until = try #require(try question(team).answerBy)
            try BoardStore(root: team.root).update { board in
                guard let index = board.taskIndex("build-it") else { return }
                board.tasks[index].status = .blocked
                if stopped { board.tasks[index].stopped = board.tasks[index].worker }
            }
            at(team, until - 1)
            team.lead.deliverWalls()
            let status = team.lead.call("status", [:]).text
            #expect(status.contains("build-it docs: waiting on @ui") != stopped, "stopped \(stopped): \(status)")
            #expect(wakes.all == (stopped ? [] : [Date(timeIntervalSince1970: until + 1)]), "stopped \(stopped): \(wakes.all)")
            at(team, until)
            team.lead.deliverWalls()
            team.lead.deliverWalls()
            #expect(deadlineNotices(team, to: "session-3").count == (stopped ? 0 : 1), "stopped \(stopped)")
            #expect(leadNotices(team).count == (stopped ? 0 : 1), "stopped \(stopped): \(leadNotices(team))")
            #expect(fixture.task(team)?.team?.allSatisfy { $0.waits == nil } == true)
        }
    }

    @Test func aDeadlineOverTwentyMinutesIsCapped() throws {
        #expect(LeadWall.wait(minutes: nil) == 600 && LeadWall.wait(minutes: 0) == 600 && LeadWall.wait(minutes: .nan) == 600)
        #expect(LeadWall.wait(minutes: 5) == 300 && LeadWall.wait(minutes: 20) == 1200 && LeadWall.wait(minutes: 45) == 1200)
        let team = try team()
        let long = team.docs.call("post", ["text": "Big question?", "to": ["@ui"], "needs_answer": true, "deadline_min": 45])
        #expect(!long.isError && long.text.contains("within 20 min"), "\(long.text)")
        let short = team.ui.call("post", ["text": "Small question?", "to": ["@docs"], "needs_answer": true, "deadline_min": 5])
        #expect(!short.isError && short.text.contains("within 5 min"), "\(short.text)")
        let first = try question(team, 1), second = try question(team, 2)
        #expect(first.answerBy == first.at + 1200 && second.answerBy == second.at + 300)
        #expect(fixture.task(team)?.teamMember("docs")?.waits?.first?.until == first.at + 1200)
        // A line written into the wall's file by hand can't ask for longer either.
        var forged = first
        forged.deadline = first.at + 3600
        #expect(forged.answerBy == first.at + 1200)
        // Told at the cap, not at what it asked for.
        at(team, first.at + 1200)
        team.lead.deliverWalls()
        #expect(deadlineNotices(team, to: "session-3").count == 1)
        #expect(deadlineNotices(team, to: "session-3").first?.contains("within its 20 min") == true)
    }

    @Test func statusAndBoardShowTheMemberWaitingWhileItsDeadlineRuns() throws {
        let team = try team()
        fixture.post(team.docs, "Is Style public?", to: ["@ui"], needsAnswer: true)
        let until = try #require(try question(team).answerBy)
        at(team, until - 7 * 60)
        let status = team.lead.call("status", [:]).text
        #expect(status.contains("Waiting on a teammate's answer, within its deadline, not stalled (1):"), "\(status)")
        #expect(status.contains("- build-it docs: waiting on @ui (an answer to wall post #1; 7 min left of its deadline)"), "\(status)")
        let board = team.lead.call("board", ["task": "build-it"]).text
        #expect(board.contains("- docs: waiting on @ui (an answer to wall post #1; 7 min left of its deadline)"), "\(board)")
        // Past it: no longer shown as waiting (the usual rules apply).
        at(team, until)
        #expect(!team.lead.call("status", [:]).text.contains("waiting on @ui"))
        #expect(!team.lead.call("board", ["task": "build-it"]).text.contains("waiting on @ui"))
    }

    // MARK: LeadStall

    /// A team task whose integrator (its worker, w1) has been idle 15 min, past `LeadStall.idleAfter`.
    static func idleIntegrator(now: Double, waits: [LeadPeerWait]?) throws -> (task: LeadTask, seen: LeadWitness.Seen) {
        var task = LeadTask(slug: "build-it", title: "Build it", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        task.status = .running
        task.worker = "w1"
        task.team = try LeadTeam.make(slug: "build-it", root: "/repo", parts: [("core", "types"), ("ui", "views")])
        task.team?[0].worker = "w1"
        task.team?[0].waits = waits
        let seen = LeadWitness.Seen(live: true, status: .idle, activity: .idle(background: nil), lastActivity: now - 15 * 60,
                                    shells: [], backgroundTasks: [], shellsRead: true, sleep: MacSleepLog())
        return (task, seen)
    }

    @Test func leadStallDoesntFlagAMemberInsideItsDeadlineAndDoesAfterIt() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let at = now.timeIntervalSince1970
        let wait = LeadPeerWait(post: 3, on: "@ui", until: at + 5 * 60)
        let inside = try Self.idleIntegrator(now: at, waits: [wait])
        // Without a wait it's an idle stall: the usual rule.
        #expect(LeadStall.detect(inside.seen, task: inside.task, now: now).map(\.reason) == [.idle])
        // Inside its deadline: not a stall, by LeadStall nor the witness.
        #expect(LeadStall.detect(inside.seen, task: inside.task, now: now, waitingOn: wait).isEmpty)
        #expect(inside.task.peerWait(session: "w1", now: at) == wait)
        var board = LeadBoard()
        board.tasks = [inside.task]
        #expect(LeadWitness.stalls(board: board, seen: ["w1": inside.seen], now: now).isEmpty)
        #expect(!LeadWitness.events(board: board, seen: ["w1": inside.seen], now: now).contains { $0.text.contains("stalled") })
        // After it: the usual rules, from its last activity.
        let after = now.addingTimeInterval(5 * 60)
        #expect(inside.task.peerWait(session: "w1", now: after.timeIntervalSince1970) == nil)
        #expect(LeadStall.detect(inside.seen, task: inside.task, now: after, waitingOn: wait).map(\.reason) == [.idle])
        #expect(LeadWitness.stalls(board: board, seen: ["w1": inside.seen], now: after)[inside.task.id]?.reason == .idle)
        #expect(LeadWitness.events(board: board, seen: ["w1": inside.seen], now: after).contains { $0.text.contains("The worker on build-it is stalled") })
    }

    /// An integrator that ended its turn on a question to a teammate, within its deadline, isn't told to the lead as
    /// "stopped without calling report" either (the wall's reply wakes it); past the deadline it is (blind check).
    @Test func anIntegratorWaitingOnATeammateIsntToldAsStoppedInsideItsDeadline() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let at = now.timeIntervalSince1970
        let wait = LeadPeerWait(post: 3, on: "@ui", until: at + 5 * 60)
        var (task, seen) = try Self.idleIntegrator(now: at, waits: [wait])
        seen.since = now.addingTimeInterval(-15 * 60)
        var board = LeadBoard()
        board.tasks = [task]
        func stopped(_ when: Date) -> Bool {
            LeadWitness.events(board: board, seen: ["w1": seen], now: when).contains { $0.text.contains("stopped without calling report") }
        }
        #expect(!stopped(now))
        #expect(stopped(now.addingTimeInterval(5 * 60)))
        // Without a wait: the usual notice.
        task.team?[0].waits = nil
        board.tasks = [task]
        #expect(stopped(now))
    }

    // MARK: T5's gaps

    @Test func aMemberWhoseSessionEndedIsToldToTheLeadOnce() throws {
        let team = try team()
        func told() -> [String] { (BoardStore(root: team.root).load().reports ?? []).map(\.text).filter { $0.contains("ended (its session is gone)") } }
        team.lead.deliverWalls()
        #expect(told().isEmpty)
        // ui said its part is done; docs didn't. Both end.
        let progress = team.ui.call("progress", ["text": "Part done: the views pass their tests"])
        #expect(!progress.isError, "\(progress.text)")
        try team.runtime.kill("session-2")
        try team.runtime.kill("session-3")
        team.lead.deliverWalls()
        team.lead.deliverWalls()
        #expect(told() == ["Member docs of build-it's team ended (its session is gone) without saying its part is done. auto_advance doesn't start it again: "
                           + "start_worker(build-it) starts it again on agent/build-it--docs, in its worktree, its commits kept."], "\(told())")
        #expect(fixture.task(team)?.teamMember("docs")?.endTold == "session-3")
        #expect(team.runtime.steered.filter { $0.text.contains("ended (its session is gone)") }.map(\.sender) == [.system(LeadAdvance.sender)])
        // The pure rule: a part done, the integrator, a task not running, or one told already is never found.
        let board = BoardStore(root: team.root).load()
        #expect(LeadWitness.endedMembers(board: board, live: []).isEmpty)
        #expect(LeadWitness.endedMembers(board: board, live: ["session-1"]).isEmpty)
        var fresh = board
        fresh.tasks[0].team?[2].endTold = nil
        #expect(LeadWitness.endedMembers(board: fresh, live: ["session-1"]).map(\.member) == ["docs"])
        // A member that reported part_done (its handoff) isn't found, though its lane's checkpoint aged out.
        var reported = fresh
        reported.tasks[0].checkpoints = []
        reported.tasks[0].team?[2].handoff = LeadPartHandoff(commit: "abc", changed: "docs", caveats: "none", verify: "test", at: 0)
        #expect(LeadWitness.endedMembers(board: reported, live: ["session-1"]).map(\.member) == ["ui"])
        // Its integrator ended too (stop_worker ends it first): that's told as the task's worker's end, not a member's.
        #expect(LeadWitness.endedMembers(board: fresh, live: []).isEmpty)
        fresh.tasks[0].status = .review
        #expect(LeadWitness.endedMembers(board: fresh, live: ["session-1"]).isEmpty)
    }

    @Test func theLeadsMessageReachesOneMemberAsTheLeadsSealedNote() throws {
        let team = try team()
        let sent = team.lead.call("message", ["task": "build-it", "member": "@docs", "text": "Keep the guide to one page."])
        #expect(!sent.isError && sent.text.contains("Sent to build-it's member docs, as yours"), "\(sent.text)")
        let got = team.runtime.steered.filter { $0.text == "Keep the guide to one page." }
        #expect(got.map(\.target) == ["session-3"])
        #expect(got.first?.sender == .lead("lead of \(LeadMail.project(of: team.root))"))
        // Kept as the lead's sealed note, as a message to the integrator is.
        let note = try #require(fixture.task(team)?.notes?.first { $0.text == "Keep the guide to one page." })
        #expect(note.seal != nil)
        #expect(team.lead.leadNotes(try #require(fixture.task(team))).lead.contains { $0.text == "Keep the guide to one page." })
        // A member's ask_lead, answered by the lead's message to that member: the task no longer waits on the lead,
        // so an idle integrator is a stall again (blind check).
        let asked = team.docs.call("ask_lead", ["question": "One page, or two?"])
        #expect(!asked.isError, "\(asked.text)")
        #expect(fixture.task(team)?.leadQuestionAt != nil)
        let answered = team.lead.call("message", ["task": "build-it", "member": "docs", "text": "One."])
        #expect(!answered.isError, "\(answered.text)")
        #expect(fixture.task(team)?.leadQuestionAt == nil)
        // The integrator by name: message as ever.
        #expect(!team.lead.call("message", ["task": "build-it", "member": "core", "text": "To core."]).isError)
        #expect(team.runtime.steered.filter { $0.text.hasPrefix("To core.") }.map(\.target) == ["session-1"])
        // Not a member, or not live: nothing sent.
        let stranger = team.lead.call("message", ["task": "build-it", "member": "nobody", "text": "hi"])
        #expect(stranger.isError && stranger.text.contains("isn't a member of build-it's team"), "\(stranger.text)")
        try team.runtime.kill("session-2")
        let gone = team.lead.call("message", ["task": "build-it", "member": "ui", "text": "hi"])
        #expect(gone.isError && gone.text.contains("has no live worker"), "\(gone.text)")
        #expect(!team.runtime.steered.contains { $0.text == "hi" })
    }
}
