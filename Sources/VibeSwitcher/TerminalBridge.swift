import AppKit
import CoreGraphics
import Foundation
import VibeCore

struct TerminalTab: Equatable {
    let windowID: Int
    let title: String
    /// Window frame (top-left origin) and the tab's index in that window.
    let position: ScreenPosition?
    let isSelected: Bool
    /// Position of the window in Terminal's front-to-back order (1 = frontmost).
    let windowOrder: Int
    /// The window server shows it on a desktop: for native tabs, only the visible tab of its group.
    var isOnScreenTab = true
}

enum TerminalAccess: Equatable {
    case unknown, granted, denied, notRunning
}

/// Talks to Terminal.app over AppleScript: reads tab titles/TTYs and brings a given tab to the front.
enum TerminalBridge {
    static let bundleID = "com.apple.Terminal"
    /// Last desktop seen per window id (only touched from the scan queue).
    private static var knownPlacements: [Int: Spaces.Placement] = [:]
    /// Tab position within its window's tab bar, per window id (only touched from the scan queue).
    private static var knownTabIndices: [Int: Int] = [:]
    private static let separator = "\u{1F}"

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static func tabs() -> (tabs: [String: TerminalTab], access: TerminalAccess) {
        // `tell application "Terminal"` would launch Terminal, so check first.
        guard isRunning else { return ([:], .notRunning) }
        // Five bulk Apple Events (one per property across all windows/tabs), then local list
        // walking: much cheaper for Terminal than one event per property per tab.
        let script = """
        tell application "Terminal"
            set wids to id of every window
            set wbounds to bounds of every window
            set ttys to tty of every tab of every window
            set sels to selected of every tab of every window
            set titles to custom title of every tab of every window
            set wnames to name of every window
        end tell
        set sep to (character id 31)
        set out to ""
        repeat with i from 1 to count of wids
            set tl to item i of ttys
            set b to item i of wbounds
            if class of tl is list and class of b is list then
                set frameText to ((item 1 of b) as text) & "," & ((item 2 of b) as text) & "," & ((item 3 of b) as text) & "," & ((item 4 of b) as text)
                repeat with j from 1 to count of tl
                    set out to out & ((item i of wids) as text) & sep & j & sep & (item j of tl) & sep & ((item j of (item i of sels)) as text) & sep & i & sep & frameText & sep & (item i of wnames) & sep & (item j of (item i of titles)) & linefeed
                end repeat
            end if
        end repeat
        return out
        """
        let result = runAppleScript(script)
        if result.status != 0 {
            return ([:], result.error.contains("-1743") ? .denied : .unknown)
        }
        var tabs: [String: TerminalTab] = [:]
        var windowNames: [Int: String] = [:]
        for line in result.output.split(separator: "\n") {
            let parts = line.components(separatedBy: separator)
            guard parts.count >= 8, let windowID = Int(parts[0]), let order = Int(parts[4]), let tabIndex = Int(parts[1])
            else { continue }
            windowNames[windowID] = parts[6]
            let tty = parts[2].replacingOccurrences(of: "/dev/", with: "")
            let title = parts[7...].joined(separator: separator)
            let edges = parts[5].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            let position = edges.count == 4
                ? ScreenPosition(frame: CGRect(x: edges[0], y: edges[1], width: edges[2] - edges[0], height: edges[3] - edges[1]),
                                 tabIndex: tabIndex)
                : nil
            tabs[tty] = TerminalTab(windowID: windowID, title: title, position: position, isSelected: parts[3] == "true", windowOrder: order)
        }
        // Which desktop each window is on (private API, may be unavailable: then positions stay desktop-less).
        // macOS briefly reports no desktop for a window during animations and full-screen transitions;
        // keep its last known desktop so the list order doesn't jump around.
        let windowIDs = Set(tabs.values.map(\.windowID))
        let live = Spaces.placements(forWindowIDs: Array(windowIDs))
        // Hidden native tabs have no desktop of their own: they take their visible sibling's.
        var frames: [Int: CGRect] = [:]
        for tab in tabs.values { if let frame = tab.position?.frame { frames[tab.windowID] = frame } }
        var placements = TabGroups.inheritDesktops(frames: frames, placed: live)
        for id in windowIDs where placements[id] == nil { placements[id] = knownPlacements[id] }
        knownPlacements = placements.filter { windowIDs.contains($0.key) }
        // Native tabs: their visual order, read from the tab bars (needs Accessibility; windows on other
        // desktops may not be readable right now, so the last known position is kept).
        if TabOrder.isTrusted {
            let fresh = TabGroups.tabIndices(windowNames: windowNames, tabBars: TabOrder.tabBars())
            knownTabIndices.merge(fresh) { $1 }
        }
        knownTabIndices = knownTabIndices.filter { windowIDs.contains($0.key) }
        for (tty, tab) in tabs {
            guard var position = tab.position, let placement = placements[tab.windowID] else { continue }
            if let index = knownTabIndices[tab.windowID] { position = position.withTabIndex(index) }
            position.desktop = placement.desktop
            position.fullscreen = placement.fullscreen
            tabs[tty] = TerminalTab(windowID: tab.windowID, title: tab.title, position: position,
                                    isSelected: tab.isSelected, windowOrder: tab.windowOrder,
                                    isOnScreenTab: live[tab.windowID] != nil)
        }
        return (tabs, .granted)
    }

