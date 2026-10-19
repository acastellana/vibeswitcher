import AppKit
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The "Ended (n)" fold (WL-1): ended window sessions leave their sections for a fold at the list's end and on Home,
/// whose open or closed state this Mac remembers; ⌘1–9 and ⌥⌘↑/↓ skip what it hides.
@MainActor
@Suite(.serialized)
struct EndedFoldTests {
    static let now = Date()

    static func hosted(_ title: String, project: String, exit: Int32?, label: String = "Shell", cwd: String? = nil) -> HostSession {
        HostSession(id: UUID(), tty: "ttys9\(abs(title.hashValue) % 90)", childPID: 1, cwd: cwd ?? "/Users/you/dev/\(project)", command: "claude",
                    label: label, agent: nil, title: title, startedAt: now - 3_600, cols: 80, rows: 24,
                    exit: exit.map { HostSession.Exit(status: $0, at: now - 600) })
    }

    static func agent(_ name: String, project: String, status: SessionStatus) -> Session {
        var session = Session(tty: "ttys\(abs(name.hashValue) % 800)", agent: .claude, pid: 1, startedAt: now - 900, cwd: "/Users/you/dev/\(project)",
                              project: project, task: nil, status: status, statusSince: now - 120, detail: nil, hasHooks: true, inTerminalApp: false)
        session.customName = name
        return session
    }

    /// A model with two live sessions, one ended by VibeSwitcher (129), one that failed (exit 1), and one finished (0).
    static func model() -> (model: WindowModel, ended: [HostSession], live: [Session]) {
        UserDefaults.standard.removeObject(forKey: WindowModel.endedOpenKey)
        UserDefaults.standard.removeObject(forKey: WindowModel.homeEndedOpenKey)
        let model = WindowModel()
        let live = [agent("Menu shortcuts", project: "acme", status: .working), agent("Phone input", project: "acme", status: .needsInput)]
        let ended = [hosted("Release notes", project: "acme", exit: 129), hosted("Build script", project: "tools", exit: 1),
                     hosted("Docs pass", project: "tools", exit: 0)]
        model.update(sessions: live, hosted: ended, table: TableRead(at: now))
        return (model, ended, live)
    }

    @Test func endedRowsFoldAwayAndTheListSkipsThemWhileFolded() {
        let (model, ended, _) = Self.model()
        defer { UserDefaults.standard.removeObject(forKey: WindowModel.endedOpenKey) }
        for grouping in [WindowGrouping.attention, .projects] {
            model.grouping = grouping
            let folded = model.folded(model.arranged)
            #expect(Set(folded.ended.map(\.id)) == Set(ended.map { "host:\($0.id)" }), "\(grouping)")
            #expect(folded.sections.flatMap(\.rows).allSatisfy { $0.end == nil }, "\(grouping)")
            #expect(!model.endedOpen)
            #expect(model.rows.count == 2)
            model.endedOpen = true
            #expect(model.rows.count == 5)
            #expect(model.rows.suffix(3).map(\.id) == folded.ended.map(\.id))
            model.endedOpen = false
        }
        // The filter reaches into the fold.
        model.filter = "build"
        #expect(model.folded(model.arranged).ended.map(\.title) == ["Build script"])
        #expect(model.folded(model.arranged).sections.isEmpty)
        // Home's fold lists every ended row, whatever the filter.
        #expect(model.endedRows.count == 3)
    }

    @Test func theFoldRemembersWhetherItsOpenOnThisMac() {
        let (model, _, _) = Self.model()
        defer {
            UserDefaults.standard.removeObject(forKey: WindowModel.endedOpenKey)
            UserDefaults.standard.removeObject(forKey: WindowModel.homeEndedOpenKey)
        }
        #expect(!model.endedOpen && !model.homeEndedOpen)
        model.endedOpen = true
        #expect(WindowModel().endedOpen)
        #expect(!WindowModel().homeEndedOpen)
        model.homeEndedOpen = true
        model.endedOpen = false
        let again = WindowModel()
        #expect(!again.endedOpen && again.homeEndedOpen)
    }

