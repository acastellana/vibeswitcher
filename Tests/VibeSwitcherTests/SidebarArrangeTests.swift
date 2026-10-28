import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The sidebar's body asked for `WindowModel.arranged` on every update, each time grouping every row and folding each
/// lead's team under it: with a lead's window updating many times a second, that was part of its freezes
/// (hang-20261027-201459). It's made again only when what it's made of changes.
@MainActor
@Suite(.serialized)
struct SidebarArrangeTests {
    static let now = Date()

    static func hosted(_ label: String, cwd: String, agent: String? = nil, started: Date = now - 3_600) -> HostSession {
        HostSession(id: UUID(), tty: "ttys0", childPID: 1, cwd: cwd, command: "claude", label: label, agent: agent, title: label,
                    startedAt: started, cols: 80, rows: 24, exit: nil)
    }

    @Test func arrangedIsMadeAgainOnlyWhenItsInputsChange() {
        UserDefaults.standard.removeObject(forKey: "windowGrouping")
        let model = WindowModel()
        let lead = Self.hosted("Lead · acme", cwd: "/Users/you/dev/acme")
        let worker = Self.hosted("Worker: One", cwd: "/Users/you/dev/acme/.vibeswitcher/worktrees/one")
        var other = Self.hosted("Shell", cwd: "/Users/you/dev/tools")
        model.update(sessions: [], hosted: [lead, worker, other], table: TableRead(at: Self.now))
        let first = model.arranged
        #expect(first.teams["host:\(lead.id)"]?.map(\.id) == ["host:\(worker.id)"])
        for _ in 0..<10 { _ = model.arranged }
        _ = model.rows
        #expect(model.arrangedMade == 1)
        // The same sessions again: nothing to make.
        model.update(sessions: [], hosted: [lead, worker, other], table: TableRead(at: Self.now))
        _ = model.arranged
        #expect(model.arrangedMade == 1)
        // The lead's team opened: made again, once, with the worker under its lead.
        model.toggleTeam("host:\(lead.id)")
        #expect(model.arranged.nested == ["host:\(worker.id)"])
        _ = model.arranged
        #expect(model.arrangedMade == 2)
        // A session's title changed: made again.
        other.title = "Another title"
        model.update(sessions: [], hosted: [lead, worker, other], table: TableRead(at: Self.now))
        #expect(model.arranged.sections.flatMap(\.rows).contains { $0.title == "Another title" })
        #expect(model.arrangedMade == 3)
        // The grouping changed: made again.
        model.grouping = model.grouping == .attention ? .projects : .attention
        _ = model.arranged
        _ = model.arranged
        #expect(model.arrangedMade == 4)
        // What it is, is what it was made from.
        let fresh = LeadTeams.arrange(model.grouping == .attention ? WindowGroups.attention(model.sections) : model.sections,
                                      label: model.label(of:), expanded: model.expandedTeams)
        #expect(model.arranged.sections == fresh.sections && model.arranged.nested == fresh.nested)
        UserDefaults.standard.removeObject(forKey: "windowGrouping")
    }

    /// Grouped by attention, a window session's agent counts as working for its first minute ("starting"), then not:
    /// the one change the clock makes alone, so the kept arrangement lasts until then.
    @Test func theAttentionGroupingIsMadeAgainWhenAStartRunsOut() {
        let started = Self.hosted("Claude", cwd: "/Users/you/dev/acme", agent: "claude", started: Self.now - 20)
        let old = Self.hosted("Claude", cwd: "/Users/you/dev/acme", agent: "claude", started: Self.now - 600)
        let sections = WindowRows.sections(sessions: [], hosted: [started, old], table: TableRead(at: Self.now)) { _ in "acme" }
        #expect(WindowModel.regroups(sections, after: Self.now) == started.startedAt.addingTimeInterval(WindowGroups.startingFor))
        let settled = WindowRows.sections(sessions: [], hosted: [old], table: TableRead(at: Self.now)) { _ in "acme" }
        #expect(WindowModel.regroups(settled, after: Self.now) == .distantFuture)
    }
}
