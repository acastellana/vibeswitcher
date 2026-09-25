import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import VibeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private let popoverState = PopoverState()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var hotKey: HotKey?
    private var keyMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        HookBinary.sync()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.image = StatusIcon.image(for: [])

        let view = PopoverView(store: store, state: popoverState,
                               onOpen: { [weak self] in self?.open($0) },
                               onInstallHooks: { [weak self] in self?.installHooks() },
                               onQuit: { NSApp.terminate(nil) })
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false

        store.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                guard let self else { return }
                self.statusItem.button?.image = StatusIcon.image(for: sessions)
                self.statusItem.button?.toolTip = Self.tooltip(for: sessions)
                self.popoverState.selectedIndex = min(self.popoverState.selectedIndex, max(0, sessions.count - 1))
            }
            .store(in: &cancellables)

        hotKey = HotKey(keyCode: kVK_ANSI_V, modifiers: controlKey | optionKey) { [weak self] in
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
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        startKeyMonitor()
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

    private func open(_ session: Session) {
        popover.performClose(nil)
        store.acknowledge(session)
        DispatchQueue.global(qos: .userInitiated).async {
            if session.inTerminalApp, TerminalBridge.focus(tty: session.tty) { return }
            DispatchQueue.main.async { _ = HostApp.activate(forPID: session.pid) }
        }
    }

    private func installHooks() {
        HookBinary.sync()
        var errors: [String] = []
        for agent in Agent.allCases {
            do { try HookInstaller.install(agent: agent) } catch { errors.append("\(agent.displayName): \(error.localizedDescription)") }
        }
        store.refreshHookStatus()
        popover.performClose(nil)

        let alert = NSAlert()
        if errors.isEmpty {
            alert.messageText = "Hooks installed"
            alert.informativeText = """
            New Claude Code and Codex sessions will now report live status. Sessions that are already running keep their old configuration: restart them to pick up the hooks.

            Codex asks you to trust new hooks once: run /hooks inside Codex and trust the vibeswitcher-hook entries.
            """
        } else {
            alert.messageText = "Some hooks could not be installed"
            alert.informativeText = errors.joined(separator: "\n")
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func tooltip(for sessions: [Session]) -> String {
        guard !sessions.isEmpty else { return "VibeSwitcher: no agent sessions" }
        return sessions.map { "\($0.status.label): \($0.title)" }.joined(separator: "\n")
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
