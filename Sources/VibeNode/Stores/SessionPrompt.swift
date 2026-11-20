import Foundation
import VibeCore

/// The question open on a hosted agent session's screen (2026-11-20, the parity table's gap 6): a permission prompt,
/// Claude's own question, a plan to approve, its trust question, as `ScreenMenu` reads it, and when it was first seen.
/// `NodeSessions.prompts` holds them; a session's live value carries one as `prompt`; `session.reply` answers it.
public struct SessionPrompt: Equatable, Sendable {
    public var menu: ScreenMenu
    public var at: Date

    public init(menu: ScreenMenu, at: Date) {
        self.menu = menu
        self.at = at
    }

    /// The question open on `screen` that takes an answer: an agent's numbered menu read off its last 40 lines as the
    /// app's chat reads it (`ChatSync.menu`); never the slash-command menu or a local command's picker. Nil when none is.
    public static func menu(on screen: String) -> ScreenMenu? {
        var lines = Platform.lines(screen.replacingOccurrences(of: "\u{0}", with: " "))
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        guard let menu = ScreenMenu.parse(Array(lines.suffix(40))), !menu.commands, !menu.picker else { return nil }
        return menu
    }

    /// Whether option `index` of `menu` is a free-text one ("Type something."): it takes the answer's words.
    public static func takesText(_ menu: ScreenMenu, _ index: Int) -> Bool {
        menu.options.indices.contains(index) && menu.options[index].lowercased().hasPrefix("type something")
    }

    /// As a session's `prompt` carries it: the question and its options as the screen shows them (an agent's words:
    /// a client shows them as text only), each option's description, the options that take words (`text`, by index),
    /// whether it takes several ticks, and when it was first seen.
    public var value: NodeWire.Value {
        .object([
            "question": .string(menu.question),
            "options": .array(menu.options.map(NodeWire.Value.string)),
            "descriptions": .array(menu.descriptions.map { $0.map(NodeWire.Value.string) ?? .null }),
            "text": .array(menu.options.indices.filter { Self.takesText(menu, $0) }.map(NodeWire.Value.int)),
            "multiSelect": .bool(menu.multiSelect),
            "at": .date(at),
        ])
    }
}
