import AppKit
import Foundation
import SwiftUI
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
    let scratch = Scratch()

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

    /// The sidebar drawn again and again with nothing changed arranges nothing and counts no lead's questions
    /// (hang-20261101-034453, -054457, -054751: `LeadTeams.arrange` and `LeadBoard.blockingQuestions` under its body on
    /// every update); a board's questions changing counts that board's once, and the sessions changing arranges the list
    /// once, as they change rather than as it draws.
    @Test func redrawsArrangeNothingAndABoardChangeCountsItsQuestionsOnce() throws {
        let saved = UserDefaults.standard.string(forKey: "windowGrouping")
        defer { UserDefaults.standard.set(saved, forKey: "windowGrouping") }
        let folder = scratch.url("sidebar-arrange")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = WindowModel()
        model.grouping = .projects
        let root = "/Users/you/dev/acme"
        let lead = Self.hosted("Lead · acme", cwd: root)
        let worker = Self.hosted("Worker: One", cwd: root + "/.vibeswitcher/worktrees/one")
        var other = Self.hosted("Shell", cwd: "/Users/you/dev/tools")
        // Arranged as the sessions arrive, before anything draws.
        let made = model.arrangedMade
        model.update(sessions: [], hosted: [lead, worker, other], table: TableRead(at: Self.now))
        #expect(model.arrangedMade == made + 1)
        model.toggleTeam("host:\(lead.id)")
        #expect(model.arrangedMade == made + 2)

        let host = HostClient(socketPath: folder.appendingPathComponent("no-host.sock").path)
        let store = SessionStore(scanner: SessionScanner(processes: { [:] }, stateDir: { folder }, cwd: { _ in nil }, arguments: { _ in [] }))
        let leads = LeadController(host: host, store: store, vault: LeadVault(folder: folder.appendingPathComponent("vault"), ask: { _ in throw LeadVault.Refused("none") }),
                                   inbox: folder, home: folder.path) { _ in "true" }
        var board = LeadBoard()
        var blocking = LeadQuestion(id: "B", text: "Which base?", options: [], at: Self.now.timeIntervalSince1970 - 60)
        blocking.priority = .blocking
        var answered = LeadQuestion(id: "A", text: "Ship it?", options: [], at: Self.now.timeIntervalSince1970 - 600)
        answered.answer = "Yes"
        answered.answeredAt = Self.now.timeIntervalSince1970 - 300
        board.questions = [blocking, answered, LeadQuestion(id: "I", text: "Blue or red?", options: [], at: Self.now.timeIntervalSince1970 - 30)]
        leads.refreshed(roots: [root], fired: [:], loaded: [root: board], decisions: [:], teams: [:], refusals: [:])
        #expect(leads.questionsCounted == 1)
        #expect(leads.questionCounts[root]?.open == board.openQuestions.count && leads.questionCounts[root]?.blocking == board.blockingQuestions)
        #expect(leads.questionCounts[root]?.open == 2 && leads.questionCounts[root]?.blocking == 1)

        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 300, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSHostingView(rootView: SessionListView(model: model, leads: leads, actions: EndedSnapshots.actions).frame(width: 300, height: 600))
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.close() }
        func redraw(_ times: Int) {
            for step in 0..<times {
                // A change the sidebar shows (its filter) and the models' plain "something changed", neither an input.
                model.filter = step % 2 == 0 ? "o" : ""
                model.objectWillChange.send()
                leads.objectWillChange.send()
                view.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                RunLoop.main.run(until: Date())
            }
            model.filter = ""
        }
        redraw(1)
        let arranged = model.arrangedMade, counted = leads.questionsCounted
        redraw(10)
        #expect(model.arrangedMade == arranged)
        #expect(leads.questionsCounted == counted)

        // The same board read again: nothing counted.
        leads.refreshed(roots: [root], fired: [:], loaded: [root: board], decisions: [:], teams: [:], refusals: [:])
        #expect(leads.questionsCounted == counted)
        // One board change (the blocking question answered): counted once, the list not arranged again.
        board.questions[0].answer = "main"
        board.questions[0].answeredAt = Self.now.timeIntervalSince1970
        leads.refreshed(roots: [root], fired: [:], loaded: [root: board], decisions: [:], teams: [:], refusals: [:])
        #expect(leads.questionsCounted == counted + 1)
        #expect(leads.questionCounts[root]?.open == 1 && leads.questionCounts[root]?.blocking == 0)
        redraw(10)
        #expect(leads.questionsCounted == counted + 1)
        #expect(model.arrangedMade == arranged)
        // One session change: arranged once.
        other.title = "Another title"
        model.update(sessions: [], hosted: [lead, worker, other], table: TableRead(at: Self.now))
        redraw(10)
        #expect(model.arrangedMade == arranged + 1)
        // A board gone: its counts go with it.
        leads.refreshed(roots: [], fired: [:], loaded: [:], decisions: [:], teams: [:], refusals: [:])
        #expect(leads.questionCounts[root] == nil)
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

    /// Grouped by attention, the stored arrangement is made again when a "starting" runs out, with no other change:
    /// the row leaves the working group by itself.
    @Test func theAttentionGroupingRegroupsByItselfWhenAStartRunsOut() async {
        let saved = UserDefaults.standard.string(forKey: "windowGrouping")
        defer { UserDefaults.standard.set(saved, forKey: "windowGrouping") }
        let model = WindowModel()
        model.grouping = .attention
        let starting = Self.hosted("Claude", cwd: "/Users/you/dev/acme", agent: "claude",
                                   started: Date().addingTimeInterval(0.3 - WindowGroups.startingFor))
        model.update(sessions: [], hosted: [starting], table: TableRead(at: Date()))
        let made = model.arrangedMade
        let before = model.arranged.sections.map(\.project)
        #expect(await until { model.arrangedMade > made }, "not arranged again as the start ran out")
        #expect(model.arranged.sections.map(\.project) != before, "\(before) → \(model.arranged.sections.map(\.project))")
        #expect(model.arranged.sections == WindowGroups.attention(model.sections, now: Date()))
    }
}