    /// Visible text of the tabs on `ttys` (Claude's footer shows background shells/agents there).
    static func screens(for ttys: Set<String>) -> [String: String] {
        guard isRunning, !ttys.isEmpty else { return [:] }
        let list = ttys.map { "\"/dev/\($0)\"" }.joined(separator: ", ")
        let script = """
        set wanted to {\(list)}
        set out to ""
        tell application "Terminal"
            repeat with w in windows
                try
                    -- Address tabs by index: `contents of t` on a loop variable is AppleScript's own
                    -- dereference operator, not Terminal's screen-text property.
                    repeat with ti from 1 to (count of tabs of w)
                        set ttyName to (tty of tab ti of w) as text
                        if wanted contains ttyName then
                            set out to out & ttyName & (character id 29) & ((contents of tab ti of w) as text) & (character id 30)
                        end if
                    end repeat
                end try
            end repeat
        end tell
        return out
        """
        let result = runAppleScript(script)
        guard result.status == 0 else { return [:] }
        var screens: [String: String] = [:]
        for record in result.output.split(separator: "\u{1E}") {
            let parts = record.split(separator: "\u{1D}", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let tty = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/dev/", with: "")
            screens[tty] = String(parts[1])
        }
        return screens
    }

    static var app: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    /// Selects the tab running on `tty` and makes its window Terminal's front window. The script's own
    /// `activate` only works when the caller is frontmost (e.g. from a shell); from the menu bar app,
    /// call `HostApp.bringToFrontAndWait` first, because macOS ignores activation from background apps.
    @discardableResult
    static func focus(tty: String) -> Bool {
        guard isRunning else { return false }
        // Windows are addressed by id, not position: activating Terminal reorders its windows, so a
        // positional reference ("window 16") can end up pointing at a neighbour. The final check
        // re-raises once if something else still ended up in front.
        let script = """
        set target to "/dev/\(tty)"
        tell application "Terminal"
            set targetWindow to missing value
            set targetTab to 0
            repeat with w in windows
                try
                    set k to 0
                    repeat with t in tabs of w
                        set k to k + 1
                        if (tty of t) is target then
                            set targetWindow to id of w
                            set targetTab to k
                            exit repeat
                        end if
                    end repeat
                end try
                if targetWindow is not missing value then exit repeat
            end repeat
            if targetWindow is missing value then return "missing"
            set w to window id targetWindow
            try
                set miniaturized of w to false
            end try
            set selected tab of w to tab targetTab of w
            set index of w to 1
            activate
            delay 0.05
            if (tty of selected tab of front window) is target then return "ok"
            -- Windows tiled side by side (macOS window tiling) keep their partner on top of
            -- `set index`; hiding and re-showing the window does reorder it.
            set visible of w to false
            set visible of w to true
            set index of w to 1
            activate
            delay 0.05
            if (tty of selected tab of front window) is target then return "ok"
            return "ok-unverified"
        end tell
        """
        let result = runAppleScript(script)
        return result.status == 0 && result.output.hasPrefix("ok")
    }

    /// Runs AppleScript through `osascript` so it is safe to call off the main thread.
    /// The Automation permission is still attributed to VibeSwitcher (the responsible process).
    static func runAppleScript(_ source: String, timeout: TimeInterval = 4) -> (output: String, error: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return ("", "\(error)", -1) }
        // Read while the script runs: waiting for exit first deadlocks once the output fills the
        // 64 KB pipe buffer (screen contents of several tabs easily do). A watchdog enforces the timeout.
        var timedOut = false
        let watchdog = DispatchWorkItem {
            timedOut = true
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        var errorData = Data()
        let errorRead = DispatchGroup()
        errorRead.enter()
        DispatchQueue.global().async {
            errorData = err.fileHandleForReading.readDataToEndOfFile()
            errorRead.leave()
        }
        let outputData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        errorRead.wait()
        watchdog.cancel()
        if timedOut { return ("", "timeout", -2) }
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""
        return (output, error, process.terminationStatus)
    }
}

/// Brings another app to the front from VibeSwitcher.
///
/// macOS 14+ ignores activation requests from a background app (which a menu bar app nearly always is),
/// including AppleScript's `activate`. Opening the app through Launch Services counts as user intent and
/// is honored, so that is the reliable path; yielding our own activation first helps when we are active.
enum HostApp {
    static func bringToFront(_ app: NSRunningApplication) {
        NSApp.yieldActivation(to: app)
        app.activate(from: NSRunningApplication.current, options: [])
        guard let url = app.bundleURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Off the main thread: activates `app` and waits (up to `timeout`) until it is really frontmost,
    /// retrying the Launch Services open once if the first request was swallowed.
    static func bringToFrontAndWait(_ app: NSRunningApplication, timeout: TimeInterval = 1.5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var retried = false
        DispatchQueue.main.sync { bringToFront(app) }
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return true }
            if !retried, deadline.timeIntervalSinceNow < timeout / 2 {
                retried = true
                DispatchQueue.main.sync { bringToFront(app) }
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        return false
    }

    /// For sessions that are not in Terminal.app (iTerm, VS Code, …): activate whichever GUI app hosts them.
    static func activate(forPID pid: Int32) -> Bool {
        var current = pid
        for _ in 0..<32 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                bringToFront(app)
                return true
            }
            guard let parent = ProcessTable.info(pid: current)?.ppid, parent > 1 else { return false }
            current = parent
        }
        return false
    }
}
