import CryptoKit
import Foundation

/// The question, permission prompt or picker on a session's screen, for the phone: read off the screen as the window's
/// chat reads it (`ScreenMenu`), credentials masked, sent with `/api/state` as option buttons, and answered with one
/// tap. A tap carries the fingerprint of the menu it was drawn from; the screen is read again before anything is typed,
/// and a tap on a menu that changed or went away is refused, never typed into whatever is there now.
public enum PhoneMenu {
    /// How far up from the bottom of the screen a menu is looked for (the chat's window looks as far).
    static let bottomLines = 40

    /// A menu as read off a screen, with the rest of its dialog above the options: what a tap is checked against.
    public struct Shown: Equatable, Sendable {
        public var menu: ScreenMenu
        /// The dialog's lines above the options, trimmed, blank ones left out: the diff of an edit, a command however
        /// long, the question. Up to the rule its dialog starts under, else the screen's top.
        public var above: [String]

        public init(menu: ScreenMenu, above: [String]) {
            self.menu = menu
            self.above = above
        }
    }

    /// The menu waiting on you on `screen` (its raw text): when the hooks say it's waiting (`needsInput`) or its
    /// footer says how to choose. Masked before it's parsed, so no part of it carries a credential.
    public static func detect(screen: String, needsInput: Bool) -> ScreenMenu? {
        read(screen: screen, needsInput: needsInput)?.menu
    }

    /// `detect`, with the dialog's lines above the options.
    public static func read(screen: String, needsInput: Bool) -> Shown? {
        var lines = Redaction.secrets(in: screen).components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        let bottom = Array(lines.suffix(bottomLines))
        let asking = needsInput
            || bottom.suffix(6).contains { $0.contains("Enter to select") || $0.contains("Esc to cancel") || $0.contains("to navigate") }
        guard asking, let (menu, first) = ScreenMenu.located(bottom) else { return nil }
        // Up from the options to the dialog's top: a rule at the left edge, not one inside a box (`│ ╰───╯ │`, an old
        // edit's diff) or a dashed one (`╌╌╌`, around today's diff or command). What's above it is the conversation,
        // which may still move (a subagent's progress) while the question stays the same.
        var above: [String] = []
        for line in lines[..<(lines.count - bottom.count + first)].reversed() {
            let text = line.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty, text.allSatisfy({ dialogTop.contains($0) || $0 == " " }) { break }
            let clean = text.trimmingCharacters(in: CharacterSet(charactersIn: "│┃║").union(.whitespaces))
            // A tab bar's marks say which questions are answered: the open one is in the fingerprint already.
            if !clean.isEmpty { above.append(String(clean.map { "☐✔☒☑".contains($0) ? "☐" : $0 })) }
        }
        return Shown(menu: menu, above: above.reversed())
    }

    private static let dialogTop: Set<Character> = Set("─━═╭╮╰╯┌┐└┘▔")

    /// Stands for this question in this session: its dialog's lines above the options (`Shown.above`), its text,
    /// options and their lines, tabs and Submit row, not where the cursor is or what's ticked (the keys are worked
    /// out from the screen as it is when the tap arrives). Two edits of one file differ by their diff.
    public static func fingerprint(_ shown: Shown, sid: String) -> String {
        let menu = shown.menu
        let parts: [String] = [sid, shown.above.joined(separator: "\u{1F}"), menu.question, menu.options.joined(separator: "\u{1F}"),
                               menu.descriptions.map { $0 ?? "\u{18}" }.joined(separator: "\u{1F}"),
                               menu.tabs.map(\.title).joined(separator: "\u{1F}"), menu.currentTab.map(String.init) ?? "-",
                               menu.submit ?? "-", menu.multiSelect ? "multi" : "single"]
        return Base64URL.encode(Data(SHA256.hash(data: Data(parts.joined(separator: "\u{1E}").utf8))).prefix(12))
    }

    /// What `/api/state` carries for the session: `menu` from `read` (already masked).
    public static func json(_ shown: Shown, sid: String) -> [String: Any] {
        let menu = shown.menu
        var object: [String: Any] = [
            "question": menu.question, "options": menu.options,
            "descriptions": menu.descriptions.map { $0.map { $0 as Any } ?? NSNull() },
            "selected": menu.selected, "fingerprint": fingerprint(shown, sid: sid),
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

    /// Right before Enter, with `screen` read again: the menu with `fingerprint` is still up, its cursor on option `index`.
    public static func readyToEnter(_ index: Int, fingerprint: String, screen: String, sid: String) -> Bool {
        guard let shown = read(screen: screen, needsInput: true) else { return false }
        return Self.fingerprint(shown, sid: sid) == fingerprint && shown.menu.selected == index
    }

    /// The tap on option `index` of the menu with `fingerprint`, against the screen read again right now.
    public static func answer(choose index: Int, fingerprint: String, screen: String, needsInput: Bool, sid: String) -> Answer {
        guard let shown = read(screen: screen, needsInput: needsInput), Self.fingerprint(shown, sid: sid) == fingerprint else {
            return .stale
        }
        let menu = shown.menu
        // A multi-select's Submit / Next row sits under its options.
        let last = menu.submit == nil ? menu.options.count - 1 : menu.options.count
        guard (0...last).contains(index) else { return .invalid }
        return .keys(menu.keys(toChoose: index), label: menu.options.indices.contains(index) ? menu.options[index] : menu.submit ?? "")
    }
}
