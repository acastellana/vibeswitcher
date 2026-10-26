import Foundation
import Testing
@testable import VibeCore

struct LeadTeamsTests {
    func hosted(_ label: String, cwd: String, project: String) -> WindowRow {
        let info = HostSession(id: UUID(), tty: "ttys9", childPID: 1, cwd: cwd, command: nil, label: label, agent: "claude", title: "",
                               startedAt: Date(), cols: 80, rows: 24, exit: nil)
        return WindowRow(content: .hosted(info), project: project)
    }

    @Test func rolesComeFromTheSessionsLabel() {
        #expect(LeadTeams.role(label: "Lead · acme") == .lead)
        #expect(LeadTeams.role(label: "Worker: Add login") == .worker)
        #expect(LeadTeams.role(label: "Verifier: Add login") == .verifier)
        #expect(LeadTeams.role(label: "Claude") == nil)
        #expect(LeadTeams.root(ofWorktree: "/r/acme/.vibeswitcher/worktrees/add-login") == "/r/acme")
        #expect(LeadTeams.root(ofWorktree: "/r/acme/src") == nil)
    }

    @Test func theTeamFoldsUnderItsLead() {
        let lead = hosted("Lead · acme", cwd: "/r/acme", project: "acme")
        let worker = hosted("Worker: Add login", cwd: "/r/acme/.vibeswitcher/worktrees/add-login", project: "add-login")
        let verifier = hosted("Verifier: Add login", cwd: "/r/acme/.vibeswitcher/worktrees/add-login", project: "add-login")
        let other = hosted("Claude", cwd: "/r/other", project: "other")
        let sections = [WindowSection(project: "add-login", rows: [worker, verifier]), WindowSection(project: "acme", rows: [lead]),
                        WindowSection(project: "other", rows: [other])]
        let folded = LeadTeams.arrange(sections, label: { $0.hosted?.label }, expanded: [])
        #expect(folded.sections.map(\.project) == ["acme", "other"])
        #expect(folded.sections[0].rows.map(\.id) == [lead.id])
        #expect(folded.teams[lead.id]?.map(\.id) == [worker.id, verifier.id])
        let open = LeadTeams.arrange(sections, label: { $0.hosted?.label }, expanded: [lead.id])
        #expect(open.sections[0].rows.map(\.id) == [lead.id, worker.id, verifier.id])
        #expect(open.nested == [worker.id, verifier.id])
    }

    @Test func aTeamWithoutItsLeadStaysVisible() {
        let worker = hosted("Worker: Add login", cwd: "/r/acme/.vibeswitcher/worktrees/add-login", project: "add-login")
        let folded = LeadTeams.arrange([WindowSection(project: "add-login", rows: [worker])], label: { $0.hosted?.label }, expanded: [])
        #expect(folded.sections.flatMap(\.rows).map(\.id) == [worker.id])
    }

    func session(_ label: String, cwd: String, started: Date = Date(), exit: Int32? = nil) -> HostSession {
        HostSession(id: UUID(), tty: "ttys9", childPID: 1, cwd: cwd, command: nil, label: label, agent: "claude", title: "",
                    startedAt: started, cols: 80, rows: 24, exit: exit.map { HostSession.Exit(status: $0, at: Date()) })
    }

    /// A window session's row with no agent in the scan of a process table read at `tableReadAt` (that couldn't tell
    /// what runs on the `undecided` terminals).
    func shellRow(_ info: HostSession, tableReadAt: Date?, undecided: Undecided = Undecided()) -> WindowRow {
        WindowRows.sections(sessions: [], hosted: [info], table: TableRead(at: tableReadAt, undecided: undecided),
                            projectName: { _ in "p" })[0].rows[0]
    }

    func agentRow(_ cwd: String, status: SessionStatus, role: LeadLaunch.Role? = nil) -> WindowRow {
        var session = Session(tty: "ttys\(UUID().uuidString.prefix(4))", agent: .claude, pid: 1, startedAt: Date(), cwd: cwd, project: "p",
                              task: nil, status: status, statusSince: Date(), detail: nil, hasHooks: true, inTerminalApp: false)
        session.hostID = UUID()
        session.teamRole = role
        return WindowRow(content: .agent(session), project: "p")
    }

