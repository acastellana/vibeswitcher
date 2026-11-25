import AppKit
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// View › Focus Terminal: the terminal takes the whole window (sidebar, inspector and session bar hidden, the chat
/// off); used again, the layout before comes back. Kept in the defaults while it's on, so a window made again (a
/// reopen after a relaunch) starts focused, and comes back to the layout from before. The window is never shown.
@MainActor
@Suite(.serialized) struct FocusTerminalTests {
    let temp = Scratch()
    /// This test's own defaults, where its windows keep their layout: each window made in a test shares them, as the
    /// app's windows share the app's (the standard defaults are every test process's on this Mac).
    let defaults: UserDefaults

    init() { defaults = temp.defaults("focus-terminal-defaults") }

    func window() throws -> MainWindowController {
        _ = NSApplication.shared
        let scratch = temp.url("focus-terminal")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let host = HostClient(socketPath: scratch.appendingPathComponent("no-host.sock").path)
        let store = SessionStore(scanner: SessionScanner(processes: { [:] }, stateDir: { scratch }, cwd: { _ in nil }, arguments: { _ in [] }))
        let leads = LeadController(host: host, store: store, vault: LeadVault(folder: scratch.appendingPathComponent("vault"), ask: { _ in throw LeadVault.Refused("none") }),
                                   inbox: scratch, home: scratch.path) { _ in "true" }
        return MainWindowController(store: store, host: host, model: WindowModel(defaults: defaults), actions: EndedSnapshots.actions, leads: leads)
    }

    /// The split's items: sidebar, middle, inspector.
    func collapsed(_ controller: MainWindowController) -> [Bool] {
        (controller.window?.contentViewController as? NSSplitViewController)?.splitViewItems.map(\.isCollapsed) ?? []
    }

    /// The layout before: set on the items (the split's autosave may hold what an earlier window left).
    func arrange(_ controller: MainWindowController, sidebarCollapsed: Bool, inspectorCollapsed: Bool) {
        let items = (controller.window?.contentViewController as? NSSplitViewController)?.splitViewItems ?? []
        items.first?.isCollapsed = sidebarCollapsed
        items.last?.isCollapsed = inspectorCollapsed
    }

    func sessionBarShown(_ controller: MainWindowController) -> Bool {
        controller.window?.titleVisibility == .hidden
    }

    @Test func itHidesTheSidebarAndInspectorAndComesBack() throws {
        defaults.set(false, forKey: "inspectorCollapsed")
        let controller = try window()
        controller.model.showsChat = true
        arrange(controller, sidebarCollapsed: false, inspectorCollapsed: false)
        #expect(collapsed(controller) == [false, false, false])
        let item = NSMenuItem(title: "Focus Terminal", action: #selector(MainWindowController.focusTerminalAction(_:)), keyEquivalent: "")
        #expect(controller.validateMenuItem(item) && item.state == .off)

        controller.focusTerminalAction(nil)
        #expect(collapsed(controller) == [true, false, true])
        #expect(!controller.model.showsChat && !sessionBarShown(controller))
        #expect(controller.validateMenuItem(item) && item.state == .on)
        #expect(MainWindowController.FocusLayout.saved(in: defaults) == .init(sidebarCollapsed: false, inspectorCollapsed: false, showsChat: true))

        controller.focusTerminalAction(nil)
        #expect(collapsed(controller) == [false, false, false])
        #expect(controller.model.showsChat && sessionBarShown(controller))
        #expect(controller.validateMenuItem(item) && item.state == .off)
        #expect(MainWindowController.FocusLayout.saved(in: defaults) == nil)
        // The inspector's own setting isn't touched by focus mode.
        #expect(defaults.object(forKey: "inspectorCollapsed") as? Bool == false)
    }

    @Test func aWindowMadeAgainStaysFocusedAndRestoresTheLayoutFromBefore() throws {
        // Before: the inspector hidden, the sidebar shown, the chat on.
        defaults.set(true, forKey: "inspectorCollapsed")
        let first = try window()
        first.model.showsChat = true
        arrange(first, sidebarCollapsed: false, inspectorCollapsed: true)
        #expect(collapsed(first) == [false, false, true])
        first.focusTerminalAction(nil)
        #expect(collapsed(first) == [true, false, true])
        // Closed and opened again: still focused.
        first.close()
        #expect(first.focusedFrom != nil && collapsed(first) == [true, false, true])

        let reopened = try window()
        #expect(collapsed(reopened) == [true, false, true])
        #expect(!sessionBarShown(reopened) && !reopened.model.showsChat)
        #expect(reopened.focusedFrom == .init(sidebarCollapsed: false, inspectorCollapsed: true, showsChat: true))
        reopened.focusTerminalAction(nil)
        #expect(collapsed(reopened) == [false, false, true])
        #expect(sessionBarShown(reopened) && reopened.model.showsChat)
    }
}
