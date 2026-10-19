import Foundation
import Testing
@testable import VibeCore

struct WindowGroupsTests {
    let now = Date(timeIntervalSince1970: 10_000)

    func agent(_ tty: String, project: String = "p", status: SessionStatus = .idle, since: TimeInterval = 0,
               started: TimeInterval = 0, task: String? = nil) -> WindowRow {
        let session = Session(tty: tty, agent: .claude, pid: 1, startedAt: Date(timeIntervalSince1970: started), cwd: "/dev/\(project)",
                              project: project, task: task, status: status, statusSince: Date(timeIntervalSince1970: since),
                              detail: nil, hasHooks: true, inTerminalApp: true)
        return WindowRow(content: .agent(session), project: project)
    }

    func hosted(agent: String? = nil, live: Bool = true, exit: Int32 = 1, title: String = "", project: String = "p") -> WindowRow {
        let info = HostSession(id: UUID(), tty: "ttys900", childPID: 2, cwd: "/dev/\(project)", command: nil, label: "Shell",
                               agent: agent, title: title, startedAt: Date(timeIntervalSince1970: 5), cols: 80, rows: 24,
                               exit: live ? nil : .init(status: exit, at: Date(timeIntervalSince1970: 9_000)))
        return WindowRow(content: .hosted(info), project: project)
    }

    /// At 30 s: the hosted sessions (started at 5) are still within their "starting" minute.
    func groups(_ rows: [WindowRow]) -> [String: [String]] {
        let sections = WindowGroups.attention([WindowSection(project: "p", rows: rows)], now: Date(timeIntervalSince1970: 30))
        return Dictionary(uniqueKeysWithValues: sections.map { ($0.project, $0.rows.map(\.id)) })
    }

    @Test func everyStateLandsInItsGroup() {
        var paused = agent("t6", status: .needsInput)
        if case .agent(var session) = paused.content {
            session.pausedUntil = .distantFuture
            paused.content = .agent(session)
        }
        let rows = [agent("t1", status: .needsInput), agent("t2", status: .working), agent("t3", status: .background),
                    agent("t4", status: .done), agent("t5", status: .idle), paused, agent("t7", status: .unknown)]
        let starting = hosted(agent: "claude")
        let shell = hosted()
        let ended = hosted(agent: "claude", live: false)
        let result = groups(rows + [starting, shell, ended])
        #expect(result[AttentionGroup.needsYou.title] == ["tty:t1"])
        #expect(result[AttentionGroup.working.title] == ["tty:t2", "tty:t3", starting.id])
        #expect(result[AttentionGroup.ready.title] == ["tty:t4"])
        #expect(result[AttentionGroup.idle.title] == ["tty:t5", "tty:t6", "tty:t7", shell.id, ended.id])
    }

    @Test func groupsComeInAttentionOrderAndEmptyOnesAreDropped() {
        let sections = WindowGroups.attention([WindowSection(project: "p", rows: [agent("t1", status: .done),
                                                                                 agent("t2", status: .needsInput)])])
        #expect(sections.map(\.project) == [AttentionGroup.needsYou.title, AttentionGroup.ready.title])
    }

    @Test func ordersWithinGroups() {
        let rows = [agent("w-late", status: .working, since: 1, started: 300), agent("w-early", status: .working, since: 900, started: 100),
                    agent("n-recent", status: .needsInput, since: 800), agent("n-old", status: .needsInput, since: 200),
                    agent("d-old", status: .done, since: 100), agent("d-new", status: .done, since: 700),
                    agent("i-b", project: "b"), agent("i-a", project: "a")]
        let result = groups(rows)
        #expect(result[AttentionGroup.needsYou.title] == ["tty:n-old", "tty:n-recent"])
        #expect(result[AttentionGroup.working.title] == ["tty:w-early", "tty:w-late"])
        #expect(result[AttentionGroup.ready.title] == ["tty:d-new", "tty:d-old"])
        #expect(result[AttentionGroup.idle.title] == ["tty:i-b", "tty:i-a"])   // input (project) order
    }

    @Test func groupingKeepsRowsAcrossSections() {
        let sections = [WindowSection(project: "a", rows: [agent("t1", project: "a", status: .needsInput)]),
                        WindowSection(project: "b", rows: [agent("t2", project: "b", status: .needsInput, since: -1)])]
        #expect(WindowGroups.attention(sections).first?.rows.map(\.id) == ["tty:t2", "tty:t1"])
    }