    func task(_ slug: String, _ status: LeadTask.Status, worktree: String? = "wt") -> LeadTask {
        var task = LeadTask(slug: slug, title: slug, contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""), status: status)
        task.worktree = worktree
        return task
    }

    @Test func theTaskIsTheWorktreesFolder() {
        #expect(LeadTeams.task(ofWorktree: "/r/acme/.vibeswitcher/worktrees/add-login") == "add-login")
        #expect(LeadTeams.task(ofWorktree: "/r/acme/.vibeswitcher/worktrees/add-login/Sources") == "add-login")
        #expect(LeadTeams.task(ofWorktree: "/r/acme") == nil)
    }

    @Test func endedSessionsOfFinishedTasksAreForgotten() {
        var board = LeadBoard()
        board.tasks = [task("merged", .done, worktree: nil), task("abandoned", .failed, worktree: nil), task("merged-not-cleaned", .done),
                       task("died", .failed), task("stopped", .blocked), task("running", .running)]
        let wt = "/r/acme/.vibeswitcher/worktrees/"
        let gone = [session("Worker: Merged", cwd: wt + "merged", exit: 129), session("Verifier: Merged", cwd: wt + "merged", exit: 129),
                    session("Worker: Abandoned", cwd: wt + "abandoned", exit: 129), session("Worker: M", cwd: wt + "merged-not-cleaned", exit: 0)]
        let kept = [session("Worker: Merged", cwd: wt + "merged"),                       // still running
                    session("Worker: Died", cwd: wt + "died", exit: 1),                  // the lead decides what next
                    session("Worker: Stopped", cwd: wt + "stopped", exit: 129),
                    session("Worker: Running", cwd: wt + "running", exit: 129),
                    session("Worker: Unknown", cwd: wt + "not-on-the-board", exit: 129),
                    session("Lead · acme", cwd: "/r/acme", exit: 129),
                    session("Claude", cwd: wt + "merged", exit: 129),                    // not on the team
                    session("Worker: Merged", cwd: "/r/other/.vibeswitcher/worktrees/merged", exit: 129)] // another repository's
        let forgotten = LeadTeams.finished(gone + kept, root: "/r/acme/", board: board)
        #expect(forgotten == gone.map(\.id))
    }

    @Test func aTeamMembersNormalEndIsntAFailure() {
        let wt = "/r/acme/.vibeswitcher/worktrees/one"
        func text(_ exit: Int32) -> String {
            LeadTeams.state(of: WindowRow(content: .hosted(session("Worker: One", cwd: wt, exit: exit)), project: "one"), now: Date()).text
        }
        #expect(text(129) == "ended")
        #expect(text(143) == "ended")
        #expect(text(0) == "finished")
        #expect(text(1) == "exit 1")
    }

    @Test func theSummaryCountsLiveTasksOnly() {
        let now = Date()
        let wt = "/r/acme/.vibeswitcher/worktrees/"
        var labels: [String: String] = [:]
        func member(_ label: String, _ row: WindowRow) -> WindowRow {
            labels[row.id] = label
            return row
        }
        var board = LeadBoard()
        board.tasks = [task("a", .running), task("b", .running), task("c", .review), task("d", .running), task("e", .done)]
        var team = [member("Worker: A", agentRow(wt + "a", status: .working)),
                    member("Worker: B", agentRow(wt + "b", status: .working)),
                    member("Worker: C", agentRow(wt + "c", status: .done)),
                    member("Verifier: C", agentRow(wt + "c", status: .working))]
        // Ended members (and one whose agent quit, leaving its shell) aren't counted.
        for index in 0..<14 {
            team.append(member("Worker: Old", WindowRow(content: .hosted(session("Worker: Old", cwd: wt + "old\(index)", exit: 129)), project: "old")))
        }
        team.append(member("Worker: D", shellRow(session("Worker: D", cwd: wt + "d", started: now - 600), tableReadAt: now)))
        #expect(LeadTeams.summary(team, label: { labels[$0.id] }, board: board, now: now) == "team: 2 working · 1 in review")

        // Waiting on its lead comes first; a merged task's live worker is done; a just-started one is working.
        team.append(member("Worker: E", agentRow(wt + "e", status: .idle)))
        team.append(member("Worker: F", shellRow(session("Worker: F", cwd: wt + "f", started: now - 5), tableReadAt: now)))
        team[0] = member("Worker: A", agentRow(wt + "a", status: .needsInput))
        #expect(LeadTeams.summary(team, label: { labels[$0.id] }, board: board, now: now) == "team: 1 waits on lead · 2 working · 1 in review · 1 done")
        // Without the board, a live verifier still means the task is in review; an idle worker is idle.
        let plain = [member("Worker: G", agentRow(wt + "g", status: .idle)), member("Verifier: H", agentRow(wt + "h", status: .idle))]
        #expect(LeadTeams.summary(plain, label: { labels[$0.id] }, board: nil, now: now) == "team: 1 in review · 1 idle")
        // A live worker with no state to read (its hooks' file gone) isn't counted as idle.
        let unread = [member("Worker: I", agentRow(wt + "i", status: .working)), member("Worker: J", agentRow(wt + "j", status: .unknown))]
        #expect(LeadTeams.summary(unread, label: { labels[$0.id] }, board: nil, now: now) == "team: 1 working · 1 unknown")
        #expect(LeadTeams.summary(Array(team[4..<18]), label: { labels[$0.id] }, board: board, now: now) == "team: none running")
    }

    /// A worker or verifier waiting on input waits on its lead: "needs you" is only ever the user (2026-10-25: a lead's row
    /// said "team: 1 needs you" for a verifier that had ended without a verdict).
    @Test func aMemberWaitingOnInputWaitsOnItsLead() {
        let now = Date()
        let wt = "/r/acme/.vibeswitcher/worktrees/"
        var board = LeadBoard()
        board.tasks = [task("a", .review), task("b", .running), task("c", .running)]
        let verifier = agentRow(wt + "a", status: .needsInput, role: .verifier)
        let labels = [verifier.id: "Verifier: A"]
        #expect(LeadTeams.summary([verifier], label: { labels[$0.id] }, board: board, now: now) == "team: 1 waits on lead")
        let two = [verifier, agentRow(wt + "b", status: .needsInput, role: .worker), agentRow(wt + "c", status: .working, role: .worker)]
        #expect(LeadTeams.summary(two, label: { labels[$0.id] }, board: board, now: now) == "team: 2 wait on lead · 1 working")
        // Its own row says so too, and isn't counted with what needs you.
        let state = verifier.state(now: now)
        #expect(state.text == "waits on lead" && state.group != .needsYou)
        #expect(WindowGroups.summary(two, now: now) == "3 working")
        // The popover's row and the header's pill say it on its own.
        #expect(verifier.session.map(LeadTeams.label(of:)) == "Waits on lead")
        // A session of yours on a prompt still needs you.
        let yours = agentRow("/r/other", status: .needsInput)
        #expect(yours.state(now: now).group == .needsYou && yours.session.map(LeadTeams.label(of:)) == "Needs you")
    }

    /// A lead with a question for you open needs you, its terminal idle or not: that's when you're needed. Answered or
    /// withdrawn, it reads idle again.
    @Test func aLeadWithAnOpenQuestionNeedsYouWithItsTerminalIdle() {
        let now = Date()
        func lead(_ status: SessionStatus, boards: [String: LeadBoard]) -> WindowRow {
            var session = Session(tty: "ttys001", agent: .claude, pid: 1, startedAt: now, cwd: "/r/acme", project: "acme", task: nil,
                                  status: status, statusSince: now - 120, detail: nil, hasHooks: true, inTerminalApp: false)
            session.hostID = UUID()
            session.teamRole = .lead
            session.leadAsks = LeadTeams.asks(session, asking: LeadTeams.asking(boards))
            return WindowRow(content: .agent(session), project: "acme")
        }
        var board = LeadBoard()
        board.questions = [LeadQuestion(text: "Ship the beta to everyone?", options: ["Everyone", "Testers"])]
        // The board's root as the lead's tools write it (a trailing slash) is the lead's folder all the same.
        let asking = lead(.idle, boards: ["/r/acme/": board])
        #expect(asking.session?.leadAsks == true)
        #expect(asking.state(now: now).text == "needs you" && asking.state(now: now).group == .needsYou)
        #expect(asking.session.map(LeadTeams.label(of:)) == "Needs you" && asking.session?.shownStatus == .needsInput)
        #expect(WindowGroups.summary([asking], now: now) == "1 needs you")
        #expect(WindowGroups.attention([WindowSection(project: "acme", rows: [asking])], now: now).map(\.project) == [AttentionGroup.needsYou.title])
        // Its turn over (done, or background jobs running) reads the same; at work it reads working, the badge says the rest.
        #expect(lead(.done, boards: ["/r/acme": board]).state(now: now).group == .needsYou)
        #expect(lead(.working, boards: ["/r/acme": board]).state(now: now).group == .working)
        // Another project's question isn't this lead's.
        #expect(lead(.idle, boards: ["/r/other": board]).state(now: now).group == .idle)
        // A worker in the lead's folder (it never is, but) isn't asked through the lead's board.
        var worker = Session(tty: "ttys002", agent: .claude, pid: 2, startedAt: now, cwd: "/r/acme", project: "acme", task: nil,
                             status: .idle, statusSince: now, detail: nil, hasHooks: true, inTerminalApp: false)
        worker.teamRole = .worker
        #expect(!LeadTeams.asks(worker, asking: LeadTeams.asking(["/r/acme": board])))

        // Answered: idle again.
        var answered = board
        answered.questions[0].answer = "Testers"
        answered.questions[0].answeredAt = now.timeIntervalSince1970
        let after = lead(.idle, boards: ["/r/acme": answered])
        #expect(after.state(now: now).text == "idle" && after.state(now: now).group == .idle)
        #expect(after.session.map(LeadTeams.label(of:)) == "Idle")
        // Withdrawn: idle again.
        var withdrawn = board
        withdrawn.questions[0].withdrawnAt = now.timeIntervalSince1970
        #expect(lead(.idle, boards: ["/r/acme": withdrawn]).state(now: now).group == .idle)
        #expect(LeadTeams.asking(["/r/acme": withdrawn]).isEmpty)
    }

    /// A lead whose worker waits on it isn't red: "needs you" is only ever you. The worker shows as working, and the
    /// lead's row says "team: 1 waits on lead".
    @Test func aLeadWithAWorkerWaitingOnItIsNotRed() {
        let now = Date()
        let wt = "/r/acme/.vibeswitcher/worktrees/"
        var board = LeadBoard()
        board.tasks = [task("a", .running)]
        let lead = agentRow("/r/acme", status: .idle, role: .lead)
        let worker = agentRow(wt + "a", status: .needsInput, role: .worker)
        #expect(lead.session?.shownStatus == .idle && lead.state(now: now).group == .idle)
        #expect(worker.session?.shownStatus == .working && worker.state(now: now).group == .working)
        #expect(LeadTeams.summary([worker], label: { _ in "Worker: A" }, board: board, now: now) == "team: 1 waits on lead")
        #expect(WindowGroups.summary([lead, worker], now: now) == "1 working")
        // The menu bar's spoken summary, and the popover's row: not one that needs you.
        #expect(StatusSummary.spoken([lead.session!, worker.session!]) == "VibeSwitcher: 1 working, 1 idle")
        #expect(StatusSummary.spoken(number: 2, name: "acme · worker a", session: worker.session!) == "2, acme · worker a, waits on lead")
        #expect(StatusSummary.spoken(number: 1, name: "acme", session: lead.session!) == "1, acme, idle")
    }

    /// Under load the process table can't be read for a while (the store keeps the sessions of the last one read): a
    /// worker's agent counts as quit only from a table read a minute after its session started, not from the clock.
    @Test func aTeamMemberEndsOnlyByATableReadAMinuteAfterItStarted() {
        let now = Date()
        let started = now - 600
        let wt = "/r/acme/.vibeswitcher/worktrees/"
        let worker = session("Worker: K", cwd: wt + "k", started: started)
        let label: (WindowRow) -> String? = { _ in "Worker: K" }
        for readAt in [nil, started - 30, started + 30] {
            let row = shellRow(worker, tableReadAt: readAt)
            #expect(LeadTeams.isLive(row), "table read at \(String(describing: readAt))")
            #expect(LeadTeams.state(of: row, now: now).text == "unknown")
            #expect(LeadTeams.summary([row], label: label, board: nil, now: now) == "team: 1 unknown")
        }
        // Read a minute on, but its terminal's process couldn't be told (mid-exec): still live, unknown.
        let undecided = shellRow(worker, tableReadAt: now, undecided: Undecided(ttys: [worker.tty]))
        #expect(LeadTeams.isLive(undecided))
        #expect(LeadTeams.state(of: undecided, now: now).text == "unknown")
        #expect(LeadTeams.summary([undecided], label: label, board: nil, now: now) == "team: 1 unknown")
        let ended = shellRow(worker, tableReadAt: started + 60)
        #expect(!LeadTeams.isLive(ended))
        #expect(LeadTeams.state(of: ended, now: now).text == "agent ended · shell")
        #expect(LeadTeams.summary([ended], label: label, board: nil, now: now) == "team: none running")
    }
}
