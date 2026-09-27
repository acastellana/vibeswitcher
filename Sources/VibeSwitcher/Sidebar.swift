import AppKit
import SwiftUI
import VibeCore

/// Sidebar mode: the session list on the right edge of the screen, on every desktop. By default it
/// auto-hides: it slides in when the mouse touches the middle of the right edge (see `SidebarHotZone`)
/// and slides out once the mouse leaves.
/// It's a switcher: picking a session goes to it (its own desktop) exactly like the menu bar list.
final class SidebarController {
    static let width: CGFloat = 320
    /// How far the mouse may stray outside the sidebar before it starts hiding, and for how long.
    private static let leaveMargin: CGFloat = 24
    private static let hideDelay: TimeInterval = 0.25

    private let panel: NSPanel
    private let hostingView: NSHostingView<AnyView>
    private let content: AnyView

    /// Sidebar mode on/off.
    private(set) var isEnabled = false
    /// Slide in on the right edge (true) or stay docked (false).
    var autoHide = true {
        didSet { if isEnabled, autoHide != oldValue { autoHide ? conceal(animated: true) : reveal(on: currentScreen()) } }
    }
    private var revealed = false
    /// After picking a session the mouse is still near the edge; don't pop back until it has moved away.
    private var suppressedUntilAway = false
    private var menuOpen = false
    /// Shown briefly after a desktop switch; stays for the whole period unless the mouse takes over.
    private var flashing = false
    private var hideWork: DispatchWorkItem?
    private var monitors: [Any] = []
    /// Safety net: mouse-moved events can be missed (fast flicks into the edge, moments the system
    /// doesn't deliver them), so the pointer is also checked a few times a second while enabled.
    private var pollTimer: Timer?
    private var screen: NSScreen?
    // Diagnostics in ~/.vibeswitcher/sidebar-debug.json: how late the pointer checks run, and why
    // visits to the right edge didn't open the sidebar (counted per pointer check, not per visit).
    private var lastPoll = Date()
    private var pollGaps: [Double] = []
    private var edgeMisses: [String: Int] = [:]
    private var edgeHits = 0
    private var lastDebugWrite = Date()
    private var totalPolls = 0
    private var lastWrittenVisits = -1

