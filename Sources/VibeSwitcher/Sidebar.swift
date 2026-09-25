import AppKit
import SwiftUI
import VibeCore

/// Sidebar mode: a list of sessions docked to the right edge of the screen, on every desktop. Picking
/// a session shows only that session's Terminal window, on the current desktop, filling the rest of
/// the screen; the other session windows are hidden until you pick them.
final class SidebarController {
    static let width: CGFloat = 320
    private static let gap: CGFloat = 8

    private let panel: NSPanel
    private let hostingView: NSHostingView<AnyView>
    private let content: AnyView

    init(content: AnyView) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        self.content = content
        hostingView = FirstMouseHostingView(rootView: AnyView(EmptyView()))
        panel.contentView = hostingView
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.place() }
    }

    var isShown: Bool { panel.isVisible }

    func setShown(_ shown: Bool) {
        if shown {
            hostingView.rootView = content
            place()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
            hostingView.rootView = AnyView(EmptyView()) // no SwiftUI work while hidden
        }
    }

    private func place() {
        guard let visible = NSScreen.main?.visibleFrame else { return }
        panel.setFrame(NSRect(x: visible.maxX - Self.width, y: visible.minY, width: Self.width, height: visible.height),
                       display: true)
    }

    /// Where a session window goes: the main screen's usable area left of the sidebar, in AppleScript's
    /// top-left-origin coordinates ({left, top, right, bottom}).
    static func sessionBounds() -> [Int]? {
        guard let screen = NSScreen.main, let primary = NSScreen.screens.first else { return nil }
        let visible = screen.visibleFrame
        let top = primary.frame.maxY - visible.maxY
        let bottom = primary.frame.maxY - visible.minY
        return [Int(visible.minX), Int(top), Int(visible.maxX - width - gap), Int(bottom)]
    }
}

/// The window juggling behind sidebar mode. Every window it hides is remembered (also on disk), so
/// leaving the mode, quitting, or relaunching after a crash always shows them again.
enum SidebarWorkspace {
    private static let hiddenKey = "sidebarHiddenWindows"

    static var hiddenWindows: Set<Int> {
        get { Set(UserDefaults.standard.array(forKey: hiddenKey) as? [Int] ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: hiddenKey) }
    }

    /// Hides the other session windows, brings `session`'s window to the current desktop beside the
    /// sidebar, selects its tab and activates Terminal. Blocking (AppleScript): call off the main thread.
    /// Returns false when the session can't be handled this way (not in Terminal, full-screen window).
    @discardableResult
    static func show(_ session: Session, among sessions: [Session]) -> Bool {
        guard let target = session.terminalWindowID, let position = session.screenPosition, !position.fullscreen,
              let bounds = SidebarController.sessionBounds() else { return false }
        // Other session windows, except full-screen ones (hiding those breaks their space) and the
        // target's own window (it may hold several sessions as tabs).
        let others = Set(sessions.compactMap { other -> Int? in
            guard let id = other.terminalWindowID, id != target, other.screenPosition?.fullscreen != true else { return nil }
            return id
        })
        let hideList = others.map(String.init).joined(separator: ", ")
        let script = """
        tell application "Terminal"
            repeat with wid in {\(hideList)}
                try
                    set visible of window id wid to false
                end try
            end repeat
            set w to window id \(target)
            try
                set miniaturized of w to false
            end try
            set visible of w to true
            set bounds of w to {\(bounds.map(String.init).joined(separator: ", "))}
            set selected tab of w to tab \(position.tabIndex) of w
            set index of w to 1
        end tell
        """
        let result = TerminalBridge.runAppleScript(script)
        guard result.status == 0 else {
            NSLog("VibeSwitcher: sidebar show failed: \(result.error)")
            return false
        }
        var hidden = hiddenWindows
        hidden.formUnion(others)
        hidden.remove(target)
        hiddenWindows = hidden
        if let terminal = TerminalBridge.app { _ = HostApp.bringToFrontAndWait(terminal) }
        return true
    }

    /// Makes every window sidebar mode hid visible again (they appear on the current desktop).
    static func restoreHiddenWindows() {
        let hidden = hiddenWindows
        guard !hidden.isEmpty else { return }
        let list = hidden.map(String.init).joined(separator: ", ")
        let script = """
        tell application "Terminal"
            repeat with wid in {\(list)}
                try
                    set visible of window id wid to true
                end try
            end repeat
        end tell
        """
        if TerminalBridge.isRunning { _ = TerminalBridge.runAppleScript(script) }
        hiddenWindows = []
    }
}
