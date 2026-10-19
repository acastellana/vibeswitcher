import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import VibeCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSViewToolTipOwner, NSPopoverDelegate {
    private let store = SessionStore()
    /// The session host that runs the window's sessions; the app proves itself to it with its key in the login Keychain.
    let hostClient = HostClient(appKey: HostClient.appKey(from: AppProof.KeychainStore()))
    private let popoverState = PopoverState()
    private let preferences = Preferences()
    /// Notifications need an app bundle; `swift run` (no bundle) runs without them instead of crashing.
    private lazy var notifier: Notifier? = Bundle.main.bundleIdentifier == nil ? nil : Notifier(preferences: preferences)
    private lazy var phoneAccess = PhoneAccess(store: store)
    private var settingsWindow: SettingsWindowController?
    /// Hooks, permissions and login item: their live state for the welcome window and Settings.
    private lazy var setup: SetupModel = {
        let model = SetupModel(preferences: preferences, system: .live(notifier: notifier))
        model.onHooksChanged = { [weak self] in self?.store.refreshHookStatus() }
        return model
    }()
    private var welcomeWindow: OnboardingWindowController?
    let windowModel = WindowModel()
    private var mainWindow: MainWindowController?
    private lazy var windowActions = WindowActions(
        newSession: { [weak self] preset, folder in self?.newSession(preset: preset, in: folder) },
        endSession: { [weak self] row in self?.endSession(row) },
        resume: { [weak self] row in self?.resumeSession(row) },
        remove: { [weak self] row in
            guard let id = row.hostID else { return }
            self?.mainWindow?.pane.forget(id)
            self?.hostClient.remove(id)
        },
        rename: { [weak self] in self?.rename($0) },
        pause: { [weak self] in self?.store.pause($0, for: $1) },
        resumePaused: { [weak self] in self?.store.resume($0) },
        openInTerminal: { [weak self] in self?.open($0, source: "window") },
        presets: { [weak self] folder in self?.presets(for: folder) ?? [] },
        isLive: { [weak self] row in
            guard let id = row.hostID else { return row.session != nil }
            return self?.hostClient.sessions.first { $0.id == id }?.isLive ?? (row.session != nil)
        },
        canResume: { [weak self] row in
            guard let self, let id = row.hostID, self.hostClient.sessions.first(where: { $0.id == id })?.isLive == false
            else { return false }
            return self.windowModel.agentSessions[id] != nil
        },
        resumeCommand: { [weak self] row in self?.resumeCommandLine(for: row) },
        settings: { [weak self] in self?.showSettings(tab: .general) },
        moveToWindow: { [weak self] in self?.moveToWindow($0) },
        startLead: { [weak self] folder in
            self?.showMainWindow()
            self?.leadController.startLead(in: folder)
        })
    private(set) lazy var leadController: LeadController = {
        let controller = LeadController(host: hostClient, store: store) { [weak self] root in
            let presets = self?.presets(for: root) ?? []
            let preset = presets.first { $0.agent == .claude && $0.place == .window } ?? presets.first { $0.agent == .claude }
            return preset.flatMap(LaunchPlan.command(for:)) ?? "claude"
        }
        controller.notify = { [weak self] title, body in self?.notifier?.postInfo(title: title, body: body) }
        controller.select = { [weak self] id in self?.showMainWindow(select: id) }
        controller.keepAwake.mode = { [weak self] in self?.preferences.keepAwake ?? .never }
        return controller
    }()
    /// Brief me: the spoken briefing of what happened lately across the led projects. The ElevenLabs key is in the
    /// login Keychain, read only when it's used.
    private lazy var briefing = BriefingModel(
        snapshot: { [weak self] in BriefingModel.Snapshot(boards: self?.leadController.boards ?? [:], sessions: self?.store.sessions ?? []) },
        language: { [weak self] in BriefingLanguage.named(self?.preferences.briefingLanguage ?? "") ?? .preferred() },
        keyStore: AppProof.KeychainSecret(account: AppProof.elevenLabsAccount))
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var hotKey: HotKey?
    private var keyMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []
    private var hostingView: NSHostingView<AnyView>!
    /// Builds the list; it's only mounted while the popover is open, so SwiftUI does no work otherwise.
    private var makePopoverContent: (() -> AnyView)!
    /// What the menu bar icon depends on; the image is only redrawn when this changes.
    private var iconSignature = ""
    private var floatingPanel: FloatingPanelController!
    private var sidebar: SidebarController!
    private var visibilityTimer: Heartbeat.Subscription?
    private var hiddenReadings = 0
    private var notificationTimer: Heartbeat.Subscription?
    private var terminationSignal: DispatchSourceSignal?
    private static let statusItemName = "VibeSwitcher"
    /// Stored by macOS as the distance from the right screen edge; set once so we start next to the
    /// clock, where an overflowing menu bar never hides items. ⌘-dragging the icon overrides it.
    private static let positionKey = "NSStatusItem Preferred Position VibeSwitcher"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Breadcrumbs.shared.note("app: launched \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") build \(HostBuild.id(ofExecutableAt: Bundle.main.executablePath ?? ""))")
        HangWatchdog.shared.describeState = { [weak self] in
            guard let self else { return "" }
            let host = "host state=\(self.hostClient.state) sessions=\(self.hostClient.sessions.count) live=\(self.hostClient.sessions.filter(\.isLive).count)"
            return "\(host)\nscanned sessions=\(self.store.sessions.count)\n" + (self.mainWindow?.debugState() ?? "window never opened")
        }
        HangWatchdog.shared.start()
        // `kill`/`pkill` (and the build script) send SIGTERM, which skips applicationWillTerminate: route it
        // through a normal quit so hidden windows come back and today's stats are saved.
        signal(SIGTERM, SIG_IGN)
        terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSignal?.setEventHandler { NSApp.terminate(nil) }
        terminationSignal?.resume()
        // Before the state folder is created below: its absence is part of what makes this a first run.
        let firstRun = FirstRun.shouldWelcome(
            defaults: .standard, stateDirExists: FileManager.default.fileExists(atPath: VibePaths.stateDir.path),
            hooksInstalled: Dictionary(uniqueKeysWithValues: Agent.allCases.map { ($0, HookInstaller.isInstalled(agent: $0)) }))
        HookBinary.sync()
        VibePaths.ensurePrivateDirectories()
        hostClient.connectIfRunning()
        // Leads' witness and questions work with the window closed too.
        _ = leadController
        if UserDefaults.standard.bool(forKey: "windowWasOpen") {
            // Cleared until the window has been up a while: if opening it crashes the app, the next launch
            // doesn't open it again (and crash again).
            UserDefaults.standard.set(false, forKey: "windowWasOpen")
            Breadcrumbs.shared.note("app: reopening the window it had open")
            DispatchQueue.main.async { [weak self] in self?.showMainWindow() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                if self?.mainWindow?.window?.isVisible == true { UserDefaults.standard.set(true, forKey: "windowWasOpen") }
            }
        }
        // No permission prompts or login item at launch: the welcome window asks for each, saying why.
        notifier?.refreshAuthorization()
        if firstRun { DispatchQueue.main.async { [weak self] in self?.showWelcome(firstRun: true) } }
        if let notice = preferences.presetsNotice {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Some launch presets couldn't be read"
                alert.informativeText = notice
                NSApp.activate()
                alert.runModal()
            }
        }
        notifier?.onOpen = { [weak self] tty in
            guard let self, let session = self.store.sessions.first(where: { $0.tty == tty }) else { return }
            self.open(session, source: "notification")
        }
        store.onAttention = { [weak self] session in self?.notifier?.post(for: session) }
        store.onNudge = { [weak self] session, nudge in self?.notifier?.post(nudge, for: session) }
        notifier?.onAlert = { [weak self] title, body, tty in self?.phoneAccess.notify(title: title, body: body, tty: tty) }
        phoneAccess.onEvent = { [weak self] title, body in self?.notifier?.postInfo(title: title, body: body) }
        phoneAccess.hostClient = hostClient
        phoneAccess.startIfEnabled()

        if UserDefaults.standard.object(forKey: Self.positionKey) == nil {
            UserDefaults.standard.set(120.0, forKey: Self.positionKey)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = Self.statusItemName
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.image = StatusIcon.image(for: [])
        statusItem.button?.setAccessibilityLabel(StatusSummary.spoken([]))

        let view = PopoverView(store: store, state: popoverState, preferences: preferences,
                               onOpen: { [weak self] in self?.open($0) },
                               onInstallHooks: { [weak self] in self?.installHooks() },
                               onQuit: { NSApp.terminate(nil) },
                               onRename: { [weak self] in self?.rename($0) },
                               onResetName: { [weak self] in self?.store.rename($0, to: nil) },
                               onNewSession: { [weak self] preset, folder in self?.newSession(preset: preset, in: folder) },
                               presetsFor: { [weak self] folder in self?.preferences.presets.presets(for: folder) ?? [] },
                               onEditCommands: { [weak self] in self?.showSettings(tab: .launch) },
                               onPause: { [weak self] in self?.store.pause($0, for: $1) },
                               onResume: { [weak self] in self?.store.resume($0) },
                               onOpenWindow: { [weak self] in
                                   self?.popover.performClose(nil)
                                   self?.showMainWindow()
                               },
                               onSettings: { [weak self] in self?.showSettings(tab: .general) },
                               onAllowNotifications: { [weak self] in self?.setup.allowNotifications() })
        var menuView = view
        menuView.briefing = briefing
        makePopoverContent = { AnyView(menuView) }
        var sidebarView = view
        sidebarView.isSidebar = true
        sidebar = SidebarController(content: AnyView(PopoverView(
            store: store, state: PopoverState(), preferences: preferences,
            onOpen: { [weak self] in self?.open($0, source: "sidebar") }, onInstallHooks: sidebarView.onInstallHooks, onQuit: sidebarView.onQuit,
            onRename: sidebarView.onRename, onResetName: sidebarView.onResetName,
            onNewSession: sidebarView.onNewSession, presetsFor: sidebarView.presetsFor,
            onEditCommands: sidebarView.onEditCommands,
            onPause: sidebarView.onPause, onResume: sidebarView.onResume,
            isSidebar: true, onOpenWindow: { [weak self] in self?.showMainWindow() },
            onSettings: { [weak self] in self?.showSettings(tab: .general) },
            onAllowNotifications: sidebarView.onAllowNotifications)))
        // Windows hidden by the earlier sidebar mode (or a crash during it) always come back.
        DispatchQueue.global(qos: .utility).async { SidebarWorkspace.restoreHiddenWindows() }
        // Desktop switched: refresh which session is "here" and show the sidebar for a moment.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.store.refresh(forceTerminal: true)
            // Not with Reduce Motion: a slide at the screen edge on every desktop switch.
            if self.preferences.sidebarMode, !Motion.isReduced { self.sidebar.flash() }
        }
        preferences.$minimizeOnPause
            .sink { [weak self] enabled in self?.store.minimizeOnPause = enabled }
            .store(in: &cancellables)
        preferences.$aiSummaries
            .sink { [weak self] enabled in self?.leadController.summaries.enabled = enabled }
            .store(in: &cancellables)
        preferences.$sidebarAutoHide
            .receive(on: RunLoop.main)
            .sink { [weak self] autoHide in self?.sidebar.autoHide = autoHide }
            .store(in: &cancellables)
        preferences.$sidebarMode
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                self.sidebar.setEnabled(enabled)
                if !enabled { DispatchQueue.global(qos: .userInitiated).async { SidebarWorkspace.restoreHiddenWindows() } }
                DispatchQueue.main.async { self.updateFloatingPanel() }
            }
            .store(in: &cancellables)
        hostingView = FirstMouseHostingView(rootView: AnyView(EmptyView()))
        let controller = NSViewController()
        controller.view = hostingView
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = false

        floatingPanel = FloatingPanelController(store: store, onOpen: { [weak self] in self?.open($0, source: "panel") },
                                                onShowList: { [weak self] anchor in self?.togglePopover(anchor: anchor) })
        preferences.$sessionOrder
            .receive(on: RunLoop.main)
            .sink { [weak self] order in self?.store.order = order }
            .store(in: &cancellables)
        preferences.$floatingPanel
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateFloatingPanel() } }
            .store(in: &cancellables)
        visibilityTimer = Heartbeat.shared.every(2) { [weak self] in self?.updateFloatingPanel() }
        notificationTimer = Heartbeat.shared.every(15) { [weak self] in self?.notifier?.refreshAuthorization() }

        store.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                guard let self else { return }
                let signature = sessions.map { "\($0.status.rawValue):\($0.isCurrent):\($0.isPaused)" }.joined(separator: ",")
                if signature != self.iconSignature {
                    self.iconSignature = signature
                    self.statusItem.button?.image = StatusIcon.image(for: sessions)
                    // VoiceOver: "VibeSwitcher: 2 need you, 3 working".
                    self.statusItem.button?.setAccessibilityLabel(StatusSummary.spoken(sessions))
                    DispatchQueue.main.async { self.updateDotToolTips() }
                }
                self.popoverState.selectedIndex = min(self.popoverState.selectedIndex, max(0, sessions.count - 1))
                DispatchQueue.main.async {
                    if self.floatingPanel.isShown { self.floatingPanel.fit() }
                    if self.popover.isShown { self.fitPopover() }
                }
            }
            .store(in: &cancellables)

        hostClient.$state
            .receive(on: RunLoop.main)
            .sink { state in AppStatus.extras["host"] = "\(state)" }
            .store(in: &cancellables)
        store.hostScreens = { [weak self] in self?.hostClient.screens ?? [:] }
        store.requestHostScreens = { [weak self] ttys in self?.hostClient.refreshScreens(ttys: ttys) }
        hostClient.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in self?.store.updateHosted(sessions) }
            .store(in: &cancellables)
        store.$sessions.combineLatest(hostClient.$sessions, hostClient.$state, store.$tableRead)
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions, hosted, state, table in
                self?.windowModel.update(sessions: sessions, hosted: hosted, table: table, hostAnswered: state != .connecting)
            }
            .store(in: &cancellables)
        MainMenu.install()
        DistributedNotificationCenter.default().addObserver(forName: AppStatus.windowNotification, object: nil,
                                                            queue: .main) { [weak self] note in
            self?.showMainWindow()
            switch note.object as? String {
            case "palette": self?.mainWindow?.showPaletteAction(nil)
            case "home": self?.windowModel.showHome()
            case let text? where text.hasPrefix("move:"):
                let tty = String(text.dropFirst("move:".count))
                if let session = self?.store.sessions.first(where: { $0.tty == tty }) { self?.moveToWindow(session, ask: false) }
            case let text? where text.hasPrefix("select:"):
                guard let model = self?.windowModel else { return }
                let query = String(text.dropFirst("select:".count))
                if let row = WindowGroups.filter(model.sections, query: query).first?.rows.first { model.selectedID = row.id }
            default: break
            }
        }
        // No notification reads a session's screen: any process can post one, a worker's Bash too, and the screen
        // would land wherever it said (the `--screen` debug aid did that, and went).
        DistributedNotificationCenter.default().addObserver(forName: AppStatus.leadNotification, object: nil,
                                                            queue: .main) { [weak self] note in
            guard let folder = note.object as? String else { return }
            // Any process can post this: the start never takes a moved branch as the lead's.
            self?.leadController.startLead(in: folder, goal: note.userInfo?["goal"] as? String, show: false, askAboutMovedHead: false)
        }
        DistributedNotificationCenter.default().addObserver(forName: AppStatus.captureNotification, object: nil,
                                                            queue: .main) { [weak self] note in
            guard let path = note.object as? String, DebugOutput.allowed(path) else { return }
            self?.captureWindows(to: path)
        }
        DistributedNotificationCenter.default().addObserver(forName: AppStatus.newSessionNotification, object: nil,
                                                            queue: .main) { [weak self] note in
            var isFolder: ObjCBool = false
            guard let self, let name = note.userInfo?["preset"] as? String, let folder = note.userInfo?["folder"] as? String,
                  FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else { return }
            let presets = self.preferences.presets.presets(for: folder)
            guard var preset = presets.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
                    ?? presets.first(where: { $0.kind.rawValue == name.lowercased() }) else { return }
            if note.userInfo?["terminal"] as? Bool == true { preset.place = .terminal }
            self.startSession(preset, in: folder)
        }
        DistributedNotificationCenter.default().addObserver(forName: AppStatus.settingsNotification, object: nil,
                                                            queue: .main) { [weak self] note in
            self?.showSettings(tab: (note.object as? String).flatMap(SettingsTab.init(rawValue:)) ?? .general)
        }
        preferences.$appearance
            .receive(on: RunLoop.main)
            .sink { [weak self] appearance in
                DispatchQueue.main.async {
                    self?.mainWindow?.pane.scrollbackLines = appearance.scrollbackLines
                    self?.mainWindow?.pane.reconfigureAll()
                }
            }
            .store(in: &cancellables)
        NSApp.publisher(for: \.effectiveAppearance)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.mainWindow?.pane.reconfigureAll() } }
            .store(in: &cancellables)
        if preferences.openWindowAtLaunch { showMainWindow() }

        hotKey = HotKey(keyCode: kVK_ANSI_V, modifiers: controlKey | optionKey) { [weak self] in
            self?.togglePopover()
        }
        AppStatus.extras["hotKeyRegistered"] = hotKey != nil
        // `VibeSwitcher --toggle` (e.g. from Raycast or a shell) opens the popover of the running instance.
        // `VibeSwitcher --open ttysNNN`: same code path as clicking that row.
        DistributedNotificationCenter.default().addObserver(forName: AppStatus.openNotification, object: nil,
                                                            queue: .main) { [weak self] note in
            guard let self, let tty = note.object as? String,
                  let session = self.store.sessions.first(where: { $0.tty == tty }) else { return }
            self.open(session, source: "command")
        }
        DistributedNotificationCenter.default().addObserver(forName: AppStatus.toggleNotification, object: nil,
                                                            queue: .main) { [weak self] _ in
            self?.togglePopover()
        }
        store.start()
    }

    /// Left-click on a dot jumps straight to that session; right-click (or ⌃-click), a click beside the
    /// dots, or the counts/empty icon opens the list.
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true { return showMainWindow() }
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if !secondary, let event, let index = dotIndex(at: event, in: sender), store.sessions.indices.contains(index) {
            open(store.sessions[index], source: "menu bar dot")
            return
        }
        togglePopover()
    }

    /// Where the dots image sits inside the status bar button (AppKit centers it with some padding).
    private func dotsImageRect(in button: NSStatusBarButton) -> NSRect? {
        let count = store.sessions.count
        guard (1...MenuBarDots.maxDots).contains(count), let image = button.image else { return nil }
        let rect = button.cell?.imageRect(forBounds: button.bounds)
            ?? NSRect(x: (button.bounds.width - image.size.width) / 2, y: (button.bounds.height - image.size.height) / 2,
                      width: image.size.width, height: image.size.height)
        return rect.width > 0 ? rect : nil
    }

    /// Button point → point in the dots image (origin bottom-left), whatever the button's flippedness.
    private func imagePoint(_ point: NSPoint, in button: NSStatusBarButton, imageRect rect: NSRect, image: NSImage) -> CGPoint {
        let fx = (point.x - rect.minX) / rect.width
        var fy = (point.y - rect.minY) / rect.height
        if button.isFlipped { fy = 1 - fy }
        return CGPoint(x: fx * image.size.width, y: fy * image.size.height)
    }

    private func dotIndex(at event: NSEvent, in button: NSStatusBarButton) -> Int? {
        guard let rect = dotsImageRect(in: button), let image = button.image else { return nil }
        let point = button.convert(event.locationInWindow, from: nil)
        return MenuBarDots.index(at: imagePoint(point, in: button, imageRect: rect, image: image), count: store.sessions.count)
    }

    /// One tooltip region per dot, naming that session.
    private func updateDotToolTips() {
        guard let button = statusItem.button else { return }
        button.removeAllToolTips()
        guard let rect = dotsImageRect(in: button), let image = button.image else {
            button.toolTip = Self.tooltip(for: store.sessions)
            return
        }
        button.toolTip = nil
        let sx = rect.width / image.size.width, sy = rect.height / image.size.height
        for index in store.sessions.indices {
            let hit = MenuBarDots.hitRect(at: index, count: store.sessions.count)
            let y = button.isFlipped ? rect.maxY - hit.maxY * sy : rect.minY + hit.minY * sy
            let area = NSRect(x: rect.minX + hit.minX * sx, y: y, width: hit.width * sx, height: hit.height * sy)
            button.addToolTip(area, owner: self, userData: UnsafeMutableRawPointer(bitPattern: index + 1))
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        let index = Int(bitPattern: data) - 1
        guard store.sessions.indices.contains(index) else { return "" }
        let session = store.sessions[index]
        let task = session.task.map { "\n\($0)" } ?? ""
        let paused = session.isPaused ? " · paused" : ""
        return "\(index + 1). \(session.displayName) · \(session.status.label)\(paused)\(task)\nClick to switch · right-click for the list"
    }

    /// Whether macOS is actually showing our menu bar icon. When the right side of the menu bar
    /// overflows, the leftmost items are pushed under the notch (or off screen) and silently vanish.
    private var statusItemVisible: Bool {
        guard let window = statusItem.button?.window, window.isVisible,
              let screen = window.screen ?? NSScreen.main else { return false }
        let frame = window.frame
        guard frame.width > 0, frame.minX >= screen.frame.minX, frame.maxX <= screen.frame.maxX else { return false }
        // On a notched screen macOS only shows status items right of the notch; overflow is parked
        // under the notch or behind the app menus on the left, invisible either way.
        if let right = screen.auxiliaryTopRightArea, frame.minX < right.minX { return false }
        return true
    }

    private func updateFloatingPanel() {
        let visible = statusItemVisible
        // The icon's frame is briefly bogus while macOS places it, so only trust two hidden readings in a row.
        hiddenReadings = visible ? 0 : hiddenReadings + 1
        var show: Bool
        switch preferences.floatingPanel {
        case .always: show = true
        case .never: show = false
        case .automatic: show = hiddenReadings >= 2
        }
        if preferences.sidebarMode { show = false } // the sidebar already shows every session
        let changed = show != floatingPanel.isShown
        floatingPanel.setShown(show)
        AppStatus.extras["menuBarIconVisible"] = visible
        AppStatus.extras["floatingPanelShown"] = show
        if changed { AppStatus.write(sessions: store.sessions, terminalAccess: store.terminalAccess) }
    }

    private func togglePopover() {
        togglePopover(anchor: nil)
    }

    /// Shows the list under the menu bar icon, or under the floating panel when the icon is hidden.
    private func togglePopover(anchor: NSView?) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        let target: NSView?
        if let anchor { target = anchor }
        else if statusItemVisible || !floatingPanel.isShown { target = statusItem.button }
        else { target = floatingPanel.anchorView }
        guard let button = target else { return }
        store.refresh(forceTerminal: true)
        notifier?.refreshAuthorization()
        loadRecentProjects()
        popoverState.selectedIndex = store.sessions.firstIndex { $0.status == .needsInput && !$0.isPaused }
            ?? store.sessions.firstIndex { $0.status == .done && !$0.isPaused } ?? 0
        hostingView.rootView = makePopoverContent()
        fitPopover()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        startKeyMonitor()
        AppStatus.write(sessions: store.sessions, terminalAccess: store.terminalAccess, extra: ["popoverOpenedAt": ISO8601DateFormatter().string(from: Date())])
    }

    /// Launching the app again (Spotlight, Finder, `open`) while it runs doesn't start a second copy:
    /// macOS reactivates this one, so show the list. Only opens, never closes, since that's what a launch asks for.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = mainWindow?.window, window.isVisible || window.isMiniaturized {
            mainWindow?.present()
        } else if !popover.isShown {
            togglePopover()
        }
        return false
    }

    @objc func showSettings(_ sender: Any?) { showSettings(tab: .general) }

    func showSettings(tab: SettingsTab) {
        popover.performClose(nil)
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                preferences: preferences, setup: setup, phoneAccess: phoneAccess,
                recentProjects: { [weak self] in self?.popoverState.recentProjects.map(\.path) ?? [] },
                showWelcome: { [weak self] in self?.showWelcome(firstRun: false) }, host: hostClient, briefing: briefing)
        }
        loadRecentProjects()
        settingsWindow?.show(tab: tab)
    }

    /// The welcome window: on first launch, and from Settings › General.
    private func showWelcome(firstRun: Bool) {
        popover.performClose(nil)
        UserDefaults.standard.set(true, forKey: FirstRun.shownKey)
        if welcomeWindow == nil { welcomeWindow = OnboardingWindowController(setup: setup) }
        welcomeWindow?.show(firstRun: firstRun)
    }

    /// Debug aid (`VibeSwitcher --capture-window PATH`): each visible window drawn into a PNG (PATH, then
    /// PATH-2.png…), without needing Screen Recording permission.
    private func captureWindows(to path: String) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.frame.width > 300 && $0.frame.height > 200 }
        for (index, window) in windows.enumerated() {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let file = index == 0 ? path : (path as NSString).deletingPathExtension + "-\(index + 1).png"
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
            // The view tree beside it (class, frame, hidden; a terminal's colors). Not the terminals' text: any
            // process can ask for a capture, a worker's Bash too, and a session's screen isn't theirs to read.
            var tree = ""
            func describe(_ view: NSView, _ depth: Int) {
                guard depth < 14 else { return }
                tree += String(repeating: "  ", count: depth) + "\(type(of: view)) \(NSStringFromRect(view.frame))\(view.isHidden ? " hidden" : "")\n"
                if let terminal = view as? HostTerminalView {
                    tree += String(repeating: "  ", count: depth + 1)
                        + "background \(terminal.nativeBackgroundColor) layer \(terminal.layer?.backgroundColor.map { "\($0)" } ?? "none")\n"
                }
                view.subviews.forEach { describe($0, depth + 1) }
            }
            describe(view, 0)
            tree += "\nwindow frame \(NSStringFromRect(window.frame)) minSize \(NSStringFromSize(window.minSize)) maxSize \(NSStringFromSize(window.maxSize)) contentMaxSize \(NSStringFromSize(window.contentMaxSize))\n"
            if let split = window.contentViewController as? NSSplitViewController {
                for item in split.splitViewItems {
                    tree += "pane \(type(of: item.viewController.view)) width \(item.viewController.view.frame.width) min \(item.minimumThickness) max \(item.maximumThickness) holding \(item.holdingPriority.rawValue)\n"
                    for constraint in item.viewController.view.constraintsAffectingLayout(for: .horizontal) {
                        tree += "  \(constraint)\n"
                    }
                }
            }
            try? tree.write(toFile: (file as NSString).deletingPathExtension + ".txt", atomically: true, encoding: .utf8)
        }
    }

    func showMainWindow(select hostID: UUID? = nil) {
        if mainWindow == nil {
            let controller = MainWindowController(store: store, host: hostClient, model: windowModel, actions: windowActions,
                                                  leads: leadController, briefing: briefing)
            controller.onFontSize = { [weak self] step in self?.changeFontSize(step) }
            controller.pane.configure = { [weak self] view in
                guard let self else { return }
                // A new view isn't in the window yet, and on its own it reports the light appearance.
                let dark = (view.window ?? self.mainWindow?.window)?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                view.apply(self.preferences.appearance, darkMode: dark)
            }
            controller.pane.scrollbackLines = preferences.appearance.scrollbackLines
            controller.pane.onBell = { [weak self] view in
                switch self?.preferences.appearance.bell {
                case .sound: NSSound.beep()
                case .visual: view.flash()
                default: break
                }
            }
            mainWindow = controller
        }
        if let hostID { windowModel.select(hostID: hostID) }
        loadRecentProjects()
        mainWindow?.present()
    }

    private func changeFontSize(_ step: Int) {
        let current = preferences.appearance
        preferences.appearance = step == 0 ? current.withFontSize(TerminalAppearance.defaultFontSize)
                                           : current.withFontSize(current.fontSize + Double(step))
    }

    private func presets(for folder: String?) -> [LaunchPreset] {
        preferences.presets.presets(for: folder)
    }

    private func newSession(preset: LaunchPreset?, in folder: String?) {
        popover.performClose(nil)
        guard let folder = folder ?? Launcher.chooseFolder(startingAt: popoverState.recentProjects.first
            .map { ($0.path as NSString).deletingLastPathComponent }) else { return }
        guard let preset = preset ?? presets(for: folder).first else { return }
        startSession(preset, in: folder)
    }

    func startSession(_ preset: LaunchPreset, in folder: String) {
        guard preset.place == .window else { return Launcher.launch(line: LaunchPlan.terminalLine(for: preset, in: folder)) }
        hostClient.spawn(SpawnRequest(cwd: folder, command: LaunchPlan.command(for: preset), env: preset.env,
                                      cols: 120, rows: 36, keepShell: preset.keepShell, label: preset.name,
                                      agent: preset.agent?.rawValue)) { [weak self] result in
            switch result {
            case .success(let session):
                self?.showMainWindow(select: session.id)
            case .failure(let error):
                // The window can't take it: start it in Terminal as before, and say why.
                Launcher.launch(line: LaunchPlan.terminalLine(for: preset, in: folder))
                self?.notifier?.postInfo(title: "Started in Terminal instead",
                                         body: "The VibeSwitcher window couldn't start it: \(error.message)")
            }
        }
    }

    /// Stops the agent in its Terminal tab (between turns only) and resumes the same conversation in the window.
    private func moveToWindow(_ session: Session, ask: Bool = true) {
        guard MoveToWindow.canMove(session), let sessionID = session.agentSessionID, let cwd = session.cwd else { return NSSound.beep() }
        if ask {
            let alert = NSAlert()
            alert.messageText = "Move “\(session.task ?? session.displayName)” to the window?"
            alert.informativeText = "\(session.agent.displayName) quits in its Terminal tab and picks up the same conversation here, "
                + "in a full-color terminal that keeps running when VibeSwitcher quits. The Terminal tab stays open."
            alert.addButton(withTitle: "Move to Window")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        // Still between turns, and still the same process (it may have started working while we asked).
        guard let current = store.sessions.first(where: { $0.identity == session.identity }), MoveToWindow.canMove(current) else {
            notifier?.postInfo(title: "Not moved", body: "It started working again; move it once it's done.")
            return
        }
        let plan = MoveToWindow.plan(agent: session.agent, sessionID: sessionID, presets: presets(for: cwd))
        let (pid, startedAt) = (session.pid, session.startedAt)
        // The very process the scan saw, not a later one that got its pid.
        guard SessionIdentity.isRunning(pid: pid, startedAt: startedAt) else { return }
        // And still between turns right now: the scan can be a second or two old, and a prompt you typed in Terminal
        // meanwhile would have its turn cut off.
        guard LeadDelivery.way(for: HookState.load(from: VibePaths.stateFile(tty: session.tty))) == .type else {
            notifier?.postInfo(title: "Not moved", body: "It started working again; move it once it's done.")
            return
        }
        Breadcrumbs.shared.note("move: stopping \(session.agent.displayName) on \(session.tty) (pid \(pid)) to resume in the window")
        kill(pid, SIGTERM)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // It has to be gone before the conversation is resumed elsewhere.
            let deadline = Date().addingTimeInterval(5)
            while SessionIdentity.isRunning(pid: pid, startedAt: startedAt), Date() < deadline { usleep(100_000) }
            let stopped = !SessionIdentity.isRunning(pid: pid, startedAt: startedAt)
            DispatchQueue.main.async {
                guard let self else { return }
                guard stopped else {
                    self.notifier?.postInfo(title: "Not moved", body: "\(session.agent.displayName) didn't quit in Terminal, so it still runs there.")
                    return
                }
                self.hostClient.spawn(SpawnRequest(cwd: cwd, command: plan.command, env: plan.env, cols: 120, rows: 36,
                                                   keepShell: false, label: plan.label, agent: session.agent.rawValue)) { [weak self] result in
                    switch result {
                    case .success(let hosted): self?.showMainWindow(select: hosted.id)
                    case .failure(let error):
                        self?.notifier?.postInfo(title: "Couldn't resume it in the window",
                                                 body: "\(error.message) Resume it in Terminal with: \(plan.command)")
                    }
                }
            }
        }
    }

    private func endSession(_ row: WindowRow) {
        guard let id = row.hostID else { return }
        let live = hostClient.sessions.first { $0.id == id }?.isLive ?? (row.session != nil)
        if let question = Self.endSessionQuestion(row, live: live) {
            let alert = NSAlert()
            alert.messageText = question.message
            alert.informativeText = question.detail
            alert.addButton(withTitle: "End Session").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        hostClient.kill(id)
    }

    /// What End Session… asks first. Always asked, idle or not, unless the session has ended already (nothing left
    /// to stop then).
    static func endSessionQuestion(_ row: WindowRow, live: Bool) -> (message: String, detail: String)? {
        guard live else { return nil }
        let state = row.session.map { "\($0.agent.displayName) is \($0.status.label.lowercased()). " } ?? ""
        return ("End “\(row.session?.displayName ?? row.title)”?",
                state + "Ending the session stops it and whatever runs in it, like closing its Terminal tab.")
    }

    private func resumeCommandLine(for row: WindowRow) -> String? {
        guard let cwd = row.cwd else { return nil }
        if let session = row.session, let id = session.agentSessionID {
            let base = row.hostID.flatMap { host in hostClient.sessions.first { $0.id == host }?.command }
            return RecentProjects.shellCommand(cd: cwd, run: LaunchPlan.resumeCommand(base: base, agent: session.agent, sessionID: id))
        }
        guard let host = row.hostID, let agentSession = windowModel.agentSessions[host] else { return nil }
        let base = hostClient.sessions.first { $0.id == host }?.command
        return RecentProjects.shellCommand(cd: cwd, run: LaunchPlan.resumeCommand(base: base, agent: agentSession.agent,
                                                                                    sessionID: agentSession.sessionID))
    }

    private func resumeSession(_ row: WindowRow) {
        guard let id = row.hostID, let info = hostClient.sessions.first(where: { $0.id == id }),
              let agentSession = windowModel.agentSessions[id] else { return }
        let command = LaunchPlan.resumeCommand(base: info.command, agent: agentSession.agent, sessionID: agentSession.sessionID)
        hostClient.spawn(SpawnRequest(cwd: info.cwd, command: command, env: [:], cols: info.cols, rows: info.rows,
                                      keepShell: false, label: info.label, agent: agentSession.agent.rawValue)) { [weak self] result in
            guard case .success(let session) = result else { return }
            self?.mainWindow?.pane.forget(id)
            self?.hostClient.remove(id)
            self?.showMainWindow(select: session.id)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Breadcrumbs.shared.note("app: quitting")
        Breadcrumbs.shared.flush()
        // Reopened at the next launch (an update relaunches the app: it shouldn't look like the window crashed).
        UserDefaults.standard.set(mainWindow?.window?.isVisible == true, forKey: "windowWasOpen")
        // Never leave session windows hidden behind a closed app.
        SidebarWorkspace.restoreHiddenWindows(timeout: 1)
        store.saveLedger()
        phoneAccess.shutdown()
    }

    func popoverDidClose(_ notification: Notification) {
        hostingView.rootView = AnyView(EmptyView())
    }

    private func startKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            let sessions = self.store.sessions
            switch Int(event.keyCode) {
            case kVK_DownArrow:
                self.popoverState.selectedIndex = min(self.popoverState.selectedIndex + 1, max(0, sessions.count - 1))
            case kVK_UpArrow:
                self.popoverState.selectedIndex = max(self.popoverState.selectedIndex - 1, 0)
            case kVK_Return, kVK_ANSI_KeypadEnter:
                if sessions.indices.contains(self.popoverState.selectedIndex) {
                    self.open(sessions[self.popoverState.selectedIndex])
                }
            case kVK_Escape:
                self.popover.performClose(nil)
            case kVK_ANSI_P where event.modifierFlags.intersection([.command, .control, .option]).isEmpty:
                // P: pause / resume the selected session.
                guard sessions.indices.contains(self.popoverState.selectedIndex) else { return event }
                let session = sessions[self.popoverState.selectedIndex]
                session.isPaused ? self.store.resume(session) : self.store.pause(session, for: .indefinitely)
            default:
                guard let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit),
                      sessions.indices.contains(digit - 1) else { return event }
                self.open(sessions[digit - 1])
            }
            return nil
        }
    }

    private func fitPopover() {
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        if size.width > 0, size.height > 0, popover.contentSize != size { popover.contentSize = size }
    }

    private func open(_ session: Session, source: String = "list") {
        if let hostID = session.hostID {
            popover.performClose(nil)
            store.acknowledge(session)
            notifier?.clear(tty: session.tty)
            if preferences.sidebarMode { sidebar.dismissAfterSelection() }
            showMainWindow(select: hostID)
            return
        }
        popover.performClose(nil)
        store.acknowledge(session)
        notifier?.clear(tty: session.tty)
        if preferences.sidebarMode { sidebar.dismissAfterSelection() }
        DispatchQueue.global(qos: .userInitiated).async {
            // Try the exact Terminal tab even if the last title scan missed it; fall back to the host app.
            var result = "terminal-tab"
            if session.inTerminalApp, let terminal = TerminalBridge.app {
                // Not in the middle of a reply the phone is typing (that would move its keystrokes).
                RemoteInput.focusLock.lock()
                defer { RemoteInput.focusLock.unlock() }
                var attempt = FocusLog.begin(session, source: source)
                // Activate first, then pick the tab: raising a window while Terminal is in the background
                // only reorders it, and Terminal re-fronts its previous key window when it activates.
                let activationStart = Date()
                let active = HostApp.bringToFrontAndWait(terminal)
                attempt.steps.append("activate Terminal: \(active ? "ok" : "timed out") (\(Int(Date().timeIntervalSince(activationStart) * 1000)) ms)")
                let focus = TerminalBridge.focusReport(tty: session.tty, onCurrentDesktop: session.windowOnCurrentDesktop)
                attempt.steps.append("select tab: \(focus.detail)")
                if !focus.ok { result = "tab-not-found" }
                else if !active { result = "terminal-tab (activation timed out)" }
                FocusLog.finish(attempt)
            } else {
                result = "host-app"
                DispatchQueue.main.sync { if !HostApp.activate(forPID: session.pid) { result = "failed" } }
            }
            DispatchQueue.main.async {
                AppStatus.extras["lastOpen"] = "\(session.tty) \(result) \(ISO8601DateFormatter().string(from: Date()))"
                AppStatus.write(sessions: self.store.sessions, terminalAccess: self.store.terminalAccess)
            }
        }
    }

    private func loadRecentProjects() {
        let observed = store.observedProjects
        DispatchQueue.global(qos: .userInitiated).async {
            let recents = Launcher.recentProjects(observed: observed)
            DispatchQueue.main.async {
                self.popoverState.recentProjects = recents
                self.windowModel.recentProjects = recents.map(\.path)
            }
        }
    }

    private func rename(_ session: Session) {
        popover.performClose(nil)
        let alert = NSAlert()
        alert.messageText = "Rename session"
        alert.informativeText = "Shown instead of “\(session.project)” in the list, tooltips and notifications, for as long as this session runs."
        let field = NSTextField(string: session.customName ?? "")
        field.placeholderString = session.task ?? session.project
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            store.rename(session, to: field.stringValue)
        }
    }

    private func installHooks() {
        popover.performClose(nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let problems = HookSetup.installAll()
            DispatchQueue.main.async {
                self.store.refreshHookStatus()
                self.setup.refresh()
                let alert = NSAlert()
                if problems.isEmpty {
                    alert.messageText = "Hooks installed"
                    alert.informativeText = "Claude Code and Codex sessions now report live status. Claude picks the hooks up in running sessions; Codex sessions started before now need a restart."
                } else {
                    alert.messageText = "Hooks installed with problems"
                    alert.informativeText = problems.joined(separator: "\n")
                }
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    private static func tooltip(for sessions: [Session]) -> String {
        guard !sessions.isEmpty else { return "VibeSwitcher: no agent sessions" }
        return sessions.map { "\($0.status.label)\($0.isPaused ? " (paused)" : ""): \($0.title)" }.joined(separator: "\n")
    }
}

/// Installs the hook binary and both agents' hook configs, and trusts the Codex hooks.
/// Returns human-readable problems (empty on success). Blocking: call off the main thread.
enum HookSetup {
    static func installAll() -> [String] {
        var problems: [String] = []
        if !HookBinary.sync(), !FileManager.default.fileExists(atPath: VibePaths.hookBinary.path) {
            problems.append("The hook binary could not be installed to \(VibePaths.hookBinary.path).")
        }
        for agent in Agent.allCases {
            do { try HookInstaller.install(agent: agent) } catch {
                problems.append("\(agent.displayName): \(error.localizedDescription)")
            }
        }
        do { try CodexTrust.trustOurHooks() } catch {
            problems.append("Codex hooks are installed but not trusted (\(error.localizedDescription)). Run /hooks in Codex and trust the vibeswitcher-hook entries.")
        }
        return problems
    }
}

/// Keeps `~/.vibeswitcher/bin/vibeswitcher-hook` in sync with the copy shipped inside the app bundle,
/// so the hook configs point at a stable path even if the app is moved.
enum HookBinary {
    static var bundled: URL? {
        let url = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("vibeswitcher-hook")
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    @discardableResult
    static func sync() -> Bool {
        guard let source = bundled, let data = try? Data(contentsOf: source) else { return false }
        let target = VibePaths.hookBinary
        if let existing = try? Data(contentsOf: target), existing == data { return true }
        do {
            try FileManager.default.createDirectory(at: VibePaths.binDir, withIntermediateDirectories: true)
            // Write-then-rename so a hook that is running right now never sees a half-written binary.
            let temp = VibePaths.binDir.appendingPathComponent(".vibeswitcher-hook.tmp")
            try data.write(to: temp)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
            return true
        } catch {
            NSLog("VibeSwitcher: failed to install hook binary: \(error)")
            return false
        }
    }
}