    init(content: AnyView) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true // moves over the sidebar itself reach the local monitor
        self.content = content
        hostingView = FirstMouseHostingView(rootView: AnyView(EmptyView()))
        panel.contentView = hostingView
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.revealed else { return }
            self.panel.setFrame(self.dockedFrame(on: self.screen ?? self.currentScreen()), display: true)
        }
        // Keep the sidebar open while one of its menus (⊕, ⚙︎, right-click) is open.
        center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.menuOpen = true
            self?.hideWork?.cancel()
        }
        center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.menuOpen = false
            self?.mouseMoved()
        }
    }

    var isShown: Bool { panel.isVisible }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            // Global monitors see mouse moves over other apps (no permission needed for mouse events);
            // the local one covers moves over our own panel.
            let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
            if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.mouseMoved() }) {
                monitors.append(global)
            }
            if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
                self?.mouseMoved()
                return event
            }) { monitors.append(local) }
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                self?.recordPoll()
                self?.mouseMoved()
            }
            pollTimer?.tolerance = 0.05
            if !autoHide { reveal(on: currentScreen()) }
        } else {
            monitors.forEach(NSEvent.removeMonitor)
            monitors.removeAll()
            pollTimer?.invalidate()
            pollTimer = nil
            conceal(animated: false)
        }
    }

    /// After a desktop switch: slide in for a moment (highlighting the session there), then slide out.
    func flash(for duration: TimeInterval = 2.5) {
        guard isEnabled, autoHide else { return }
        flashing = true
        reveal(on: currentScreen())
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWork = nil
            self.flashing = false
            let inside = self.panel.frame.insetBy(dx: -Self.leaveMargin, dy: -Self.leaveMargin).contains(NSEvent.mouseLocation)
            if !inside, !self.menuOpen { self.conceal(animated: true) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Called after a session was picked: get out of the way until the mouse leaves and comes back.
    func dismissAfterSelection() {
        guard isEnabled, autoHide else { return }
        suppressedUntilAway = true
        conceal(animated: true)
    }

    private func mouseMoved() {
        guard isEnabled, autoHide else { return }
        let point = NSEvent.mouseLocation
        let screen = currentScreen()
        if revealed {
            let inside = panel.frame.insetBy(dx: -Self.leaveMargin, dy: -Self.leaveMargin).contains(point)
            if flashing {
                // Mouse moves elsewhere don't cut a flash short; entering the sidebar makes it stay.
                if inside {
                    flashing = false
                    hideWork?.cancel()
                    hideWork = nil
                }
                return
            }
            if inside || menuOpen {
                hideWork?.cancel()
                hideWork = nil
            } else if hideWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.hideWork = nil
                    self?.conceal(animated: true)
                }
                hideWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDelay, execute: work)
            }
            return
        }
        let atEdge = point.x >= screen.frame.maxX - 8
        if suppressedUntilAway {
            // After picking a session: re-arm as soon as the pointer has left the edge for a moment.
            if point.x < screen.frame.maxX - 40 { suppressedUntilAway = false }
            if atEdge { edgeMisses["suppressed", default: 0] += 1 }
            return
        }
        if SidebarHotZone.contains(point, screen: screen.frame), isOuterRightEdge(of: screen, at: point.y) {
            edgeHits += 1
            reveal(on: screen)
        } else if atEdge {
            let reason = !SidebarHotZone.contains(point, screen: screen.frame)
                ? (point.x < screen.frame.maxX - SidebarHotZone.edgeWidth ? "x=\(Int(screen.frame.maxX - point.x))pt short" : "outside band")
                : "not outer edge"
            edgeMisses[reason, default: 0] += 1
        }
    }

    private func recordPoll() {
        let now = Date()
        pollGaps.append(now.timeIntervalSince(lastPoll))
        lastPoll = now
        if pollGaps.count > 3000 { pollGaps.removeFirst(pollGaps.count - 3000) }
        totalPolls += 1
        // Only when something happened at the edge (or every 10 minutes): no steady disk writes.
        let visits = edgeHits + edgeMisses.values.reduce(0, +)
        guard visits != lastWrittenVisits || now.timeIntervalSince(lastDebugWrite) > 600 else { return }
        lastWrittenVisits = visits
        lastDebugWrite = now
        let sorted = pollGaps.sorted()
        let object: [String: Any] = [
            "updatedAt": ISO8601DateFormatter().string(from: now),
            "polls": pollGaps.count, "gapMedian": sorted[sorted.count / 2], "gapMax": sorted.last ?? 0.0 as Double,
            "gapsOver1s": pollGaps.filter { $0 > 1 }.count, "gapsOver0_5s": pollGaps.filter { $0 > 0.5 }.count,
            "edgeHits": edgeHits, "edgeMisses": edgeMisses, "totalPolls": totalPolls,
        ]
        if JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: VibePaths.root.appendingPathComponent("sidebar-debug.json"))
        }
    }

    /// False where another display continues to the right: the pointer just crosses over there.
    private func isOuterRightEdge(of screen: NSScreen, at y: CGFloat) -> Bool {
        !NSScreen.screens.contains { other in
            other != screen && abs(other.frame.minX - screen.frame.maxX) < 1 && other.frame.minY <= y && y <= other.frame.maxY
        }
    }

    private func currentScreen() -> NSScreen {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func dockedFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        return NSRect(x: visible.maxX - Self.width, y: visible.minY, width: Self.width, height: visible.height)
    }

    private func reveal(on screen: NSScreen) {
        hideWork?.cancel()
        hideWork = nil
        suppressedUntilAway = false
        self.screen = screen
        let docked = dockedFrame(on: screen)
        if !revealed {
            revealed = true
            hostingView.rootView = content
            panel.setFrame(docked.offsetBy(dx: Self.width, dy: 0), display: false) // start just off screen
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(docked, display: true)
        }
    }

    private func conceal(animated: Bool) {
        hideWork?.cancel()
        hideWork = nil
        guard revealed else { return }
        revealed = false
        let finish = { [weak self] in
            guard let self, !self.revealed else { return }
            self.panel.orderOut(nil)
            self.hostingView.rootView = AnyView(EmptyView()) // no SwiftUI work while hidden
        }
        guard animated else { return finish() }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(panel.frame.offsetBy(dx: Self.width, dy: 0), display: true)
        }, completionHandler: finish)
    }
}

/// Earlier versions of sidebar mode hid the other session windows. This only remains as a safety net:
/// any window still recorded as hidden gets shown again (on quit, when leaving sidebar mode, at launch).
enum SidebarWorkspace {
    private static let hiddenKey = "sidebarHiddenWindows"

    static var hiddenWindows: Set<Int> {
        get { Set(UserDefaults.standard.array(forKey: hiddenKey) as? [Int] ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: hiddenKey) }
    }

    /// Makes every window recorded as hidden visible again.
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
