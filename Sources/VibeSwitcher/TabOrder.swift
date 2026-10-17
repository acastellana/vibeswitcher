import ApplicationServices
import AppKit
import VibeCore

/// The visual order of Terminal's native tabs. Terminal's scripting dictionary doesn't expose it (each
/// tab looks like its own window), but the tab bar is visible through the Accessibility API, which
/// needs the user's permission (System Settings › Privacy & Security › Accessibility).
enum TabOrder {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Registers the app for the Accessibility permission and opens that settings page. (The system
    /// prompt alone doesn't always add the app to the list, so the page is opened either way.)
    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// For each Terminal window with a tab bar, its tab titles from left to right. Off the main thread: each call
    /// waits on Terminal, up to half a second.
    static func tabBars() -> [[String]] {
        guard isTrusted, let terminal = TerminalBridge.app else { return [] }
        let app = AXUIElementCreateApplication(terminal.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var bars: [[String]] = []
        for window in children(of: app, attribute: kAXWindowsAttribute) {
            // The timeout is per element: one set on the app alone leaves its windows at the default (about 6 s).
            AXUIElementSetMessagingTimeout(window, 0.5)
            guard let tabGroup = children(of: window, attribute: kAXChildrenAttribute)
                .first(where: { role(of: $0) == kAXTabGroupRole }) else { continue }
            AXUIElementSetMessagingTimeout(tabGroup, 0.5)
            let titles = children(of: tabGroup, attribute: kAXTabsAttribute).compactMap(title(of:))
            let fallback = children(of: tabGroup, attribute: kAXChildrenAttribute)
                .filter { role(of: $0) == kAXRadioButtonRole }.compactMap(title(of:))
            let bar = titles.isEmpty ? fallback : titles
            if bar.count > 1 { bars.append(bar) }
        }
        return bars
    }

    private static func children(of element: AXUIElement, attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return value as? String
    }

    private static func title(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        return value as? String
    }
}
