import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import VibeCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSViewToolTipOwner {
    private let store = SessionStore()
    private let popoverState = PopoverState()
    private let preferences = Preferences()
    private lazy var notifier = Notifier(preferences: preferences)
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var hotKey: HotKey?
    private var keyMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []
    private var hostingView: NSHostingView<AnyView>!
    private var floatingPanel: FloatingPanelController!
    private var visibilityTimer: Timer?
    private var hiddenReadings = 0
    private var notificationTimer: Timer?
    /// Stored by macOS as the distance from the right screen edge; set once so we start next to the
    /// clock, where an overflowing menu bar never hides items. ⌘-dragging the icon overrides it.
    private static let statusItemName = "VibeSwitcher"
    private static let positionKey = "NSStatusItem Preferred Position VibeSwitcher"

    func applicationDidFinishLaunching(_ notification: Notification) {
        HookBinary.sync()
        preferences.setUpLoginItemOnFirstLaunch()
        notifier.requestAuthorization()
        notifier.onOpen = { [weak self] tty in
            guard let self, let session = self.store.sessions.first(where: { $0.tty == tty }) else { return }
            self.open(session)
        }
        store.onAttention = { [weak self] session in self?.notifier.post(for: session) }

        if UserDefaults.standard.object(forKey: Self.positionKey) == nil {
            UserDefaults.standard.set(120.0, forKey: Self.positionKey)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = Self.statusItemName
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.image = StatusIcon.image(for: [])

        let view = PopoverView(store: store, state: popoverState, preferences: preferences,
                               onOpen: { [weak self] in self?.open($0) },
                               onInstallHooks: { [weak self] in self?.installHooks() },
                               onQuit: { NSApp.terminate(nil) })
        hostingView = FirstMouseHostingView(rootView: AnyView(view))
        let controller = NSViewController()
        controller.view = hostingView
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = false

        floatingPanel = FloatingPanelController(store: store, onOpen: { [weak self] in self?.open($0) },
                                                onShowList: { [weak self] anchor in self?.togglePopover(anchor: anchor) })
        preferences.$floatingPanel
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateFloatingPanel() } }
            .store(in: &cancellables)
        visibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.updateFloatingPanel()
        }
        notificationTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.notifier.refreshAuthorization()
        }

        store.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                guard let self else { return }
                self.statusItem.button?.image = StatusIcon.image(for: sessions)
                DispatchQueue.main.async {
                    self.updateDotToolTips()
                    self.floatingPanel.fit()
                }
                self.popoverState.selectedIndex = min(self.popoverState.selectedIndex, max(0, sessions.count - 1))
                DispatchQueue.main.async { self.fitPopover() }
            }
            .store(in: &cancellables)

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
            self.open(session)
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
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if !secondary, let event, let index = dotIndex(at: event, in: sender), store.sessions.indices.contains(index) {
            open(store.sessions[index])
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
        AppStatus.extras["menuBar"] = ["buttonWidth": button.bounds.width, "imageX": rect.minX, "imageWidth": rect.width,
                                       "flipped": button.isFlipped]
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        let index = Int(bitPattern: data) - 1
        guard store.sessions.indices.contains(index) else { return "" }
        let session = store.sessions[index]
        let task = session.task.map { "\n\($0)" } ?? ""
        return "\(index + 1). \(session.project) · \(session.status.label)\(task)\nClick to switch · right-click for the list"
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
        let show: Bool
        switch preferences.floatingPanel {
        case .always: show = true
        case .never: show = false
        case .automatic: show = hiddenReadings >= 2
        }
        let changed = show != floatingPanel.isShown
        floatingPanel.setShown(show)
        AppStatus.extras["menuBarIconVisible"] = visible
        AppStatus.extras["floatingPanelShown"] = show
        if let frame = statusItem.button?.window?.frame {
            AppStatus.extras["menuBarIconFrame"] = ["x": frame.minX, "width": frame.width]
        }
        if changed { AppStatus.write(sessions: store.sessions, terminalAccess: store.terminalAccess) }
    }

    @objc private func togglePopover() {
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
        notifier.refreshAuthorization()
        popoverState.selectedIndex = store.sessions.firstIndex { $0.status == .needsInput }
            ?? store.sessions.firstIndex { $0.status == .done } ?? 0
        fitPopover()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        startKeyMonitor()
        AppStatus.write(sessions: store.sessions, terminalAccess: store.terminalAccess, extra: ["popoverOpenedAt": ISO8601DateFormatter().string(from: Date())])
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

    private func open(_ session: Session) {
        popover.performClose(nil)
        store.acknowledge(session)
        notifier.clear(tty: session.tty)
        DispatchQueue.global(qos: .userInitiated).async {
            // Try the exact Terminal tab even if the last title scan missed it; fall back to the host app.
            var result = "terminal-tab"
            if session.inTerminalApp, let terminal = TerminalBridge.app {
                // Activate first, then pick the tab: raising a window while Terminal is in the background
                // only reorders it, and Terminal re-fronts its previous key window when it activates.
                let active = HostApp.bringToFrontAndWait(terminal)
                if !TerminalBridge.focus(tty: session.tty) { result = "tab-not-found" }
                else if !active { result = "terminal-tab (activation timed out)" }
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

    private func installHooks() {
        popover.performClose(nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let problems = HookSetup.installAll()
            DispatchQueue.main.async {
                self.store.refreshHookStatus()
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
        return sessions.map { "\($0.status.label): \($0.title)" }.joined(separator: "\n")
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
