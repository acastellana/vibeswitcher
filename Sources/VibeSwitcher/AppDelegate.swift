import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import VibeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        HookBinary.sync()
        preferences.setUpLoginItemOnFirstLaunch()
        notifier.requestAuthorization()
        notifier.onOpen = { [weak self] tty in
            guard let self, let session = self.store.sessions.first(where: { $0.tty == tty }) else { return }
            self.open(session)
        }
        store.onAttention = { [weak self] session in self?.notifier.post(for: session) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
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

        store.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                guard let self else { return }
                self.statusItem.button?.image = StatusIcon.image(for: sessions)
                self.statusItem.button?.toolTip = Self.tooltip(for: sessions)
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

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        store.refresh(forceTerminal: true)
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
