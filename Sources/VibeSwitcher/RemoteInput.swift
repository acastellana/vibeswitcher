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

    enum Failure: Error, Equatable, CustomStringConvertible {
        case locked, noAccessibility, notInTerminal, focusFailed, invalidText, sessionChanged, notAllowed
        /// Another tab or app came to the front while typing. `typed`: part of the text is in the session's
        /// box (not sent).
        case focusMoved(typed: Bool)

        var description: String {
            switch self {
            case .locked: return "The Mac is locked."
            case .noAccessibility: return "VibeSwitcher needs Accessibility permission to type."
            case .notInTerminal: return "This session isn't in a Terminal tab."
            case .focusFailed: return "Couldn't bring that tab to the front on the Mac."
            case .invalidText: return "Text is empty or too long."
            case .sessionChanged: return "That session ended or another one took its tab. Nothing was typed."
            case .notAllowed: return "Not sent: this phone was unpaired or replies were turned off."
            case .focusMoved(let typed):
                return typed ? "Another tab came to the front on the Mac while typing, so it stopped. Part of the message is in the session's box, not sent."
                             : "Another tab came to the front on the Mac, so nothing was typed."
            }
        }
    }

    /// Held while VibeSwitcher brings a tab to the front or types into it: a jump from the menu bar
    /// must not move the focus in the middle of a reply from the phone.
    static let focusLock = NSLock()

    static let maxTextLength = 2000

    /// Plain single-line text: control characters would let a message smuggle in key presses.
    static func sanitized(_ text: String) -> String? {
        let flat = String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
        guard !flat.trimmingCharacters(in: .whitespaces).isEmpty, flat.count <= maxTextLength else { return nil }
        return flat
    }

    /// Runs off the main thread (AppleScript and short pauses between key events). `agent` is the session's
    /// agent process: if it isn't running on `tty` any more, the tab holds something else and nothing is typed.
    /// `stillAllowed` runs once any jump in progress is over, right before anything happens (pairing, the
    /// replies switch and the session can change while waiting).
    static func send(tty: String, agent: (pid: Int32, startedAt: Date), text: String?, submit: Bool, key: Key?,
                     stillAllowed: () -> Bool) -> Failure? {
        if isScreenLocked { return .locked }
        guard AXIsProcessTrusted() else { return .noAccessibility }
        guard TerminalBridge.isValidTTY(tty), let terminal = TerminalBridge.app else { return .notInTerminal }
        var cleanText: String?
        if let text {
            guard let clean = sanitized(text) else { return .invalidText }
            cleanText = clean
        }
        focusLock.lock()
        defer { focusLock.unlock() }
        guard stillAllowed() else { return .notAllowed }
        guard SessionIdentity.isRunning(pid: agent.pid, startedAt: agent.startedAt),
              ProcessTable.info(pid: agent.pid)?.tty == tty else { return .sessionChanged }
        let active = HostApp.bringToFrontAndWait(terminal)
        let focus = TerminalBridge.focusReport(tty: tty, strict: true)
        let front = focus.ok ? TerminalBridge.frontTTY() : nil
        // The tab's own window (each Terminal tab is a window of its own): if another one comes in front, stop.
        guard focus.ok, front == tty, let window = focus.windowID ?? frontWindowNumber(of: terminal.processIdentifier) else {
            FocusLog.record(tty: tty, source: "phone", steps: [
                "activate Terminal: \(active ? "ok" : "timed out")", "select tab: \(focus.detail)",
                "front tab before typing: \(front ?? "?")"])
            return .focusFailed
        }
        let pid = terminal.processIdentifier
        var finish: [() -> Void] = []
        if cleanText != nil, submit { finish.append { post(key: .enter, to: pid) } }
        if let key { finish.append { post(key: key, to: pid) } }
        let outcome = GuardedTyping.run(
            chunks: GuardedTyping.chunks(cleanText ?? ""), finish: finish,
            // Cheap, before every chunk: Terminal still frontmost with the same window in front.
            stillFocused: { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid && frontWindowNumber(of: pid) == window },
            // Full: the selected tab of the front window is still this session's.
            stillFrontTab: { TerminalBridge.frontTTY() == tty },
            clock: { ProcessInfo.processInfo.systemUptime }, fullCheckEvery: 0.4,
            post: { post(chunk: $0, to: pid) }, pause: { usleep(useconds_t($0 * 1_000_000)) })
        guard case .stopped(let typed) = outcome else { return nil }
        FocusLog.record(tty: tty, source: "phone", steps: ["focus moved while typing", typed ? "stopped after some text" : "nothing typed"])
        return .focusMoved(typed: typed)
    }

    /// The window number of `pid`'s frontmost real window (the one keystrokes go to). Skips the thin title-bar
    /// strips and small helper windows full-screen Terminal windows come with.
    private static func frontWindowNumber(of pid: pid_t) -> Int? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for window in windows {
            let owner = window[kCGWindowOwnerPID as String] as? Int32
            let layer = window[kCGWindowLayer as String] as? Int
            let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
            let bounds = (window[kCGWindowBounds as String] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            guard owner == pid, layer == 0, alpha > 0, let bounds, bounds.height >= 200, bounds.width >= 200 else { continue }
            return window[kCGWindowNumber as String] as? Int
        }
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

    private static func post(chunk: [UInt16], to pid: pid_t) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            event.postToPid(pid)
        }
    }
}
