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
    /// app's chat reads it (`ChatSync.menu`), else one of Claude's own dialogs whose rows have no numbers (`select`: its
    /// folder-trust question); never the slash-command menu or a local command's picker. Nil when none is.
    public static func menu(on screen: String) -> ScreenMenu? {
        var lines = Platform.lines(screen.replacingOccurrences(of: "\u{0}", with: " "))
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        let bottom = Array(lines.suffix(40))
        if let menu = ScreenMenu.parse(bottom) { return menu.commands || menu.picker ? nil : menu }
        guard ScreenMenu.parsePicker(bottom) == nil, ScreenMenu.parseCommands(bottom) == nil else { return nil }
        return select(bottom)
    }

    /// One of Claude's own dialogs drawn with rows that have no numbers, as 2.1.30x draws its folder-trust question at
    /// the start (acceptance run, 2026-11-20: `vibeswitcher new` in a new folder was stuck on it, needs-you with no
    /// `prompt`, so `reply` refused):
    ///
    ///      Quick safety check: Is this a project you created or one you trust? …
    ///
    ///      ❯ No, exit
    ///        Yes, I trust this folder
    ///
    ///     Enter to confirm · Esc to cancel
    ///
    /// The footer (the last line) says Enter chooses; one row is marked ❯ / ›, the others start where its text does
    /// (a line further in is the row above's second line), with no blank line between; the question is the text above,
    /// up to a rule (at most 12 lines: the trust question's path and its wrapped sentences). Options in screen order,
    /// the cursor's as `selected`, so `keys(toChoose:)` answers it as the app's keys do (arrows, then Enter). A local
    /// command's picker (under a fullscreen Claude's `▔▔▔`) isn't one: `menu(on:)` asks `parsePicker` first.
    static func select(_ screen: [String]) -> ScreenMenu? {
        let lines = screen.map(unboxed)
        guard let footer = lines.lastIndex(where: { !$0.allSatisfy(\.isWhitespace) }) else { return nil }
        let hint = lines[footer].trimmingCharacters(in: .whitespaces)
        guard hint.range(of: #"\bEnter to (confirm|select|continue)\b"#, options: .regularExpression) != nil else { return nil }
        let indent = { (line: String) in line.prefix { $0 == " " }.count }
        let blank = { (line: String) in line.allSatisfy(\.isWhitespace) }
        let isMarked = { (line: String) in line.drop { $0 == " " }.first.map { "❯›".contains($0) } == true }
        guard let marked = lines[max(0, footer - 20)..<footer].lastIndex(where: isMarked) else { return nil }
        let marker = indent(lines[marked])
        let text = marker + 1 + lines[marked].dropFirst(marker + 1).prefix { $0 == " " }.count
        var first = marked, last = marked
        while first > 0, !blank(lines[first - 1]), !isMarked(lines[first - 1]), indent(lines[first - 1]) >= text { first -= 1 }
        // A row's second line can't come before the first row.
        while first < marked, indent(lines[first]) > text { first += 1 }
        while last + 1 < footer, !blank(lines[last + 1]), !isMarked(lines[last + 1]), indent(lines[last + 1]) >= text { last += 1 }
        var rows: [(label: String, detail: [String])] = []
        var selected = 0
        for index in first...last {
            let line = lines[index]
            let content = line.dropFirst(index == marked ? text : indent(line)).trimmingCharacters(in: .whitespaces)
            if index != marked, indent(line) > text {
                rows[rows.count - 1].detail.append(content)
                continue
            }
            if index == marked { selected = rows.count }
            rows.append((content, []))
        }
        guard rows.count >= 2, rows.allSatisfy({ !$0.label.isEmpty }) else { return nil }
        var question: [String] = []
        for line in lines[..<first].reversed() {
            let words = line.trimmingCharacters(in: .whitespaces)
            if words.isEmpty { continue }
            if words.allSatisfy({ "─━═╭╮╰╯┌┐└┘-▔╌ ".contains($0) }) || question.count == 12 { break }
            question.insert(words, at: 0)
        }
        return ScreenMenu(question: question.joined(separator: "\n"), options: rows.map(\.label),
                          descriptions: rows.map { $0.detail.isEmpty ? nil : $0.detail.joined(separator: " ") }, selected: selected, hint: hint)
    }

    /// `  │ ❯ No   │` → `    ❯ No`: a box's sides as blanks, so its rows keep their columns.
    private static func unboxed(_ line: String) -> String {
        var characters = Array(line)
        while characters.last == " " { characters.removeLast() }
        guard let left = characters.firstIndex(where: { $0 != " " }), "│┃".contains(characters[left]) else { return String(characters) }
        characters[left] = " "
        if let right = characters.indices.last, right > left, "│┃".contains(characters[right]) { characters[right] = " " }
        while characters.last == " " { characters.removeLast() }
        return String(characters)
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
