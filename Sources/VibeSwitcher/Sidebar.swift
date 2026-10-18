import AppKit
import SwiftUI
import VibeCore

/// Sidebar mode: the session list on the right edge of the screen, on every desktop. By default it
/// auto-hides: it slides in when the mouse touches the middle of the right edge (see `SidebarHotZone`)
/// and slides out once the mouse leaves.
/// It's a switcher: picking a session goes to it (its own desktop) exactly like the menu bar list.
///
/// The pointer is followed with tracking areas, not by watching the mouse: a see-through strip on each right edge's
/// hot zone says when it gets there. While the sidebar is out, the pointer is looked at every quarter second until
/// it's gone (it can't be tracked outside the panel); while it's hidden, nothing runs.
final class SidebarController {
    static let width: CGFloat = 320
    /// How far the mouse may stray outside the sidebar before it starts hiding, and for how long.
    private static let leaveMargin: CGFloat = 24
    private static let hideDelay: TimeInterval = 0.25

    private let panel: NSPanel
    private let hostingView: NSHostingView<AnyView>
    private let content: AnyView
    private let tracker = PointerTracker()
    /// One per stretch of right edge that reveals the sidebar; only while it auto-hides.
    private var strips: [EdgeStrip] = []

    /// Sidebar mode on/off.
    private(set) var isEnabled = false
    /// Slide in on the right edge (true) or stay docked (false).
    var autoHide = true {
        didSet {
            guard isEnabled, autoHide != oldValue else { return }
            updateStrips()
            autoHide ? conceal(animated: true) : currentScreen().map { reveal(on: $0) }
        }
    }
    private var revealed = false
    /// After picking a session the mouse can still be on the edge; don't pop back until it has left it.
    private var suppressedUntilAway = false
    private var menuOpen = false
    /// Shown briefly after a desktop switch; stays for the whole period unless the mouse takes over.
    private var flashing = false
    private var hideWork: DispatchWorkItem?
    private var screen: NSScreen?
    // Diagnostics in ~/.vibeswitcher/sidebar-debug.json: visits to the edge, and the last slide in/out steps.
    private var edgeHits = 0
    private var edgeMisses: [String: Int] = [:]
    /// Last misses with time and height, to match a "it just didn't open" report.
    private var recentMisses: [String] = []
    private var lastMissRecorded = Date.distantPast
    /// The last slide in/out steps (what the window really did), to explain the next "it didn't show".
    private var trail: [String] = []
    private var debugWritePending = false

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
        // The tracking area sits on a plain container: the hosting view manages its own.
        let container = NSView()
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        container.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                                 owner: tracker, userInfo: nil))
        panel.contentView = container
        tracker.entered = { [weak self] in self?.pointerEnteredSidebar() }
        tracker.exited = { [weak self] in self?.pointerLeftSidebar() }
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.updateStrips()
            guard self.revealed, let screen = self.screen ?? self.currentScreen() else { return }
            self.panel.setFrame(self.dockedFrame(on: screen), display: true)
        }
        // Keep the sidebar open while one of its menus (⊕, ⚙︎, right-click) is open.
        center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.menuOpen = true
        }
        center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.menuOpen = false
            if self?.flashing == false { self?.watchPointer() }
        }
    }

    var isShown: Bool { panel.isVisible }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        updateStrips()
        if enabled {
            if !autoHide, let screen = currentScreen() { reveal(on: screen) }
        } else {
            conceal(animated: false)
        }
    }

    /// After a desktop switch: slide in for a moment (highlighting the session there), then slide out.
    func flash(for duration: TimeInterval = 2.5) {
        guard isEnabled, autoHide else { return }
        guard let screen = currentScreen() else { return }
        flashing = true
        reveal(on: screen)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWork = nil
            self.flashing = false
            // The pointer on it: it stays, and leaving hides it as usual.
            self.watchPointer(after: 0)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Called after a session was picked: get out of the way until the mouse leaves the edge and comes back.
    func dismissAfterSelection() {
        guard isEnabled, autoHide else { return }
        let point = NSEvent.mouseLocation
        suppressedUntilAway = strips.contains { $0.frame.contains(point) }
        conceal(animated: true)
    }

    // MARK: Pointer

    /// The pointer reached a strip on `screen`'s right edge.
    private func pointerReachedEdge(of screen: NSScreen) {
        guard isEnabled, autoHide else { return }
        healIfStranded(on: screen)
        guard !revealed else { return }
        if suppressedUntilAway { return recordMiss("suppressed", point: NSEvent.mouseLocation, screen: screen) }
        edgeHits += 1
        reveal(on: screen)
    }

    private func pointerLeftEdge() {
        suppressedUntilAway = false
    }

    private func pointerEnteredSidebar() {
        guard isEnabled, autoHide, revealed, flashing else { return }
        // Entering the sidebar during a flash makes it stay (until the pointer leaves).
        flashing = false
        watchPointer()
    }

    /// Leaving: hide in `hideDelay` (unless it's back by then), not at the next look.
    private func pointerLeftSidebar() {
        guard isEnabled, autoHide, revealed, !flashing else { return }
        watchPointer()
    }

    /// While the sidebar is out (auto-hiding, not flashing), where the pointer is, every `hideDelay`: it hides once
    /// the pointer is more than `leaveMargin` outside it and none of its menus is open. A tracking area can't follow
    /// the pointer out there, and one that appeared under a still pointer may never hear it leave.
    private func watchPointer(after delay: TimeInterval = SidebarController.hideDelay) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWork = nil
            guard self.isEnabled, self.autoHide, self.revealed, !self.flashing else { return }
            let near = self.panel.frame.insetBy(dx: -Self.leaveMargin, dy: -Self.leaveMargin).contains(NSEvent.mouseLocation)
            if near || self.menuOpen { return self.watchPointer() }
            self.conceal(animated: true)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Believed shown but it isn't (an animation never finished, or it got stuck off screen): start over.
    private func healIfStranded(on screen: NSScreen) {
        guard isStrandedOffScreen else { return }
        let reason = animating ? "healed: animation never finished" : "healed: was stuck off screen"
        recordMiss(reason, point: NSEvent.mouseLocation, screen: screen)
        note(reason)
        animating = false
        revealed = false
        transition += 1
        panel.orderOut(nil)
        hostingView.rootView = AnyView(EmptyView())
    }

    /// Strips on every right edge's hot zone while the sidebar auto-hides; none otherwise.
    private func updateStrips() {
        strips.forEach { $0.close() }
        strips = []
        guard isEnabled, autoHide else { return }
        let frames = NSScreen.screens.map(\.frame)
        for screen in NSScreen.screens {
            for frame in SidebarHotZone.strips(on: screen.frame, screens: frames) {
                strips.append(EdgeStrip(frame: frame, entered: { [weak self, weak screen] in
                    if let screen { self?.pointerReachedEdge(of: screen) }
                }, exited: { [weak self] in self?.pointerLeftEdge() }))
            }
        }
        note("watching \(strips.count) edge strip(s)")
    }

    private func recordMiss(_ reason: String, point: NSPoint, screen: NSScreen) {
        edgeMisses[reason, default: 0] += 1
        // One entry per visit: at most every 2 s.
        guard Date().timeIntervalSince(lastMissRecorded) > 2 else { return }
        lastMissRecorded = Date()
        let height = Int(((point.y - screen.frame.minY) / screen.frame.height * 100).rounded())
        let time = Date().formatted(date: .omitted, time: .standard)
        recentMisses = Array(([String(format: "%@  %@  (x %.1f, %d%% up)", time, reason, point.x, height)] + recentMisses).prefix(30))
        writeDebugSoon()
    }

    /// Only when something happened, and at most every 2 s: no steady disk writes.
    private func writeDebugSoon() {
        guard !debugWritePending else { return }
        debugWritePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.debugWritePending = false
            let object: [String: Any] = [
                "updatedAt": ISO8601DateFormatter().string(from: Date()),
                "edgeHits": self.edgeHits, "edgeMisses": self.edgeMisses, "recentMisses": self.recentMisses, "trail": self.trail,
                "strips": self.strips.map { NSStringFromRect($0.frame) },
            ]
            if JSONSerialization.isValidJSONObject(object),
               let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: VibePaths.root.appendingPathComponent("sidebar-debug.json"))
            }
        }
    }

    /// The display under the pointer; nil when there's no display at all.
    private func currentScreen() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func dockedFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        return NSRect(x: visible.maxX - Self.width, y: visible.minY, width: Self.width, height: visible.height)
    }

    /// Bumped by every slide in/out; an animation's completion only acts if no newer one started.
    private var transition = 0
    private var animating = false {
        didSet { animationStartedAt = animating ? Date() : nil }
    }
    private var animationStartedAt: Date?

    private func note(_ step: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        let state = String(format: "visible %@, this desktop %@, x %.0f", panel.isVisible ? "yes" : "no",
                           panel.isOnActiveSpace ? "yes" : "no", panel.frame.minX)
        trail = Array((["\(time)  \(step)  (\(state))"] + trail).prefix(30))
        writeDebugSoon()
    }

    private func reveal(on screen: NSScreen) {
        hideWork?.cancel()
        hideWork = nil
        suppressedUntilAway = false
        self.screen = screen
        // Absolute targets, never relative to the current frame: interrupted animations used to leave
        // the panel further off screen each time while we believed it was shown.
        let docked = dockedFrame(on: screen)
        if !revealed { note(String(format: "reveal → x %.0f", docked.minX)) }
        revealed = true
        if autoHide, !flashing { watchPointer() }
        if !panel.isVisible {
            hostingView.rootView = content
            panel.setFrame(docked.offsetBy(dx: Self.width, dy: 0), display: false)   // start just off screen
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        guard panel.frame != docked else { return }
        transition += 1
        let id = transition
        animating = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.isReduced ? 0 : 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(docked, display: true)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            guard self.transition == id else { return self.note("reveal #\(id) superseded") }
            self.animating = false
            if self.revealed { self.panel.setFrame(docked, display: true) }   // land exactly
            self.note("reveal #\(id) done")
        })
    }

    private func conceal(animated: Bool) {
        hideWork?.cancel()
        hideWork = nil
        guard revealed else { return }
        revealed = false
        transition += 1
        let id = transition
        guard let target = screen ?? currentScreen() else { return }
        let hidden = dockedFrame(on: target).offsetBy(dx: Self.width, dy: 0)
        note("conceal #\(id)\(animated ? "" : " (instant)")")
        let finish = { [weak self] in
            guard let self else { return }
            guard self.transition == id, !self.revealed else { return self.note("conceal #\(id) superseded") }
            self.animating = false
            self.panel.orderOut(nil)
            self.panel.setFrame(hidden, display: false)
            self.hostingView.rootView = AnyView(EmptyView()) // no SwiftUI work while hidden
            self.note("conceal #\(id) done")
        }
        guard animated, !Motion.isReduced else { return finish() }
        animating = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(hidden, display: true)
        }, completionHandler: finish)
    }

    /// Safety net: "shown" but not actually on screen where it belongs, outside any animation, or with
    /// an animation that should have finished long ago (its completion was lost: it once stayed stuck so).
    private var isStrandedOffScreen: Bool {
        guard revealed else { return false }
        if animating, !SidebarAnimation.isStale(startedAt: animationStartedAt, now: Date()) { return false }
        guard let target = screen ?? currentScreen() else { return false }
        let docked = dockedFrame(on: target)
        return !panel.isVisible || abs(panel.frame.minX - docked.minX) > 1
    }
}


