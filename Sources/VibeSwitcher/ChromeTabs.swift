import AppKit
import ScriptingBridge
import VibeCore

/// The localhost pages open in Google Chrome. Only while Chrome is running: this never launches it.
/// The first read shows macOS's "control Google Chrome" prompt.
///
/// Addressed by process, not by bundle id: browser-automation tools leave background copies of Chrome
/// running (same bundle id, no windows), and an Apple Event sent "to com.google.Chrome" can land in
/// one of those and never be answered.
enum ChromeTabs {
    static let bundleID = "com.google.Chrome"

    enum Failure: Error, Equatable {
        case notRunning
        case notAllowed
        case failed(String)
    }

    /// The Chrome you use: a regular (Dock) app, not a background-only automation copy.
    static var userChrome: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .min { ($0.launchDate ?? .distantFuture) < ($1.launchDate ?? .distantFuture) }
    }

    /// Records the error of the last Apple Event Scripting Bridge sent (it returns nil, not an error).
    private final class ErrorCatcher: NSObject, SBApplicationDelegate {
        var code: Int?
        func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: Error) -> Any? {
            code = (error as NSError).code
            return nil
        }
    }

    static func localPages() -> Result<[DevPage], Failure> {
        guard let chrome = userChrome else { return .failure(.notRunning) }
        guard let app = SBApplication(processIdentifier: chrome.processIdentifier) else {
            return .failure(.failed("couldn't address Chrome"))
        }
        let catcher = ErrorCatcher()
        app.delegate = catcher
        app.timeout = 8 * 60   // ticks (1/60 s)
        // Two requests per window (every tab's URL, every tab's title), however many tabs there are.
        var tabs: [(url: String, title: String)] = []
        let windows = app.value(forKey: "windows") as? SBElementArray ?? SBElementArray()
        for case let window as SBObject in windows {
            guard let windowTabs = window.value(forKey: "tabs") as? SBElementArray else { continue }
            let urls = windowTabs.value(forKey: "URL") as? [Any] ?? []
            let titles = windowTabs.value(forKey: "title") as? [Any] ?? []
            for (index, url) in urls.enumerated() {
                guard let url = url as? String else { continue }
                tabs.append((url, index < titles.count ? (titles[index] as? String ?? "") : ""))
            }
        }
        guard let code = catcher.code else { return .success(DevPages.pages(fromTabs: tabs)) }
        switch code {
        case -1743: return .failure(.notAllowed)                 // errAEEventNotPermitted
        case -1712: return .failure(.failed("timeout"))
        default: return .failure(.failed("Apple Event error \(code)"))
        }
    }
}

extension ChromeTabs {
    /// Whether VibeSwitcher may read Chrome's tabs. With `ask`, macOS shows its "control Google Chrome"
    /// dialog if it hasn't been answered yet. That blocks until the user answers: call it off the main thread.
    static func access(ask: Bool) -> AutomationAccess {
        guard let chrome = userChrome else { return .appNotRunning }
        var pid = chrome.processIdentifier
        var target = AEAddressDesc()
        let created = AECreateDesc(DescType(typeKernelProcessID), &pid, MemoryLayout<pid_t>.size, &target)
        guard created == noErr else { return .unknown(Int32(created)) }
        defer { AEDisposeDesc(&target) }
        // The event reading a tab's URL sends: "get data" of the core suite.
        let status = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(kCoreEventClass), AEEventID(kAEGetData), ask)
        return AutomationAccess(status: status)
    }

    /// Privacy & Security › Automation, where the answer can be changed later.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
}