    @Test func filterMatchesTitleProjectAndTaskIgnoringCase() {
        let sections = [WindowSection(project: "genswap", rows: [agent("t1", project: "genswap", task: "Fix Router")]),
                        WindowSection(project: "other", rows: [agent("t2", project: "other"), hosted(title: "GenSwap logs", project: "other")])]
        #expect(WindowGroups.filter(sections, query: "router").flatMap(\.rows).map(\.id) == ["tty:t1"])
        #expect(WindowGroups.filter(sections, query: "GENSWAP").map(\.project) == ["genswap", "other"])
        #expect(WindowGroups.filter(sections, query: "OTH").flatMap(\.rows).count == 2)
        #expect(WindowGroups.filter(sections, query: "zzz").isEmpty)
        #expect(WindowGroups.filter(sections, query: "  ") == sections)
    }

    @Test func titlePrefersCustomNameThenTaskThenProject() {
        var row = agent("t1", project: "proj", task: "Task")
        #expect(row.title == "Task")
        if case .agent(var session) = row.content {
            session.customName = "Mine"
            row.content = .agent(session)
        }
        #expect(row.title == "Mine")
        #expect(agent("t2", project: "proj").title == "proj")
        #expect(hosted(title: "vim notes").title == "vim notes")
        #expect(hosted().title == "Shell")
    }

    @Test func stateTextAndSince() {
        #expect(agent("t", status: .needsInput, since: 100).state(now: now).text == "waiting")
        #expect(agent("t", status: .needsInput, since: 100).state(now: now).since == Date(timeIntervalSince1970: 100))
        #expect(agent("t", status: .done).state(now: now).text == "done")
        #expect(agent("t", status: .working).state(now: now).text == "working")
        var busy = agent("t", status: .working)
        if case .agent(var session) = busy.content {
            session.activity = "Run tests"
            session.activitySince = Date(timeIntervalSince1970: 50)
            busy.content = .agent(session)
        }
        #expect(busy.state(now: now).text == "Run tests")
        #expect(busy.state(now: now).since == Date(timeIntervalSince1970: 50))
        #expect(hosted(live: false).state(now: now).text == "exit 1")
        #expect(hosted(agent: "codex").state(now: Date(timeIntervalSince1970: 30)).text == "starting")
        #expect(hosted().state(now: now).text == "shell")
        #expect(agent("t", status: .unknown).state(now: now).since == nil)
    }

    /// A preset that keeps a shell open leaves a live session with an agent label after the agent quits: it
    /// isn't "starting" for ever.
    @Test func aWindowSessionWhoseAgentNeverShowsUpStopsBeingStarting() {
        let info = hosted(agent: "claude").hosted!   // started at 5
        #expect(scanned(info, tableReadAt: Date(timeIntervalSince1970: 30)).state(now: Date(timeIntervalSince1970: 30)).group == .working)
        let later = scanned(info, tableReadAt: Date(timeIntervalSince1970: 5 + 61)).state(now: Date(timeIntervalSince1970: 5 + 61))
        #expect(later.group == .idle)
        #expect(later.text == "agent ended · shell")
    }

    /// Its row as the window builds it from a scan of a process table read at `tableReadAt` that found no agent on it
    /// (and couldn't tell what runs on the `undecided` terminals).
    func scanned(_ info: HostSession, tableReadAt: Date?, undecided: Undecided = Undecided()) -> WindowRow {
        WindowRows.sections(sessions: [], hosted: [info], table: TableRead(at: tableReadAt, undecided: undecided),
                            projectName: { _ in "p" })[0].rows[0]
    }

