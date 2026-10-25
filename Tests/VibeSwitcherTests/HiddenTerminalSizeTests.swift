import AppKit
import SwiftUI
import Testing
import VibeCore
@testable import VibeSwitcher

/// 2026-10-25: "Brief me on vibeswitcher" open in the lead's Team tab (a wrapping text sized to fit) grew the window
/// downwards past the screen to some 6,000 points, through the inspector's hosting controller; the leads' views made
/// behind their chats in it attached their Claude sessions at 116×392, which reflowed their screens. A terminal is never
/// attached or resized at a size it doesn't have on screen: behind the chat a view keeps its session's size, the first
/// real layout sends the pane's, and a size no screen has never reaches the host. On a scratch host running scratch
/// shells (`TerminalPaneReleaseTests.Pane`), each spawned at 100×30; never the user's sessions.
@MainActor
@Suite(.serialized)
struct HiddenTerminalSizeTests {
    typealias Pane = TerminalPaneReleaseTests.Pane

    /// The pane as the window had it: as tall as a window grown past the screen.
    static let grown = NSRect(x: 0, y: 0, width: 1100, height: 6_000)
    /// The pane as the window has it on screen.
    static let real = NSRect(x: 0, y: 0, width: 1100, height: 700)

    /// Once the host has answered a request sent after everything before it: the sizes it told by then are in.
    func settled(_ p: Pane, _ id: UUID) async {
        var answered = false
        p.host.screen(id) { _ in answered = true }
        #expect(await until { answered }, "the host never answered")
    }

    /// The session's PTY size, as the host has it once it's settled.
    func ptySize(_ p: Pane, _ id: UUID) async -> [Int] {
        await settled(p, id)
        return p.host.size(of: id).map { [$0.cols, $0.rows] } ?? []
    }

    func viewSize(_ p: Pane, _ id: UUID) -> [Int] {
        p.pane.terminalView(id).map { [$0.getTerminal().cols, $0.getTerminal().rows] } ?? []
    }

    /// Waits until the session's view shows its name, and so has been attached and drawn from the host.
    func drawn(_ p: Pane, _ id: UUID, _ name: String) async {
        #expect(await until { p.pane.screenLines(id).contains("\(name) ready") }, "\(name) never reached its view")
    }

    @Test func aLeadsViewMadeBehindItsChatKeepsTheSessionsSizeUntilItsShown() async throws {
        let p = try Pane()
        let lead = try await p.spawn("lead")
        #expect(p.host.size(of: lead).map { [$0.cols, $0.rows] } == [100, 30])
        // The chat covers the pane, in a window grown past the screen; the lead's terminal was never shown.
        p.pane.covered = true
        p.pane.view.frame = Self.grown
        p.pane.show(hostID: lead, focus: false)
        await drawn(p, lead, "lead")
        #expect(await ptySize(p, lead) == [100, 30])
        #expect(viewSize(p, lead) == [100, 30])

        // The window back to its size, then the terminal shown: the pane's size, sent once.
        p.pane.view.frame = Self.real
        p.pane.covered = false
        let shown = viewSize(p, lead)
        #expect(shown.count == 2 && shown != [100, 30] && HostClient.isRealSize(cols: shown[0], rows: shown[1]))
        #expect(await ptySize(p, lead) == shown)
    }

    @Test func openingTheChatAndBackKeepsTheTerminalsSizeAndThenSendsTheRealOne() async throws {
        let p = try Pane()
        let id = try await p.spawn("alpha")
        await p.show(id, "alpha")
        let onScreen = viewSize(p, id)
        #expect(await ptySize(p, id) == onScreen)

        // The chat opened, and the pane laid out at no real size under it: nothing reaches the session.
        p.pane.covered = true
        p.pane.view.frame = Self.grown
        #expect(await ptySize(p, id) == onScreen)
        p.pane.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 0)
        #expect(await ptySize(p, id) == onScreen)

        // Back to the terminal in a window that's smaller than before: the size it has now.
        p.pane.view.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        p.pane.covered = false
        let smaller = viewSize(p, id)
        #expect(smaller != onScreen && HostClient.isRealSize(cols: smaller[0], rows: smaller[1]))
        #expect(await ptySize(p, id) == smaller)

