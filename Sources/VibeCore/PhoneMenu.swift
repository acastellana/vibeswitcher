import CryptoKit
import Foundation

/// The question, permission prompt or picker on a session's screen, for the phone: read off the screen as the window's
/// chat reads it (`ScreenMenu`), credentials masked, sent with `/api/state` as option buttons, and answered with one
/// tap. A tap carries the fingerprint of the menu it was drawn from; the screen is read again before anything is typed,
/// and a tap on a menu that changed or went away is refused, never typed into whatever is there now.
public enum PhoneMenu {
    /// How far up from the bottom of the screen a menu is looked for (the chat's window looks as far).
    static let bottomLines = 40

    /// The menu waiting on you on `screen` (its raw text): when the hooks say it's waiting (`needsInput`) or its
    /// footer says how to choose. Masked before it's parsed, so no part of it carries a credential.
    public static func detect(screen: String, needsInput: Bool) -> ScreenMenu? {
        var lines = Redaction.secrets(in: screen).components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        let bottom = Array(lines.suffix(bottomLines))
        let asking = needsInput
            || bottom.suffix(6).contains { $0.contains("Enter to select") || $0.contains("Esc to cancel") || $0.contains("to navigate") }
        return asking ? ScreenMenu.parse(bottom) : nil
    }

    /// Stands for this question in this session: its text, options and their lines, tabs and Submit row, not where
    /// the cursor is or what's ticked (the keys are worked out from the screen as it is when the tap arrives).
    public static func fingerprint(_ menu: ScreenMenu, sid: String) -> String {
        let parts: [String] = [sid, menu.question, menu.options.joined(separator: "\u{1F}"),
                               menu.descriptions.map { $0 ?? "\u{18}" }.joined(separator: "\u{1F}"),
                               menu.tabs.map(\.title).joined(separator: "\u{1F}"), menu.currentTab.map(String.init) ?? "-",
                               menu.submit ?? "-", menu.multiSelect ? "multi" : "single"]
        return Base64URL.encode(Data(SHA256.hash(data: Data(parts.joined(separator: "\u{1E}").utf8))).prefix(12))
    }

    /// What `/api/state` carries for the session: `menu` from `detect` (already masked).
    public static func json(_ menu: ScreenMenu, sid: String) -> [String: Any] {
        var object: [String: Any] = [
            "question": menu.question, "options": menu.options,
            "descriptions": menu.descriptions.map { $0.map { $0 as Any } ?? NSNull() },
            "selected": menu.selected, "fingerprint": fingerprint(menu, sid: sid),
        ]
        if let checked = menu.checked { object["checked"] = checked }
        if let submit = menu.submit { object["submit"] = submit }
        return object
    }

    public enum Answer: Equatable {
        /// The keys to type: arrows from where the cursor is now, then Enter.
        case keys([HostInput.Write], label: String)
        /// The menu the tap was meant for isn't on the screen any more (another one is, or none).
        case stale
        /// No such option.
        case invalid
    }

    /// The tap on option `index` of the menu with `fingerprint`, against the screen read again right now.
    public static func answer(choose index: Int, fingerprint: String, screen: String, needsInput: Bool, sid: String) -> Answer {
        guard let menu = detect(screen: screen, needsInput: needsInput), Self.fingerprint(menu, sid: sid) == fingerprint else {
            return .stale
        }
        // A multi-select's Submit / Next row sits under its options.
        let last = menu.submit == nil ? menu.options.count - 1 : menu.options.count
        guard (0...last).contains(index) else { return .invalid }
        return .keys(menu.keys(toChoose: index), label: menu.options.indices.contains(index) ? menu.options[index] : menu.submit ?? "")
    }
}
