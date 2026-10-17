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
    /// What the middle shows for a Terminal session: its mirror (with or without Move to Window), or nothing while
    /// the chat covers it (the mirror reads Terminal every few seconds). Rebuilt when that changes.
    private var mirrorState: String?
    private var endedBar: NSView { endedHost }
    private var shownID: String?
    private var cancellables: Set<AnyCancellable> = []
    /// The selected session's conversation, shown over the terminal (which stays attached underneath).
    let chat = ChatModel()
    private lazy var chatHost = NSHostingView(rootView: AnyView(EmptyView()))
    private lazy var endedHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let sidebarHost = NSHostingController(rootView: AnyView(EmptyView()))
    private let inspectorHost = NSHostingController(rootView: AnyView(EmptyView()))
    private let headerHost = NSHostingView(rootView: AnyView(EmptyView()))
    /// Whether the window's SwiftUI views are in place. A closed window keeps its views, and with them their
    /// observers and tasks (git runs, transcript reads on every hook event): they come down on close.
    private var mounted = false

    private func makeChat() -> AnyView {
        AnyView(ChatContainer(
        chat: chat, model: model, leads: leads, actions: actions,
        composer: ComposerActions(send: { [weak self] text in self?.sendToSelected(text) ?? false },
                                  steer: { [weak self] text in self?.steerSelected(text) ?? false },
                                  stop: { [weak self] in self?.sendKeys([27]) },
                                  cycleMode: { [weak self] in self?.sendKeys(AgentMode.cycleKey) }),
        choose: { [weak self] index, typing in self?.chooseMenuOption(index, typing: typing) },
        moveTab: { [weak self] delta in
            guard delta != 0 else { return }
            self?.sendKeys(Array(repeating: delta > 0 ? [27, 91, 67] : [27, 91, 68], count: abs(delta)).flatMap { $0 })
        },
        showTerminal: { [weak self] in self?.model.showsChat = false }))
    }

    private func mountViews() {
        guard !mounted else { return }
        mounted = true
        sidebarHost.rootView = AnyView(SessionListView(model: model, leads: leads, actions: actions))
        inspectorHost.rootView = AnyView(InspectorView(model: model, host: host, leads: leads))
        headerHost.rootView = AnyView(SessionHeaderView(model: model, host: host, actions: actions))
        endedHost.rootView = AnyView(EndedBar(model: model, actions: actions))
        chatHost.rootView = makeChat()
    }

    private func unmountViews() {
        guard mounted else { return }
        mounted = false
        for host in [sidebarHost, inspectorHost] { host.rootView = AnyView(EmptyView()) }
        for host in [headerHost, endedHost, chatHost] { host.rootView = AnyView(EmptyView()) }
    }

    /// Follows the transcript while the chat is on screen.
    private var chatTimer: Heartbeat.Subscription?

    let leads: LeadController

    init(store: SessionStore, host: HostClient, model: WindowModel, actions: WindowActions, leads: LeadController) {
        self.leads = leads
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

        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebar.minimumThickness = 260
        sidebar.maximumThickness = 380
        let middle = NSViewController()
        middle.view = makeMiddle()
        let content = NSSplitViewItem(viewController: middle)
        content.minimumThickness = 420
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorHost)
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

        chat.runner.run = { [weak self] prompt in
            guard let self else { return false }
            let working = self.model.selectedRow?.session?.status == .working
            guard self.sendToSelected(prompt) else { return false }
            Breadcrumbs.shared.note("chat: ran a code block (\(prompt.count) chars)")
            self.chat.sent(prompt, expectsSoon: !working)
            self.chat.scrollToBottom()
            return true
        }
        model.$selectedID.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.showSelection() } }
            .store(in: &cancellables)
        model.$sections.receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.showSelection()
                    // Also while minimized, when showSelection does nothing: that's when the Dock is looked at.
                    self?.updateTitleAndBadge()
                }
            }
            .store(in: &cancellables)
        leads.$boards.receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateTitleAndBadge() } }
            .store(in: &cancellables)
        model.$showsChat.removeDuplicates().receive(on: RunLoop.main)
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
        let header = headerHost
        let divider = NSBox()
        divider.boxType = .separator
        endedBar.isHidden = true
        // Their size comes from the stack. Left to their content, an empty bar asks to be zero wide, which
        // pins the whole middle pane (and so the window) at its minimum width.
        header.sizingOptions = []
        endedHost.sizingOptions = []
        // The terminal and the chat share the space; the chat covers the terminal when shown.
        let body = NSView()
        chatHost.sizingOptions = []
        for view in [pane.view, chatHost] {
            view.frame = body.bounds
            view.autoresizingMask = [.width, .height]
            body.addSubview(view)
        }
        chatHost.isHidden = true
        let stack = NSStackView(views: [header, divider, body, endedBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        for view in [header, divider, body, endedBar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        header.heightAnchor.constraint(equalToConstant: 52).isActive = true
        endedBar.heightAnchor.constraint(equalToConstant: 40).isActive = true
        body.setContentHuggingPriority(.defaultLow, for: .vertical)
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

    /// For the hang watchdog: what the window shows right now.
    func debugState() -> String {
        let row = model.selectedRow
        let frame = window.map { NSStringFromRect($0.frame) } ?? "none"
        let draft = row.map { chat.composer.drafts[$0.draftKey]?.count ?? 0 } ?? 0
        return """
        window visible=\(window?.isVisible == true) key=\(window?.isKeyWindow == true) frame=\(frame) mounted=\(mounted)
        selected=\(row?.id ?? "none") project=\(row?.project ?? "") showsChat=\(model.showsChat) chatShown=\(!chatHost.isHidden) terminalHidden=\(pane.view.isHidden)
        chat path=\(chat.path ?? "none") state=\(chat.state) entries=\(chat.log.entries.count) items=\(chat.items.count) shownLimit=\(chat.shownLimit) atBottom=\(chat.atBottom) pending=\(chat.pending.count) menu=\(chat.menu != nil) draft=\(draft) chars
        attached terminals=\(pane.attachedIDs.count) current=\(pane.current?.uuidString ?? "none")
        """
    }

    func present() {
        Breadcrumbs.shared.note("window: present")
        mountViews()
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // Activation is cooperative (macOS 14+): with no app yielding (at login, after an update, from a hang) the
        // app isn't made active and its window would open behind the others. Bring the window up regardless; the
        // first click then activates the app.
        window?.orderFrontRegardless()
        // Right after becoming a regular app, a polite activate often doesn't take (the app lands last in ⌘-Tab,
        // behind the frontmost one): ask again, firmly, on the next turn of the run loop.
        NSApp.activate()
        DispatchQueue.main.async { [weak self] in
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            self?.window?.makeKeyAndOrderFront(nil)
            self?.window?.orderFrontRegardless()
        }
        shownID = nil
        showSelection()
    }

    /// `--idle-bench`: the window up but off screen, without a Dock icon or taking the keyboard.
    func presentOffscreen() {
        mountViews()
        window?.setFrame(NSRect(x: -20_000, y: -20_000, width: 1280, height: 800), display: false)
        window?.orderFrontRegardless()
        window?.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        shownID = nil
        showSelection()
    }

    private func showSelection() {
        guard window?.isVisible == true else { return }
        defer {
            updateChat()
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
        if shownID != row.id { Breadcrumbs.shared.note("window: select \(row.id) (\(row.project))") }
        if let id = row.hostID {
            if pane.current != id { pane.show(hostID: id, focus: !model.chatShown) }
        } else if let session = row.session {
            let covered = model.showsChat && model.chatPath(for: row) != nil
            let wanted = covered ? "covered" : MoveToWindow.canMove(session) ? "mirror+move" : "mirror"
            if shownID != row.id || wanted != mirrorState {
                mirrorState = wanted
                if covered {
                    pane.show(placeholder: AnyView(EmptyView()))
                } else {
                    let move: (() -> Void)? = MoveToWindow.canMove(session) ? { [weak self] in self?.actions.moveToWindow(session) } : nil
                    pane.show(placeholder: AnyView(TerminalMirror(session: session, open: { [weak self] in
                        self?.actions.openInTerminal(session)
                    }, move: move)))
                }
            }
        }
        shownID = row.id
    }

    /// Shows the selected row's conversation over the terminal when Chat is chosen and it has one.
    private func updateChat() {
        let row = model.selectedRow
        let path = row.flatMap(model.chatPath(for:))
        let shown = model.showsChat && path != nil
        // Only read a conversation that's on screen.
        let previous = chat.path
        chat.show(path: shown ? path : nil, key: shown ? row?.draftKey : nil)
        if chat.path != previous { Breadcrumbs.shared.note("chat: show \(chat.path.map { ($0 as NSString).lastPathComponent } ?? "none")") }
        if shown, chat.path != previous {
            chat.loadCompletions(agent: row?.session?.agent ?? row?.hosted?.agent.flatMap(Agent.init(rawValue:)) ?? .claude,
                                 folder: row?.cwd)
            readScreen()
        }
        // A covered terminal still draws every frame its program sends (a working agent's spinner): hide it. It keeps
        // reading the session, so the answer card and the mode chip still see the screen.
        if pane.view.isHidden != shown { pane.view.isHidden = shown }
        if chatHost.isHidden == shown {
            chatHost.isHidden = !shown
            if shown { chat.focusComposer() } else { pane.focus() }
        } else if shown, chat.path != previous {
            chat.focusComposer()
        }
        if shown, chatTimer == nil {
            chatTimer = Heartbeat.shared.every(1) { [weak self] in
                guard let self, self.window?.isVisible == true, !self.chatHost.isHidden else { return }
                self.chat.poll()
                self.chat.refreshSteering()
                self.readScreen()
                if self.window?.isKeyWindow == true { self.chat.markSeen() }
            }
        } else if !shown {
            chatTimer?.cancel()
            chatTimer = nil
        }
    }


    /// The menu and permission mode on the selected window session's screen, for the answer card and the mode chip.
    private func readScreen() {
        // Run on code blocks: for a Claude window session you can type into (`!` runs a command there).
        let canRun = model.selectedRow.map { $0.hostID != nil && actions.isLive($0) && $0.session?.agent == .claude } == true && host.isUsable
        if chat.runner.canRun != canRun { chat.runner.canRun = canRun }
        // Messages steered to this session that are still waiting (also from before a relaunch), and whether its
        // agent is idle (then they won't be taken by themselves).
        if let session = model.selectedRow?.session, session.agent == .claude {
            chat.watchSteering(tty: session.tty, agentPid: session.pid,
                               idle: LeadDelivery.way(for: HookState.load(from: VibePaths.stateFile(tty: session.tty))) == .type)
        } else {
            chat.watchSteering(tty: nil, agentPid: nil, idle: false)
        }
        guard let row = model.selectedRow, let id = row.hostID, actions.isLive(row) else {
            if chat.menu != nil { chat.menu = nil }
            if chat.mode != nil { chat.mode = nil }
            return
        }
        let lines = pane.screenLines(id)
        let bottom = Array(lines.suffix(40))
        // Only a menu that's waiting on you: the hooks say so, or the screen says how to choose.
        let asking = row.session?.status == .needsInput
            || bottom.suffix(6).contains { $0.contains("Enter to select") || $0.contains("Esc to cancel") || $0.contains("to navigate") }
        let menu = asking ? ScreenMenu.parse(bottom) : nil
        if chat.menu != menu { chat.menu = menu }
        let mode = row.session?.agent == .codex ? nil : AgentMode.parse(Array(lines.suffix(6)))
        if chat.mode != mode { chat.mode = mode }
    }

    /// The composer's message, typed into the selected window session (as a paste when its program asked for that).
    private func sendToSelected(_ text: String) -> Bool {
        // Not connected to the host (it's reconnecting, or gone): the keys would go nowhere; the text stays in the box.
        guard let row = model.selectedRow, let id = row.hostID, actions.isLive(row), host.isUsable else {
            NSSound.beep()
            return false
        }
        Breadcrumbs.shared.note("composer: send \(text.count) chars to \(row.id)")
        let key = row.draftKey
        // The composer's outbox keeps the message until the host confirms it (and the conversation shows it).
        host.send(id, writes: ComposerText.writes(text, bracketed: pane.bracketedPaste(id))) { [weak self] ok in
            if !ok { Breadcrumbs.shared.note("composer: the host didn't confirm \(text.count) chars for \(row.id)") }
            self?.chat.confirmed(key: key, message: text, ok: ok)
        }
        return true
    }

    /// Hands the message to the selected session's agent at its next step: through its hook for Claude (window or
    /// Terminal session alike), typed in for Codex (which takes input during a turn as steering).
    private func steerSelected(_ text: String) -> Bool {
        guard let row = model.selectedRow, let session = row.session else {
            NSSound.beep()
            return false
        }
        if session.agent == .codex { return row.hostID != nil ? sendToSelected(text) : false }
        // Not working after all (its turn ended since the composer last looked): a steer would wait for a next step
        // that never comes. A window session gets it typed in instead.
        if LeadDelivery.way(for: HookState.load(from: VibePaths.stateFile(tty: session.tty))) == .type {
            Breadcrumbs.shared.note("composer: steer to an idle agent on \(session.tty), typed instead")
            return row.hostID != nil ? sendToSelected(text) : false
        }
        let message = SteerMessage(text: text, from: .user, agentPid: session.pid)
        do {
            try SteerInbox.post(message, tty: session.tty)
            chat.handedOff(key: row.draftKey, message: text)
            chat.steered(message, tty: session.tty)
            chat.scrollToBottom()
            return true
        } catch {
            NSSound.beep()
            return false
        }
    }

    /// Keys for the selected window session (Esc to stop, shift+tab for the mode).
    private func sendKeys(_ bytes: [UInt8]) {
        guard let row = model.selectedRow, let id = row.hostID, actions.isLive(row) else { return NSSound.beep() }
        write([HostInput.Write(bytes: bytes, delay: 0)], to: id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.readScreen() }
    }

    /// Answers the menu on screen: arrows from where its cursor is, then Enter.
    private func chooseMenuOption(_ index: Int, typing: String? = nil) {
        guard let row = model.selectedRow, let id = row.hostID, let menu = chat.menu else { return }
        // Read again right before: the question may have changed or gone, and an answer must not land on another one.
        readScreen()
        guard chat.menu == menu else {
            chat.answerNotice = chat.menu == nil ? "That question is gone." : "That question changed; here it is now."
            return
        }
        write(typing.map { menu.keys(toChoose: index, typing: $0) } ?? menu.keys(toChoose: index), to: id)
        chat.menu = nil
        chat.scrollToBottom()
    }

    private func write(_ writes: [HostInput.Write], to id: UUID) {
        var at: TimeInterval = 0
        for write in writes {
            at += write.delay
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                self?.host.send(id, bytes: Data(write.bytes), reply: false)
            }
        }
    }

    /// The window's title names the selected session; the Dock badge counts sessions waiting on you, and leads'
    /// blocking questions (not the ones that can wait).
    private func updateTitleAndBadge() {
        window?.title = model.selectedRow.map { "\($0.title) — \($0.project)" } ?? "VibeSwitcher"
        guard let window, window.isVisible || window.isMiniaturized else { return }
        let waiting = model.allRows.filter { $0.state(now: Date()).group == .needsYou }.count
            + leads.boards.values.reduce(0) { $0 + $1.blockingQuestions }
        NSApp.dockTile.badgeLabel = waiting > 0 ? "\(waiting)" : nil
    }

    private func updateViewing() {
        let row = model.selectedRow
        store.windowViewingTTY = window?.isKeyWindow == true && row?.hostID != nil ? row?.session?.tty : nil
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        updateViewing()
        if chatHost.isHidden { pane.focus() } else { chat.focusComposer() }
    }

    func windowDidResignKey(_ notification: Notification) { updateViewing() }

    func windowWillClose(_ notification: Notification) {
        Breadcrumbs.shared.note("window: close")
        store.windowViewingTTY = nil
        palette.close()
        chatTimer?.cancel()
        chatTimer = nil
        NSApp.dockTile.badgeLabel = nil
        pane.detachAll()
        // A hidden window keeps its views, and with them the mirror's reading loop: take it down.
        pane.show(placeholder: AnyView(EmptyView()))
        shownID = nil
        mirrorState = nil
        chat.show(path: nil)
        unmountViews()
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
        case #selector(showTerminalAction(_:)): menuItem.state = model.chatShown ? .off : .on
        case #selector(showChatAction(_:)):
            menuItem.state = model.chatShown ? .on : .off
            return model.selectedRow.map { model.chatPath(for: $0) != nil } == true
        case #selector(openInTerminalAction(_:)): return model.selectedRow?.session?.inTerminalApp == true
        case #selector(findAction(_:)), #selector(findNextAction(_:)), #selector(findPreviousAction(_:)):
            // Something to search: the conversation, or the terminal's scrollback (not the start page).
            return model.selectedRow != nil && (model.chatShown || pane.currentView != nil)
        case #selector(endSessionAction(_:)):
            return model.selectedRow.map { $0.hostID != nil && actions.isLive($0) } == true
        default: break
        }
        return true
    }

    @objc func showHomeAction(_ sender: Any?) { model.showHome() }
    @objc func showTerminalAction(_ sender: Any?) { model.showsChat = false }
    @objc func showChatAction(_ sender: Any?) { model.showsChat = true }

    /// ⌘F: searches the conversation in Chat, the terminal's scrollback in Terminal.
    @objc func findAction(_ sender: Any?) {
        if model.chatShown {
            chat.searchActive = true
        } else if let terminal = pane.currentView {
            window?.makeFirstResponder(terminal)
            terminal.performFindPanelAction(sender)
        }
    }

    @objc func findNextAction(_ sender: Any?) {
        if model.chatShown { chat.stepSearch(1) } else { pane.currentView?.performFindPanelAction(sender) }
    }

    @objc func findPreviousAction(_ sender: Any?) {
        if model.chatShown { chat.stepSearch(-1) } else { pane.currentView?.performFindPanelAction(sender) }
    }

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
        let leadFolders = ([selectedFolder].compactMap { $0 } + model.recentProjects.prefix(6)).reduce(into: [String]()) { list, path in
            if !list.contains(path) { list.append(path) }
        }
        commands += leadFolders.map { path in
            PaletteItem(id: "lead:\(path)", title: "Start Project Lead in \((path as NSString).lastPathComponent)",
                        subtitle: "A lead that runs workers, has their work verified, and merges", icon: .symbol("person.3")) {
                [weak self] in self?.actions.startLead(path)
            }
        }
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

    /// ⌘+ / ⌘− / ⌘0 size the chat's text while it's shown, the terminal's otherwise.
    @objc func biggerFont(_ sender: Any?) { model.chatShown ? ChatFont.step(1) : onFontSize(1) }
    @objc func smallerFont(_ sender: Any?) { model.chatShown ? ChatFont.step(-1) : onFontSize(-1) }
    @objc func actualSizeFont(_ sender: Any?) { model.chatShown ? ChatFont.step(0) : onFontSize(0) }

    @objc func stopAction(_ sender: Any?) {
        guard let row = model.selectedRow, row.hostID != nil, actions.isLive(row) else { return NSSound.beep() }
        sendKeys([27])
    }

    @objc func exportChatAction(_ sender: Any?) {
        guard let row = model.selectedRow, model.chatPath(for: row) != nil, !chat.log.entries.isEmpty else { return NSSound.beep() }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = row.title.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let agent = row.session?.agent.displayName ?? "Agent"
        try? ChatExport.markdown(chat.log.entries, agent: agent).write(to: url, atomically: true, encoding: .utf8)
    }
    @objc func clearScrollbackAction(_ sender: Any?) { pane.clearScrollback() }
}
