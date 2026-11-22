import Foundation
import Testing
@testable import VibeCore

struct WindowRowsTests {
    func agent(_ tty: String, project: String, host: UUID? = nil) -> Session {
        var session = Session(tty: tty, agent: .claude, pid: 1, startedAt: Date(), cwd: "/dev/\(project)", project: project,
                              task: nil, status: .idle, statusSince: Date(), detail: nil, hasHooks: true, inTerminalApp: host == nil)
        session.hostID = host
        return session
    }

    func hosted(_ tty: String, cwd: String, live: Bool = true, started: TimeInterval = 0) -> HostSession {
        HostSession(id: UUID(), tty: tty, childPID: 2, cwd: cwd, command: nil, label: "Shell", agent: nil, title: "",
                    startedAt: Date(timeIntervalSince1970: started), cols: 80, rows: 24,
                    exit: live ? nil : .init(status: 0, at: Date()))
    }

    @Test func extrasAreHostedSessionsWithoutALiveAgent() {
        let withAgent = hosted("ttys001", cwd: "/a")
        let shell = hosted("ttys002", cwd: "/a")
        let ended = hosted("ttys003", cwd: "/a", live: false)
        let extras = WindowRows.extras(hosted: [withAgent, shell, ended], agentTTYs: ["ttys001", "ttys003"])
        #expect(extras.map(\.id) == [shell.id, ended.id])   // an ended session stays even if its tty is reused
    }

    @Test func sectionsFollowTheStoreOrderThenAddExtras() {
        let windowID = UUID()
        let sessions = [agent("ttys005", project: "beta"), agent("ttys001", project: "alpha", host: windowID),
                        agent("ttys002", project: "beta")]
        let older = hosted("ttys009", cwd: "/x/alpha", started: 1)
        let newer = hosted("ttys010", cwd: "/x/gamma", started: 2)
        let ended = hosted("ttys011", cwd: "/x/alpha", live: false, started: 3)
        let sections = WindowRows.sections(sessions: sessions, hosted: [older, ended, newer], table: TableRead(),
                                           projectName: { ($0 as NSString).lastPathComponent })
        #expect(sections.map(\.project) == ["beta", "alpha", "gamma"])
        #expect(sections[0].rows.map(\.id) == ["tty:ttys005", "tty:ttys002"])
        #expect(sections[1].rows.map(\.id) == ["host:\(windowID)", "host:\(older.id)", "host:\(ended.id)"])
        #expect(sections[1].rows[0].hostID == windowID)
    }

    /// At launch the scan can list an agent before the store learns its tty is a window session's: the row
    /// must still be the window session's (same id), or the window loses its selection.
    @Test func anAgentOnAHostedTTYGetsTheHostIDBeforeTheStoreKnows() {
        let shell = hosted("ttys009", cwd: "/x/alpha")
        let sections = WindowRows.sections(sessions: [agent("ttys009", project: "alpha")], hosted: [shell], table: TableRead(),
                                           projectName: { ($0 as NSString).lastPathComponent })
        #expect(sections.flatMap(\.rows).map(\.id) == ["host:\(shell.id)"])
        #expect(sections.first?.rows.first?.hostID == shell.id)
    }

    /// A host restart ends the window sessions one by one; until the next scan the store still lists their agents.
    /// The ended session is the agent's row then, not a second one with the same id (SwiftUI's ForEach warns
    /// "the ID host:… occurs multiple times" and the list misbehaves).
    @Test func aWindowSessionEndedBeforeTheScanKnowsIsOneRow() {
        let info = hosted("ttys001", cwd: "/x/alpha", live: false)
        let id = info.id
        let sessions = [agent("ttys001", project: "alpha", host: id)]
        let rows = WindowRows.sections(sessions: sessions, hosted: [info], table: TableRead(), projectName: { ($0 as NSString).lastPathComponent })
            .flatMap(\.rows)
        #expect(rows.map(\.id) == ["host:\(id)"])
    }

    @Test func aWindowSessionKeepsItsRowIDWhenItsAgentEnds() {
        let id = UUID()
        let running = WindowRow(content: .agent(agent("ttys001", project: "a", host: id)), project: "a")
        var info = hosted("ttys001", cwd: "/a", live: false)
        info.id = id
        let ended = WindowRow(content: .hosted(info), project: "a")
        #expect(running.id == ended.id)
    }

    /// A handover ended the old lead (started at 10): the new one (started at 40) goes where its row was, before the
    /// user's session started at 20, not last; Terminal's sessions and the ended old row don't count.
    @Test func aLeadAHandoverStartedTakesTheOldOnesPlace() {
        func at(_ tty: String, _ started: TimeInterval, host: UUID? = nil) -> Session {
            var session = agent(tty, project: "alpha", host: host)
            session.startedAt = Date(timeIntervalSince1970: started)
            return session
        }
        let (user, new) = (UUID(), UUID())
        var old = hosted("ttys001", cwd: "/x/alpha", live: false, started: 10)
        old.label = "Lead · alpha"
        let terminal = at("ttys009", 50)
        let sessions = [terminal, at("ttys002", 20, host: user), at("ttys003", 40, host: new)]
        let shell = hosted("ttys004", cwd: "/x/alpha", started: 30)
        let sections = WindowRows.sections(sessions: sessions, hosted: [old, shell], table: TableRead(),
                                           projectName: { ($0 as NSString).lastPathComponent })
        #expect(sections[0].rows.map(\.id) == ["tty:ttys009", "host:\(user)", "host:\(new)", "host:\(shell.id)", "host:\(old.id)"])
        let placed = WindowRows.placed(sections, places: [new: Date(timeIntervalSince1970: 10)])
        #expect(placed[0].rows.map(\.id) == ["tty:ttys009", "host:\(new)", "host:\(user)", "host:\(shell.id)", "host:\(old.id)"])
        // Placed again, or with no places: as it was.
        #expect(WindowRows.placed(placed, places: [new: Date(timeIntervalSince1970: 10)]) == placed)
        #expect(WindowRows.placed(sections, places: [:]) == sections)
        // A lead that started before everything after its place stays where it is.
        #expect(WindowRows.placed(sections, places: [new: Date(timeIntervalSince1970: 35)]) == sections)
    }
}
