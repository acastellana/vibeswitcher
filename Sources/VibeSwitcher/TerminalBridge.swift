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
        -- Eight strings per tab, returned as a quoted list (osascript -s s): a title can contain any
        -- character, and inside quotes it can't pass for another tab's fields.
        set out to {}
        repeat with i from 1 to count of wids
            set tl to item i of ttys
            set b to item i of wbounds
            if class of tl is list and class of b is list then
                set frameText to ((item 1 of b) as text) & "," & ((item 2 of b) as text) & "," & ((item 3 of b) as text) & "," & ((item 4 of b) as text)
                repeat with j from 1 to count of tl
                    set end of out to ((item i of wids) as text)
                    set end of out to (j as text)
                    set end of out to ((item j of tl) as text)
                    set end of out to ((item j of (item i of sels)) as text)
                    set end of out to (i as text)
                    set end of out to frameText
                    set end of out to ((item i of wnames) as text)
                    set end of out to ((item j of (item i of titles)) as text)
                end repeat
            end if
        end repeat
        return out
        """
        let result = runAppleScript(script, sourceForm: true)
        if result.status != 0 {
            return ([:], result.error.contains("-1743") ? .denied : .unknown)
        }
        guard let fields = AppleScriptStrings.parse(result.output), let records = TerminalTabRecords.parse(fields) else {
            return ([:], .unknown)
        }
        var tabs: [String: TerminalTab] = [:]
        var windowNames: [Int: String] = [:]
        for record in records {
            windowNames[record.windowID] = record.windowName
            let edges = record.bounds.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            let position = edges.count == 4
                ? ScreenPosition(frame: CGRect(x: edges[0], y: edges[1], width: edges[2] - edges[0], height: edges[3] - edges[1]),
                                 tabIndex: record.tabIndex)
                : nil
            tabs[record.tty] = TerminalTab(windowID: record.windowID, title: record.title, position: position,
                                           isSelected: record.isSelected, windowOrder: record.windowOrder)
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
        let ttys = ttys.filter(isValidTTY)
        guard isRunning, !ttys.isEmpty else { return [:] }
        let list = ttys.map { "\"/dev/\($0)\"" }.joined(separator: ", ")
        let script = """
        set wanted to {\(list)}
        set out to {}
        tell application "Terminal"
            repeat with w in windows
                try
                    -- Address tabs by index: `contents of t` on a loop variable is AppleScript's own
                    -- dereference operator, not Terminal's screen-text property.
                    repeat with ti from 1 to (count of tabs of w)
                        set ttyName to (tty of tab ti of w) as text
                        if wanted contains ttyName then
                            set end of out to ttyName
                            set end of out to ((contents of tab ti of w) as text)
                        end if
                    end repeat
                end try
            end repeat
        end tell
        return out
        """
        // Quoted list of (tty, screen) pairs: screen text can't forge another tab's entry.
        let result = runAppleScript(script, sourceForm: true)
        guard result.status == 0, let fields = AppleScriptStrings.parse(result.output), fields.count % 2 == 0 else { return [:] }
        var screens: [String: String] = [:]
        for index in stride(from: 0, to: fields.count, by: 2) {
            let tty = fields[index].replacingOccurrences(of: "/dev/", with: "")
            guard ttys.contains(tty), screens[tty] == nil else { continue }
            screens[tty] = fields[index + 1]
        }
        return screens
    }

    /// A tab's whole scrollback and its visible screen, in one read (for the phone's Terminal tab).
    static func history(tty: String) -> (history: String, screen: String)? {
        guard isRunning, isValidTTY(tty) else { return nil }
        let result = runAppleScript("""
        set target to "/dev/\(tty)"
        tell application "Terminal"
            repeat with w in windows
                try
                    repeat with ti from 1 to (count of tabs of w)
                        if ((tty of tab ti of w) as text) is target then
                            return {((history of tab ti of w) as text), ((contents of tab ti of w) as text)}
                        end if
                    end repeat
                end try
            end repeat
        end tell
        return {}
        """, timeout: 8, sourceForm: true)
        guard result.status == 0, let parts = AppleScriptStrings.parse(result.output), parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    static var app: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    /// Selects the tab running on `tty` and makes its window Terminal's front window. The script's own
    /// `activate` only works when the caller is frontmost (e.g. from a shell); from the menu bar app,
    /// call `HostApp.bringToFrontAndWait` first, because macOS ignores activation from background apps.
    /// `strict`: never use the hide/re-show fallback (it can strand windows across desktops) and only
    /// report success when the tab is verified to be in front, as typing into it requires.
    @discardableResult
    static func focus(tty: String, strict: Bool = false) -> Bool {
        focusReport(tty: tty, strict: strict).ok
    }

    /// `focus`, plus what happened, for the focus log: the script's verdict ("ok", "missing", …),
    /// whether the window was minimized, and which tab was in front when it wasn't the target.
    /// `onCurrentDesktop`: the tab's window is on the desktop being shown (unknown counts as no). Only then is the check quick and
    /// the re-show fallback allowed; otherwise it waits up to 1.5 s for macOS to switch desktops.
    static func focusReport(tty: String, strict: Bool = false, onCurrentDesktop: Bool = false) -> (ok: Bool, detail: String, windowID: Int?) {
        guard isRunning else { return (false, "terminal not running", nil) }
        guard isValidTTY(tty) else { return (false, "invalid tty", nil) }
        // A tab on another desktop (or an unknown one) gets time for the desktop switch and no re-show.
        let plan = FocusPlan.make(onCurrentDesktop: onCurrentDesktop, strict: strict)
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
            set extra to ""
            try
                if miniaturized of w then set extra to " minimized"
                set miniaturized of w to false
            end try
            set selected tab of w to tab targetTab of w
            set index of w to 1
            activate
            set checked to 0
            repeat \(plan.checks) times
                delay \(plan.interval)
                set checked to checked + 1
                try
                    if (tty of selected tab of front window) is target then
                        if checked > 1 then set extra to extra & " after " & checked & " checks"
                        return "ok" & extra & " window=" & targetWindow
                    end if
                end try
            end repeat
            try
                set extra to extra & " front=" & (tty of selected tab of front window)
            end try
            if \(strict) then return "unverified" & extra
            if not \(plan.mayReshow) then return "ok-unverified" & extra
            -- Windows tiled side by side (macOS window tiling) keep their partner on top of
            -- `set index`; hiding and re-showing the window does reorder it.
            set visible of w to false
            set visible of w to true
            set index of w to 1
            activate
            delay 0.05
            if (tty of selected tab of front window) is target then return "ok-after-reshow" & extra
            return "ok-unverified" & extra
        end tell
        """
        let start = Date()
        let result = runAppleScript(script, timeout: 4 + plan.waitLimit)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let verdict = output.split(separator: " ").first.map(String.init) ?? ""
        let ok = result.status == 0 && (strict ? verdict == "ok" : verdict.hasPrefix("ok"))
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        let detail = result.status == 0
            ? "\(output.replacingOccurrences(of: "/dev/", with: "")) (\(elapsed) ms)"
            : "script error \(result.status): \(result.error.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)) (\(elapsed) ms)"
        // The tab's window id (Terminal's AppleScript window id is the window server's number for it).
        let windowID = output.range(of: #"window=([0-9]+)"#, options: .regularExpression)
            .flatMap { Int(output[$0].dropFirst("window=".count)) }
        return (ok, detail, windowID)
    }

    /// Minimizes the window running `tty` if that session is its only tab (minimizing a shared window
    /// would hide the other tabs too). Returns the window id when it did.
    static func minimizeIfAlone(tty: String) -> Int? {
        guard isRunning, isValidTTY(tty) else { return nil }
        let result = runAppleScript("""
        tell application "Terminal"
            repeat with w in windows
                try
                    if (count of tabs of w) is 1 and ((tty of tab 1 of w) as text) is "/dev/\(tty)" then
                        set miniaturized of w to true
                        return (id of w) as text
                    end if
                end try
            end repeat
        end tell
        return ""
        """)
        return Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Brings back a window minimized by `minimizeIfAlone` (if it still exists and is still minimized).
    static func unminimize(windowID: Int) {
        guard isRunning else { return }
        _ = runAppleScript("""
        tell application "Terminal"
            try
                if miniaturized of window id \(windowID) then set miniaturized of window id \(windowID) to false
            end try
        end tell
        """)
    }

    /// The tty of the tab in Terminal's front window, e.g. "ttys011".
    static func frontTTY() -> String? {
        let result = runAppleScript(#"tell application "Terminal" to return (tty of selected tab of front window) as text"#)
        guard result.status == 0 else { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/dev/", with: "")
    }

    /// TTY names are interpolated into AppleScript; accept only the shape macOS uses.
    static func isValidTTY(_ tty: String) -> Bool {
        tty.range(of: #"^ttys[0-9]{1,4}$"#, options: .regularExpression) != nil
    }

    /// Runs AppleScript through `osascript` so it is safe to call off the main thread.
    /// The Automation permission is still attributed to VibeSwitcher (the responsible process).
    /// `sourceForm`: print the result as AppleScript source (`-s s`), so strings come back quoted (see `AppleScriptStrings`).
    static func runAppleScript(_ source: String, timeout: TimeInterval = 4, sourceForm: Bool = false) -> (output: String, error: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = (sourceForm ? ["-s", "s"] : []) + ["-e", source]
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
