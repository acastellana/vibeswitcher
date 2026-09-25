import AppKit
import Foundation
import VibeCore

struct TerminalTab: Equatable {
    let windowID: Int
    let tabIndex: Int
    let tty: String          // "ttys009"
    let title: String
    let isSelected: Bool
    /// Position of the window in Terminal's front-to-back order (1 = frontmost).
    let windowOrder: Int
}

enum TerminalAccess: Equatable {
    case unknown, granted, denied, notRunning
}

/// Talks to Terminal.app over AppleScript: reads tab titles/TTYs and brings a given tab to the front.
enum TerminalBridge {
    static let bundleID = "com.apple.Terminal"
    private static let separator = "\u{1F}"

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static func tabs() -> (tabs: [String: TerminalTab], access: TerminalAccess) {
        // `tell application "Terminal"` would launch Terminal, so check first.
        guard isRunning else { return ([:], .notRunning) }
        let script = """
        set sep to (character id 31)
        set out to ""
        tell application "Terminal"
            set wi to 0
            repeat with w in windows
                set wi to wi + 1
                try
                    set wid to (id of w) as text
                    set ti to 0
                    repeat with t in tabs of w
                        set ti to ti + 1
                        set out to out & wid & sep & ti & sep & (tty of t) & sep & ((selected of t) as text) & sep & wi & sep & (custom title of t) & linefeed
                    end repeat
                end try
            end repeat
        end tell
        return out
        """
        let result = runAppleScript(script)
        if result.status != 0 {
            return ([:], result.error.contains("-1743") ? .denied : .unknown)
        }
        var tabs: [String: TerminalTab] = [:]
        for line in result.output.split(separator: "\n") {
            let parts = line.components(separatedBy: separator)
            guard parts.count >= 6, let wid = Int(parts[0]), let ti = Int(parts[1]), let order = Int(parts[4]) else { continue }
            let tty = parts[2].replacingOccurrences(of: "/dev/", with: "")
            let title = parts[5...].joined(separator: separator)
            tabs[tty] = TerminalTab(windowID: wid, tabIndex: ti, tty: tty, title: title,
                                    isSelected: parts[3] == "true", windowOrder: order)
        }
        return (tabs, .granted)
    }

    static var app: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    /// Selects the tab running on `tty` and makes its window Terminal's front window. Activating Terminal
    /// is left to the caller (`HostApp.bringToFront`), because AppleScript's `activate` is ignored when
    /// sent from a background app.
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
        let deadline = DispatchTime.now() + timeout
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        if done.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return ("", "timeout", -2)
        }
        let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
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
