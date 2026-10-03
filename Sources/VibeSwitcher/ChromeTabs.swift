import AppKit
import VibeCore

/// The localhost pages open in Google Chrome, read with AppleScript. Only while Chrome is running:
/// this never launches it. The first read shows macOS's "control Google Chrome" prompt.
enum ChromeTabs {
    static let bundleID = "com.google.Chrome"

    enum Failure: Error, Equatable {
        case notRunning
        case notAllowed
        case failed(String)
    }

    static func localPages() -> Result<[DevPage], Failure> {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
            return .failure(.notRunning)
        }
        let result = TerminalBridge.runAppleScript("""
        set out to ""
        tell application id "\(bundleID)"
            repeat with w in windows
                repeat with t in tabs of w
                    set out to out & (URL of t) & (character id 31) & (title of t) & (character id 30)
                end repeat
            end repeat
        end tell
        return out
        """)
        guard result.status == 0 else {
            // -1743: the user said no (or hasn't been asked yet) under Privacy & Security › Automation.
            if result.error.contains("-1743") { return .failure(.notAllowed) }
            return .failure(.failed(String(result.error.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))))
        }
        let tabs: [(url: String, title: String)] = result.output.split(separator: "\u{1E}").compactMap { record in
            let parts = record.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines), String(parts[1]))
        }
        return .success(DevPages.pages(fromTabs: tabs))
    }
}

extension ChromeTabs {
    /// Whether VibeSwitcher may read Chrome's tabs. With `ask`, macOS shows its "control Google Chrome"
    /// dialog if it hasn't been answered yet. That blocks until the user answers: call it off the main thread.
    static func access(ask: Bool) -> AutomationAccess {
        var target = AEAddressDesc()
        let created = bundleID.withCString { AECreateDesc(DescType(typeApplicationBundleID), $0, strlen($0), &target) }
        guard created == noErr else { return .unknown(Int32(created)) }
        defer { AEDisposeDesc(&target) }
        // The event reading a tab's URL sends: "get data" of the core suite.
        let status = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(kCoreEventClass), AEEventID(kAEGetData), ask)
        return AutomationAccess(status: status)
    }

    /// Privacy & Security › Automation, where the answer can be changed later.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
}
