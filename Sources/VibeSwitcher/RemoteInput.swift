import AppKit
import CoreGraphics
import VibeCore

/// Types into a session's Terminal tab on behalf of the paired phone.
///
/// Terminal has no scripting call for key presses (`do script` appends a newline that TUIs like
/// Claude Code treat as part of a paste), so the tab is brought to the front and verified, then key
/// events are posted to Terminal's process only (not system-wide) so nothing can land in another app.
enum RemoteInput {
    enum Key: String, CaseIterable {
        case enter, escape, up, down, left, right, tab, backspace
        case interrupt   // ⌃C

        var code: CGKeyCode {
            switch self {
            case .enter: return 36
            case .escape: return 53
            case .up: return 126
            case .down: return 125
            case .left: return 123
            case .right: return 124
            case .tab: return 48
            case .backspace: return 51
            case .interrupt: return 8   // "c"
            }
        }

        var flags: CGEventFlags { self == .interrupt ? .maskControl : [] }
    }

    enum Failure: Error, CustomStringConvertible {
        case locked, noAccessibility, notInTerminal, focusFailed, invalidText

        var description: String {
            switch self {
            case .locked: return "The Mac is locked."
            case .noAccessibility: return "VibeSwitcher needs Accessibility permission to type."
            case .notInTerminal: return "This session isn't in a Terminal tab."
            case .focusFailed: return "Couldn't bring that tab to the front on the Mac."
            case .invalidText: return "Text is empty or too long."
            }
        }
    }

    static let maxTextLength = 2000

    /// Plain single-line text: control characters would let a message smuggle in key presses.
    static func sanitized(_ text: String) -> String? {
        let flat = String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
        guard !flat.trimmingCharacters(in: .whitespaces).isEmpty, flat.count <= maxTextLength else { return nil }
        return flat
    }

    /// Runs off the main thread (AppleScript and short pauses between key events).
    static func send(tty: String, text: String?, submit: Bool, key: Key?) -> Failure? {
        if isScreenLocked { return .locked }
        guard AXIsProcessTrusted() else { return .noAccessibility }
        guard TerminalBridge.isValidTTY(tty), let terminal = TerminalBridge.app else { return .notInTerminal }
        var cleanText: String?
        if let text {
            guard let clean = sanitized(text) else { return .invalidText }
            cleanText = clean
        }
        let active = HostApp.bringToFrontAndWait(terminal)
        let focus = TerminalBridge.focusReport(tty: tty, strict: true)
        let front = focus.ok ? TerminalBridge.frontTTY() : nil
        guard focus.ok, front == tty else {
            FocusLog.record(tty: tty, source: "phone", steps: [
                "activate Terminal: \(active ? "ok" : "timed out")", "select tab: \(focus.detail)",
                "front tab before typing: \(front ?? "?")"])
            return .focusFailed
        }
        let pid = terminal.processIdentifier
        if let cleanText {
            post(text: cleanText, to: pid)
            // A separate, slightly later Enter: sent with the text it would count as part of a paste.
            if submit { usleep(120_000); post(key: .enter, to: pid) }
        }
        if let key { post(key: key, to: pid) }
        return nil
    }

    static var isScreenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
    }

    private static let source = CGEventSource(stateID: .hidSystemState)

    private static func post(key: Key, to pid: pid_t) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: down) else { continue }
            event.flags = key.flags
            event.postToPid(pid)
            usleep(8_000)
        }
    }

    private static func post(text: String, to pid: pid_t) {
        let units = Array(text.utf16)
        var start = 0
        while start < units.count {
            var end = min(start + 16, units.count)
            // Don't split a surrogate pair across events.
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            let chunk = Array(units[start..<end])
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event.postToPid(pid)
            }
            usleep(10_000)
            start = end
        }
    }
}
