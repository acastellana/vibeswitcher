import Foundation
import Testing
@testable import VibeCore

/// Your own sessions apart from the leads' workers and verifiers (UI audit 2026-10-22 #1).
struct SessionTeamsTests {
    private func session(_ tty: String, _ role: LeadLaunch.Role?, cwd: String, project: String) -> Session {
        var session = Session(tty: tty, agent: .claude, pid: 1, startedAt: Date(), cwd: cwd, project: project, task: nil,
                              status: .working, statusSince: Date(), detail: nil, hasHooks: true, inTerminalApp: false)
        session.teamRole = role
        return session
    }

    @Test func aLeadsTeamIsListedAfterYourOwnSessionsUnderItsProject() {
        let sessions = [
            session("w1", .worker, cwd: "/r/acme/.vibeswitcher/worktrees/fix-login", project: "fix-login"),
            session("me", nil, cwd: "/r/notes", project: "notes"),
            session("lead", .lead, cwd: "/r/acme", project: "acme"),
            session("v1", .verifier, cwd: "/r/acme/.vibeswitcher/worktrees/fix-login", project: "fix-login"),
            session("g1", .worker, cwd: "/r/genswap/.vibeswitcher/worktrees/plan", project: "plan"),
            session("w2", .worker, cwd: "/r/acme/.vibeswitcher/worktrees/docs", project: "docs"),
        ]
        let split = SessionTeams.split(sessions)
        #expect(split.own.map(\.tty) == ["me", "lead"])
        #expect(split.teams.map(\.project) == ["acme", "genswap"])
        #expect(split.teams.map { $0.members.map(\.tty) } == [["w1", "v1", "w2"], ["g1"]])
        #expect(split.teamCount == 4)
        #expect(split.listed.map(\.tty) == ["me", "lead", "w1", "v1", "w2", "g1"])
    }

    @Test func aTeamMemberIsNamedByItsTeamAndTask() {
        #expect(SessionTeams.name(of: session("v", .verifier, cwd: "/r/acme/.vibeswitcher/worktrees/fix-login", project: "fix-login"))
                == "acme · verifier fix-login")
        // Outside a worktree: its own project, no task.
        #expect(SessionTeams.name(of: session("w", .worker, cwd: "/r/odd", project: "odd")) == "odd · worker")
        #expect(SessionTeams.name(of: session("lead", .lead, cwd: "/r/acme", project: "acme")) == nil)
        #expect(SessionTeams.name(of: session("me", nil, cwd: "/r/notes", project: "notes")) == nil)
    }

    @Test func aTeamMemberThatCdsAwayKeepsItsRepositoryAndTask() {
        // Its agent ran `cd` into a scratch folder: its window session's start folder still says where it works.
        var drifted = session("w", .worker, cwd: "/tmp/scratch", project: "scratch")
        drifted.startFolder = "/r/acme/.vibeswitcher/worktrees/fix-login"
        #expect(SessionTeams.project(of: drifted) == "acme")
        #expect(SessionTeams.task(of: drifted) == "fix-login")
        #expect(SessionTeams.name(of: drifted) == "acme · worker fix-login")
        let split = SessionTeams.split([drifted, session("v", .verifier, cwd: "/r/acme/.vibeswitcher/worktrees/fix-login", project: "fix-login")])
        #expect(split.teams.map(\.project) == ["acme"])
        #expect(split.teamCount == 2)
    }
}