/// Says when the pointer comes into and leaves a tracking area it owns.
private final class PointerTracker: NSResponder {
    var entered: () -> Void = {}
    var exited: () -> Void = {}

    override func mouseEntered(with event: NSEvent) { entered() }
    override func mouseExited(with event: NSEvent) { exited() }
}

/// A see-through strip over a stretch of a screen's right edge whose tracking area says when the pointer gets there,
/// on every desktop and over full-screen apps, as the sidebar is.
private final class EdgeStrip {
    let frame: NSRect
    private let panel: NSPanel
    private let tracker = PointerTracker()

    init(frame: NSRect, entered: @escaping () -> Void, exited: @escaping () -> Void) {
        self.frame = frame
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Under the sidebar, which covers it while shown.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        // Not quite clear: the window server sends no mouse events to a fully transparent window.
        panel.backgroundColor = NSColor(white: 0, alpha: 0.01)
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                            owner: tracker, userInfo: nil))
        panel.contentView = view
        tracker.entered = entered
        tracker.exited = exited
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
    }

    func close() { panel.orderOut(nil) }
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
    /// `timeout`: short at quit (Terminal busy must not hold the quit up; what's left is restored at the next launch).
    static func restoreHiddenWindows(timeout: TimeInterval = 4) {
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
        guard TerminalBridge.isRunning else { return }
        // Only forgotten once Terminal has done it; otherwise the next launch tries again.
        if TerminalBridge.runAppleScript(script, timeout: timeout).status == 0 { hiddenWindows = [] }
    }
}
