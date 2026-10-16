import AppKit
import Combine
import SwiftUI
import VibeCore

/// The main window: sessions by project | the selected session's terminal | inspector.
/// While it's open the app is a regular app (Dock icon, ⌘-Tab); closing it goes back to menu bar only.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    let model: WindowModel
    let pane: TerminalPaneController
    /// ⌘+ (1), ⌘− (−1), ⌘0 (0 = default size).
    var onFontSize: (Int) -> Void = { _ in }

    private let store: SessionStore
    private let host: HostClient
    private let actions: WindowActions
    private let split = NSSplitViewController()
    private var inspectorItem: NSSplitViewItem!
    private let palette = CommandPaletteController()
    private lazy var endedBar = NSHostingView(rootView: EndedBar(model: model, actions: actions))
    private var shownID: String?
    private var cancellables: Set<AnyCancellable> = []

    init(store: SessionStore, host: HostClient, model: WindowModel, actions: WindowActions) {
        self.store = store
        self.host = host
        self.model = model
        self.actions = actions
        pane = TerminalPaneController(host: host)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "VibeSwitcher"
        // The session bar shows the title; the window's title still names the session in ⌘` and Mission Control.
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 420)
        super.init(window: window)
        window.delegate = self

        let sidebar = NSSplitViewItem(sidebarWithViewController: NSHostingController(
            rootView: SessionListView(model: model, host: host, actions: actions)))
        sidebar.minimumThickness = 260
        sidebar.maximumThickness = 380
        let middle = NSViewController()
        middle.view = makeMiddle()
        let content = NSSplitViewItem(viewController: middle)
        content.minimumThickness = 420
        inspectorItem = NSSplitViewItem(inspectorWithViewController: NSHostingController(
            rootView: InspectorView(model: model, host: host)))
        inspectorItem.minimumThickness = 240
        inspectorItem.maximumThickness = 380
        inspectorItem.isCollapsed = UserDefaults.standard.object(forKey: "inspectorCollapsed") as? Bool ?? false
        split.splitViewItems = [sidebar, content, inspectorItem]
        // Renamed when the pane limits changed, so widths saved under the old limits don't squeeze the terminal.
        split.splitView.autosaveName = "MainWindowSplit2"
        window.contentViewController = split
        // Setting the content view controller sizes the window to its view's initial frame.
        window.setContentSize(NSSize(width: 1280, height: 800))

        let toolbar = NSToolbar(identifier: "MainWindow")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        if !window.setFrameUsingName("MainWindow") { window.center() }
        window.setFrameAutosaveName("MainWindow")

        model.$selectedID.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.showSelection() } }
            .store(in: &cancellables)
        model.$sections.receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.showSelection() } }
            .store(in: &cancellables)
        host.$sessions.receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                guard let self else { return }
                let known = Set(sessions.map(\.id))
                self.pane.attachedIDs.filter { !known.contains($0) }.forEach(self.pane.forget)
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func makeMiddle() -> NSView {
        let header = NSHostingView(rootView: SessionHeaderView(model: model, host: host, actions: actions))
        let divider = NSBox()
        divider.boxType = .separator
        endedBar.isHidden = true
        let stack = NSStackView(views: [header, divider, pane.view, endedBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        for view in [header, divider, pane.view, endedBar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        header.heightAnchor.constraint(equalToConstant: 52).isActive = true
        endedBar.heightAnchor.constraint(equalToConstant: 40).isActive = true
        pane.view.setContentHuggingPriority(.defaultLow, for: .vertical)
        // The window's content runs under the toolbar; start below it.
        let container = NSView()
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func present() {
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        shownID = nil
        showSelection()
    }

    private func showSelection() {
        guard window?.isVisible == true else { return }
        defer {
            updateViewing()
            updateTitleAndBadge()
        }
        guard let row = model.selectedRow else {
            guard shownID != "" else { return }
            shownID = ""
            endedBar.isHidden = true
            pane.show(placeholder: AnyView(StartPage(model: model, actions: actions)))
            return
        }
        endedBar.isHidden = row.hosted?.exit == nil
        if let id = row.hostID {
            if pane.current != id { pane.show(hostID: id) }
        } else if let session = row.session, shownID != row.id {
            pane.show(placeholder: AnyView(TerminalMirror(session: session) { [weak self] in
                self?.actions.openInTerminal(session)
            }))
        }
        shownID = row.id
    }

    /// The window's title names the selected session; the Dock badge counts sessions waiting on you.
    private func updateTitleAndBadge() {
        window?.title = model.selectedRow.map { "\($0.title) — \($0.project)" } ?? "VibeSwitcher"
        guard window?.isVisible == true else { return }
        let waiting = model.allRows.filter { $0.state(now: Date()).group == .needsYou }.count
        NSApp.dockTile.badgeLabel = waiting > 0 ? "\(waiting)" : nil
    }

    private func updateViewing() {
        let row = model.selectedRow
        store.windowViewingTTY = window?.isKeyWindow == true && row?.hostID != nil ? row?.session?.tty : nil
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        updateViewing()
        pane.focus()
    }

    func windowDidResignKey(_ notification: Notification) { updateViewing() }

    func windowWillClose(_ notification: Notification) {
        store.windowViewingTTY = nil
        palette.close()
        NSApp.dockTile.badgeLabel = nil
        pane.detachAll()
        shownID = nil
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: Toolbar

    private static let newItem = NSToolbarItem.Identifier("newSession")
    private static let homeItem = NSToolbarItem.Identifier("startPage")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Self.homeItem, .flexibleSpace, Self.newItem, .inspectorTrackingSeparator,
         .flexibleSpace, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == Self.homeItem {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Start Page"
            item.toolTip = "Recent projects and shortcuts (⇧⌘H)"
            item.image = NSImage(systemSymbolName: "house", accessibilityDescription: "Start Page")
            item.target = self
            item.action = #selector(showHomeAction(_:))
            return item
        }
        guard identifier == Self.newItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "New Session"
        item.toolTip = "New session in the selected project (⌘N)"
        item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Session")
        item.target = self
        item.action = #selector(newSessionAction(_:))
        return item
    }

    // MARK: Menu actions (reached through the responder chain)

    private var selectedFolder: String? { model.selectedRow?.cwd }

    @objc func newSessionAction(_ sender: Any?) { actions.newSession(nil, selectedFolder) }

    @objc func newShellAction(_ sender: Any?) {
        actions.newSession(actions.presets(selectedFolder).first { $0.kind == .shell }, selectedFolder)
    }

    @objc func endSessionAction(_ sender: Any?) {
        guard let row = model.selectedRow, row.hostID != nil, actions.isLive(row) else { return NSSound.beep() }
        actions.endSession(row)
    }

    @objc func nextSession(_ sender: Any?) { model.move(by: 1) }
    @objc func previousSession(_ sender: Any?) { model.move(by: -1) }
    @objc func nextNeedingYou(_ sender: Any?) { model.selectNextNeedingYou() }
    @objc func selectSessionByTag(_ sender: NSMenuItem) { model.select(index: sender.tag - 1) }

    @objc func toggleInspectorAction(_ sender: Any?) {
        inspectorItem.animator().isCollapsed.toggle()
        // The animator proxy already reports the new value.
        UserDefaults.standard.set(inspectorItem.isCollapsed, forKey: "inspectorCollapsed")
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(groupByAttention(_:)): menuItem.state = model.grouping == .attention ? .on : .off
        case #selector(groupByProjects(_:)): menuItem.state = model.grouping == .projects ? .on : .off
        case #selector(openInTerminalAction(_:)): return model.selectedRow?.session?.inTerminalApp == true
        default: break
        }
        return true
    }

    @objc func showHomeAction(_ sender: Any?) { model.showHome() }

    @objc func showPaletteAction(_ sender: Any?) {
        guard let window else { return }
        if palette.isShown { return palette.close() }
        palette.show(over: window, items: paletteItems())
    }

    /// Sessions (in attention order), window commands, then "New <preset> in <project>" for recent projects.
    private func paletteItems() -> [PaletteItem] {
        let now = Date()
        let sessions = WindowGroups.attention(model.sections).flatMap(\.rows).map { row in
            let state = row.state(now: now)
            var subtitle = "\(row.project) · \(state.text)"
            if let since = state.since { subtitle += " · \(Durations.compact(now.timeIntervalSince(since)))" }
            return PaletteItem(id: row.id, title: row.title, subtitle: subtitle, icon: .mark(row.markKind, row.statusColor)) {
                [weak self] in self?.model.selectedID = row.id
            }
        }
        func command(_ title: String, _ symbol: String, _ keys: String, _ action: Selector) -> PaletteItem {
            PaletteItem(id: "cmd:\(title)", title: title, subtitle: keys, icon: .symbol(symbol)) {
                NSApp.sendAction(action, to: nil, from: nil)
            }
        }
        let folder = selectedFolder.map { ($0 as NSString).lastPathComponent }
        var commands = [
            command("Next Session Needing You", "exclamationmark.bubble", "⌘J", #selector(nextNeedingYou(_:))),
            command(folder.map { "New Session in \($0)" } ?? "New Session…", "plus", "⌘N", #selector(newSessionAction(_:))),
            command(folder.map { "New Shell in \($0)" } ?? "New Shell…", "terminal", "⌥⌘N", #selector(newShellAction(_:))),
            command("Start Page", "house", "⇧⌘H", #selector(showHomeAction(_:))),
            command("Group by Attention", "exclamationmark.circle", "⌃⌘1", #selector(groupByAttention(_:))),
            command("Group by Project", "folder", "⌃⌘2", #selector(groupByProjects(_:))),
            command("Filter Sessions", "line.3.horizontal.decrease", "⌥⌘F", #selector(focusFilterAction(_:))),
            command("Toggle Inspector", "sidebar.right", "⌥⌘0", #selector(toggleInspectorAction(_:))),
            command("Toggle Sidebar", "sidebar.left", "⌃⌘S", #selector(NSSplitViewController.toggleSidebar(_:))),
        ]
        if model.selectedRow?.session?.inTerminalApp == true {
            commands.insert(command("Open in Terminal", "arrow.up.forward.app", "⌘O", #selector(openInTerminalAction(_:))), at: 1)
        }
        commands.append(PaletteItem(id: "cmd:settings", title: "Settings…", subtitle: "⌘,", icon: .symbol("gearshape")) {
            [weak self] in self?.actions.settings()
        })
        let launches = model.recentProjects.prefix(12).flatMap { path in
            actions.presets(path).map { preset in
                PaletteItem(id: "new:\(path):\(preset.id)", title: "New \(preset.name) in \((path as NSString).lastPathComponent)",
                            subtitle: path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), icon: .symbol("play.circle")) {
                    [weak self] in self?.actions.newSession(preset, path)
                }
            }
        }
        return sessions + commands + launches
    }
    @objc func groupByAttention(_ sender: Any?) { model.grouping = .attention }
    @objc func groupByProjects(_ sender: Any?) { model.grouping = .projects }
    @objc func focusFilterAction(_ sender: Any?) { model.focusFilter() }

    @objc func openInTerminalAction(_ sender: Any?) {
        guard let session = model.selectedRow?.session, session.inTerminalApp else { return NSSound.beep() }
        actions.openInTerminal(session)
    }

    @objc func biggerFont(_ sender: Any?) { onFontSize(1) }
    @objc func smallerFont(_ sender: Any?) { onFontSize(-1) }
    @objc func actualSizeFont(_ sender: Any?) { onFontSize(0) }
    @objc func clearScrollbackAction(_ sender: Any?) { pane.clearScrollback() }
}
