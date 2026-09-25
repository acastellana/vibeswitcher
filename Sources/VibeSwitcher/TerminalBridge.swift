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

    /// Selects the tab running on `tty`, un-minimizes and raises its window, and activates Terminal.
    @discardableResult
    static func focus(tty: String) -> Bool {
        guard isRunning else { return false }
        let script = """
        tell application "Terminal"
            repeat with w in windows
                try
                    repeat with t in tabs of w
                        if (tty of t) is "/dev/\(tty)" then
                            try
                                set miniaturized of w to false
                            end try
                            set selected tab of w to t
                            set index of w to 1
                            try
                                set frontmost of w to true
                            end try
                            activate
                            return "ok"
                        end if
                    end repeat
                end try
            end repeat
        end tell
        return "missing"
        """
        let result = runAppleScript(script)
        return result.status == 0 && result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
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

/// For sessions that are not in Terminal.app (iTerm, VS Code, …): activate whichever GUI app hosts them.
enum HostApp {
    static func activate(forPID pid: Int32) -> Bool {
        var current = pid
        for _ in 0..<32 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return app.activate()
            }
            guard let parent = ProcessTable.info(pid: current)?.ppid, parent > 1 else { return false }
            current = parent
        }
        return false
    }
}
