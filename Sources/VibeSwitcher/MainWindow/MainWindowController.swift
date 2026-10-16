import AppKit
import Combine
import SwiftUI
import VibeCore

/// The main window: sessions by project | the selected session's terminal | inspector.
/// While it's open the app is a regular app (Dock icon, ⌘-Tab); closing it goes back to menu bar only.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let model: WindowModel
    let pane: TerminalPaneController
    /// ⌘+ (1), ⌘− (−1), ⌘0 (0 = default size).
    var onFontSize: (Int) -> Void = { _ in }

    private let store: SessionStore
    private let host: HostClient
    private let actions: WindowActions
    private let split = NSSplitViewController()
    private var inspectorItem: NSSplitViewItem!
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
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 420)
        super.init(window: window)
        window.delegate = self

        let sidebar = NSSplitViewItem(sidebarWithViewController: NSHostingController(
            rootView: SessionListView(model: model, host: host, actions: actions)))
        sidebar.minimumThickness = 220
        sidebar.maximumThickness = 420
        let middle = NSViewController()
        middle.view = makeMiddle()
        let content = NSSplitViewItem(viewController: middle)
        content.minimumThickness = 420
        inspectorItem = NSSplitViewItem(inspectorWithViewController: NSHostingController(
            rootView: InspectorView(model: model, host: host)))
        inspectorItem.minimumThickness = 220
        inspectorItem.maximumThickness = 420
        inspectorItem.isCollapsed = UserDefaults.standard.object(forKey: "inspectorCollapsed") as? Bool ?? false
        split.splitViewItems = [sidebar, content, inspectorItem]
        split.splitView.autosaveName = "MainWindowSplit"
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
        let stack = NSStackView(views: [header, divider, pane.view])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        for view in [header, divider, pane.view] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        header.heightAnchor.constraint(equalToConstant: 40).isActive = true
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
        defer { updateViewing() }
        guard let row = model.selectedRow else {
            guard shownID != "" else { return }
            shownID = ""
            pane.show(placeholder: AnyView(EmptySessionView { [weak self] in self?.actions.newSession(nil, nil) }))
            return
        }
        if let id = row.hostID {
            if pane.current != id { pane.show(hostID: id) }
        } else if let session = row.session, shownID != row.id {
            pane.show(placeholder: AnyView(TerminalAppPlaceholder(session: session) { [weak self] in
                self?.actions.openInTerminal(session)
            }))
        }
        shownID = row.id
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
        pane.detachAll()
        shownID = nil
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: Toolbar

    private static let newItem = NSToolbarItem.Identifier("newSession")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.newItem, .inspectorTrackingSeparator,
         .flexibleSpace, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
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

    @objc func biggerFont(_ sender: Any?) { onFontSize(1) }
    @objc func smallerFont(_ sender: Any?) { onFontSize(-1) }
    @objc func actualSizeFont(_ sender: Any?) { onFontSize(0) }
    @objc func clearScrollbackAction(_ sender: Any?) { pane.clearScrollback() }
}