    /// Under load the process table can't be read for minutes (the store keeps the sessions of the last one read): a
    /// minute on by the clock, the agent isn't known to have quit until a table read a minute after the session started
    /// says so. Never read, read before it started or less than a minute after: unknown, never "agent ended".
    @Test func anUnreadOrStaleTableNeverEndsTheAgent() {
        let info = hosted(agent: "claude").hosted!   // started at 5
        for readAt in [nil, Date(timeIntervalSince1970: 1), Date(timeIntervalSince1970: 5 + 59)] {
            let row = scanned(info, tableReadAt: readAt)
            #expect(!row.agentQuit)
            #expect(row.state(now: Date(timeIntervalSince1970: 30)).text == "starting")
            let later = row.state(now: now)
            #expect(later.text == "status unknown", "table read at \(String(describing: readAt))")
            #expect(later.group == .idle)
            #expect(later.since == nil)
        }
        let ended = scanned(info, tableReadAt: Date(timeIntervalSince1970: 5 + 60)).state(now: now)
        #expect(ended.text == "agent ended · shell")
        #expect(ended.group == .idle)
        // Read a minute on, but what runs on its terminal couldn't be told (a process mid-exec): unknown as well.
        for undecided in [Undecided(ttys: [info.tty]), Undecided(anywhere: true)] {
            let row = scanned(info, tableReadAt: now, undecided: undecided)
            #expect(!row.agentQuit)
            #expect(row.state(now: now).text == "status unknown")
        }
        #expect(scanned(info, tableReadAt: now, undecided: Undecided(ttys: ["ttys901"])).state(now: now).text == "agent ended · shell")
        // Ended sessions and plain shells read the same whatever the table.
        #expect(scanned(hosted(agent: "claude", live: false).hosted!, tableReadAt: nil).state(now: now).text == "exit 1")
        #expect(scanned(hosted().hosted!, tableReadAt: now).state(now: now).text == "shell")
    }

    @Test func summaryCountsWhatNeedsYouAndWhatWorks() {
        #expect(WindowGroups.summary([agent("a", status: .needsInput), agent("b", status: .needsInput), agent("c", status: .working),
                                      agent("d", status: .background)]) == "2 need you · 2 working")
        #expect(WindowGroups.summary([agent("a", status: .needsInput)]) == "1 needs you")
        #expect(WindowGroups.summary([agent("a", status: .idle)]) == "")
    }

    /// One mapping for how a session ended (WL-1): VibeSwitcher's hangup or terminate (129, 143) is a normal end, as is
    /// exit 0; any other code is a failure, said as its code.
    @Test func howASessionEndedReadsTheSameEverywhere() {
        let cases: [(Int32, String, Bool, String)] = [(0, "finished", false, "checkmark.circle"), (129, "ended", false, "stop.circle"),
                                                      (143, "ended", false, "stop.circle"), (1, "exit 1", true, "exclamationmark.circle")]
        for (status, text, failure, symbol) in cases {
            let end = SessionEnd(status: status)
            #expect(end.text == text, "\(status)")
            #expect(end.isFailure == failure, "\(status)")
            #expect(end.symbol == symbol, "\(status)")
            let row = hosted(live: false, exit: status)
            #expect(row.end == end)
            #expect(row.state(now: now).text == text)
            #expect(row.state(now: now).group == .idle)
            #expect(row.state(now: now).since == Date(timeIntervalSince1970: 9_000))
        }
        #expect(SessionEnd(status: 2).isFailure && SessionEnd(status: 137).text == "exit 137")
        #expect(hosted().end == nil && agent("t").end == nil)
    }

    /// Ended rows leave their sections for the "Ended (n)" fold, in the order shown; a row kept (a team member under
    /// its lead) stays, and a section left empty goes.
    @Test func endedRowsFoldAwayFromTheirSections() {
        let live = agent("a"), shell = hosted(project: "q")
        let ended = hosted(live: false, exit: 129), failed = hosted(live: false, exit: 1, project: "q"), member = hosted(live: false, exit: 143)
        let sections = [WindowSection(project: "p", rows: [live, ended, member]), WindowSection(project: "q", rows: [failed, shell]),
                        WindowSection(project: "r", rows: [hosted(live: false, exit: 0, project: "r")])]
        let (kept, folded) = WindowGroups.foldEnded(sections, keep: [member.id])
        #expect(kept.map(\.project) == ["p", "q"])
        #expect(kept[0].rows.map(\.id) == [live.id, member.id])
        #expect(kept[1].rows.map(\.id) == [shell.id])
        #expect(folded.map(\.id) == [ended.id, failed.id, sections[2].rows[0].id])
        #expect(WindowGroups.foldEnded([WindowSection(project: "p", rows: [live])]).ended.isEmpty)
    }
}