    /// A team's ended members stay with their lead (its Team view and history rule), not in Home's fold.
    @Test func aLeadsTeamStaysOutOfHomesFold() {
        let model = WindowModel()
        let lead = Self.hosted("Lead", project: "acme", exit: nil, label: "Lead · acme")
        let worker = Self.hosted("Worker", project: "acme", exit: 129, label: "Worker: One", cwd: "/Users/you/dev/acme/.vibeswitcher/worktrees/one")
        let plain = Self.hosted("Plain", project: "acme", exit: 143)
        model.update(sessions: [], hosted: [lead, worker, plain], table: TableRead(at: Self.now))
        #expect(model.endedRows.map(\.id) == ["host:\(plain.id)"])
    }
}

/// Pictures of ended rows, drawn offscreen in a real window, light and dark: the sidebar itself (`SessionListView`)
/// with its "Ended (n)" fold closed and open, holding a session ended by VibeSwitcher (129), a failed one (exit 1)
/// and a finished one (0); the ended bar for each; Home's fold. Only with
/// `ENDED_SNAPSHOT_DIR=/some/folder scripts/test.sh --filter EndedSnapshots`.
@MainActor
struct EndedSnapshots {
    static let folder = ProcessInfo.processInfo.environment["ENDED_SNAPSHOT_DIR"]

    static let actions = WindowActions(
        newSession: { _, _ in }, endSession: { _ in }, resume: { _ in }, remove: { _ in }, rename: { _ in },
        pause: { _, _ in }, resumePaused: { _ in }, openInTerminal: { _ in }, presets: { _ in [] }, isLive: { _ in false },
        canResume: { $0.end?.isFailure == false }, resumeCommand: { _ in nil }, settings: {}, moveToWindow: { _ in }, startLead: { _ in })

    func render(_ view: some View, size: NSSize, appearance: NSAppearance.Name) throws -> Data {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: size.width, height: size.height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let frame = try #require(window.contentView)
        frame.layoutSubtreeIfNeeded()
        frame.displayIfNeeded()
        let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    func write(_ view: some View, name: String, folder: String, size: NSSize) throws {
        for scheme in [NSAppearance.Name.aqua, .darkAqua] {
            let data = try render(view, size: size, appearance: scheme)
            try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(scheme == .darkAqua ? "dark" : "light").png"))
        }
    }

    @Test(.enabled(if: folder != nil)) func drawEndedRows() throws {
        let folder = try #require(Self.folder)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let (model, ended, _) = EndedFoldTests.model()
        defer {
            UserDefaults.standard.removeObject(forKey: WindowModel.endedOpenKey)
            UserDefaults.standard.removeObject(forKey: WindowModel.homeEndedOpenKey)
        }
        // A client and store that reach nothing: the list only asks them for leads' boards (none here).
        let scratch = FileManager.default.temporaryDirectory
        let host = HostClient(socketPath: scratch.appendingPathComponent("no-host.sock").path)
        let store = SessionStore(scanner: SessionScanner(processes: { [:] }, stateDir: { scratch }, cwd: { _ in nil }, arguments: { _ in [] }))
        let leads = LeadController(host: host, store: store, vault: LeadVault(folder: scratch.appendingPathComponent("vault"), ask: { _ in throw LeadVault.Refused("none") }),
                                   inbox: scratch, home: scratch.path) { _ in "true" }
        model.selectedID = model.rows.first?.id
        model.endedOpen = false
        try write(SessionListView(model: model, leads: leads, actions: Self.actions), name: "sidebar-ended-folded", folder: folder, size: NSSize(width: 300, height: 330))
        model.endedOpen = true
        try write(SessionListView(model: model, leads: leads, actions: Self.actions), name: "sidebar-ended-open", folder: folder, size: NSSize(width: 300, height: 480))

        // The ended bar under each one's terminal.
        let selected = ended.map { info -> WindowModel in
            let one = WindowModel()
            one.update(sessions: [], hosted: [info], table: TableRead(at: EndedFoldTests.now))
            one.selectedID = "host:\(info.id)"
            return one
        }
        let bars = VStack(spacing: 6) {
            ForEach(selected.indices, id: \.self) { EndedBar(model: selected[$0], actions: Self.actions) }
        }
        try write(bars, name: "ended-bar", folder: folder, size: NSSize(width: 560, height: 140))

        // Home's fold, open.
        let home = EndedSessions(rows: model.endedRows, open: .constant(true), model: model, actions: Self.actions).padding(16)
        try write(home, name: "home-ended", folder: folder, size: NSSize(width: 620, height: 250))
    }
}
