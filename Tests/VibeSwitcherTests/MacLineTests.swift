import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The Team view's Mac-wide line: what every project's team holds and the load, so the user sees why a lead holds
/// back its workers.
struct MacLineTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func hosted(_ cwd: String, _ label: String, ended: Bool = false) -> HostSession {
        HostSession(id: UUID(), tty: "ttys0", childPID: 1, cwd: cwd, command: "claude", label: label, agent: "claude", title: label,
                    startedAt: now - 60, cols: 120, rows: 40, exit: ended ? HostSession.Exit(status: 0, at: now) : nil)
    }

    static let sessions = [
        hosted("/Users/x/dev/vibeswitcher/.vibeswitcher/worktrees/fix", "Worker: Fix"),
        hosted("/Users/x/dev/vibeswitcher/.vibeswitcher/worktrees/fix", "Verifier: Fix"),
        hosted("/Users/x/dev/project-c/.vibeswitcher/worktrees/swap", "Worker: Swap"),
        hosted("/Users/x/dev/films/.vibeswitcher/worktrees/cut", "Worker: Cut", ended: true),
        hosted("/Users/x/dev/films", "Lead · films"),
        hosted("/Users/x/dev/notes", "Claude"),
    ]

    @Test func theLineCountsEveryProjectsLiveTeamAndTheLoad() {
        let line = MacLine.make(Self.sessions, load: 12.34, limits: MacLimits(loadThreshold: 24))
        #expect(line.text == "Mac: load 12.3, 3 team sessions across 2 projects")
        #expect(!line.isOver)
        #expect(line.spoken == "Whole Mac, all projects: load average 12.3, the greater of the last minute's and the last 5 minutes'; 3 team sessions across 2 projects (vibeswitcher 2, project-c 1)")
    }

    @Test func overALimitItSaysWhichAndThatTheLeadWaits() {
        let loaded = MacLine.make(Self.sessions, load: 150, limits: MacLimits(loadThreshold: 24))
        #expect(loaded.text == "Mac: load 150.0, 3 team sessions across 2 projects")
        #expect(loaded.isOver)
        #expect(loaded.spoken.contains("over the load limit of 24: new workers and audits wait"))
        #expect(!loaded.spoken.contains("limit of 3 team sessions"))
        let full = MacLine.make(Self.sessions, load: 1, limits: MacLimits(maxSessions: 3))
        #expect(full.isOver)
        #expect(full.spoken.contains("at the limit of 3 team sessions: new workers and audits wait"))
        let unknown = MacLine.make([], load: nil, limits: MacLimits())
        #expect(unknown.text == "Mac: load unknown, 0 team sessions across 0 projects")
        #expect(unknown.spoken.contains("load average unknown") && !unknown.isOver)
    }
}
