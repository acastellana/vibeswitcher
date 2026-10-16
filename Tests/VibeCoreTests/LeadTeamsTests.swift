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
}