        // And the chat again, then the terminal at the same size: still that.
        p.pane.covered = true
        p.pane.covered = false
        #expect(viewSize(p, id) == smaller)
        #expect(await ptySize(p, id) == smaller)
    }

    @Test func aViewOnScreenAtNoRealSizeNeverSendsIt() async throws {
        let p = try Pane()
        let a = try await p.spawn("alpha"), b = try await p.spawn("beta")
        // Shown in a pane far taller than any screen: attached at the session's size.
        p.pane.view.frame = Self.grown
        await p.show(a, "alpha")
        #expect(await ptySize(p, a) == [100, 30])
        // A pane squeezed to almost nothing: its size isn't sent either.
        await p.show(b, "beta")
        p.pane.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 40)
        #expect(viewSize(p, b).last.map { $0 < HostClient.realRows.lowerBound } == true)
        #expect(await ptySize(p, b) == [100, 30])
        // Asked straight: refused too, and the host keeps what it had.
        p.host.resize(a, cols: 116, rows: 392, reason: .shown)
        p.host.resize(a, cols: 116, rows: 2, reason: .shown)
        #expect(await ptySize(p, a) == [100, 30])
        // A real size goes.
        p.pane.view.frame = Self.real
        let real = viewSize(p, b)
        #expect(await ptySize(p, b) == real)
    }

    @Test func realSizesAreTheOnesAScreenCanHave() {
        #expect(HostClient.isRealSize(cols: 116, rows: 56))
        #expect(HostClient.isRealSize(cols: 10, rows: 5) && HostClient.isRealSize(cols: 1_000, rows: 300))
        #expect(!HostClient.isRealSize(cols: 116, rows: 392))
        #expect(!HostClient.isRealSize(cols: 116, rows: 4))
        #expect(!HostClient.isRealSize(cols: 9, rows: 40) && !HostClient.isRealSize(cols: 1_001, rows: 40))
    }
}

/// The window's side panes are sized by the split and the window, never by their content: a content's smallest size
/// (SwiftUI's, taken at no width) once grew the window to thousands of points. The window is never shown.
@MainActor
@Suite(.serialized) struct SidePaneSizeTests {
    let temp = Scratch()

    func window() throws -> MainWindowController {
        _ = NSApplication.shared
        let scratch = temp.url("side-panes")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let host = HostClient(socketPath: scratch.appendingPathComponent("no-host.sock").path)
        let store = SessionStore(scanner: SessionScanner(processes: { [:] }, stateDir: { scratch }, cwd: { _ in nil }, arguments: { _ in [] }))
        let leads = LeadController(host: host, store: store, vault: LeadVault(folder: scratch.appendingPathComponent("vault"), ask: { _ in throw LeadVault.Refused("none") }),
                                   inbox: scratch, home: scratch.path) { _ in "true" }
        return MainWindowController(store: store, host: host, model: WindowModel(), actions: EndedSnapshots.actions, leads: leads)
    }

    /// What the briefing panel holds: a wrapping text sized to fit, and the Team tab's scroll view under it.
    static var tall: AnyView {
        AnyView(VStack(spacing: 0) {
            Text(String(repeating: "What landed, what's running, what's blocked. ", count: 14)).fixedSize(horizontal: false, vertical: true)
            ScrollView { Text("Tasks") }
        })
    }

    @Test func aTallSidePaneDoesntGrowTheWindow() throws {
        let controller = try window()
        let window = try #require(controller.window)
        let split = try #require(window.contentViewController as? NSSplitViewController)
        let saved = split.splitViewItems.map(\.isCollapsed)
        defer { zip(split.splitViewItems, saved).forEach { $0.isCollapsed = $1 } }
        split.splitViewItems.forEach { $0.isCollapsed = false }
        window.setFrame(NSRect(x: 0, y: 64, width: 1728, height: 1015), display: false)
        window.contentView?.layoutSubtreeIfNeeded()
        let before = window.frame
        for item in [split.splitViewItems.first, split.splitViewItems.last] {
            let host = try #require(item?.viewController as? NSHostingController<AnyView>)
            host.rootView = Self.tall
        }
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(window.frame == before)
        #expect(split.splitViewItems[1].viewController.view.frame.height <= before.height)
    }
}
