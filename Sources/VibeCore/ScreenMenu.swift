import Foundation

/// A numbered choice an agent shows in its terminal (permission prompts, questions): read off the screen so the
/// chat can offer it as buttons, then answered with the arrow keys and Enter, like a person would.
public struct ScreenMenu: Equatable, Sendable {
    /// A question's tab when several are asked at once (`☐ Fruit  ☐ Toppings  ✔ Submit`).
    public struct Tab: Equatable, Sendable {
        public var title: String
        public var done: Bool
        public init(title: String, done: Bool) {
            self.title = title
            self.done = done
        }
    }

    /// The text above the options ("Bash command … Do you want to proceed?").
    public var question: String
    public var options: [String]
    /// The line under each option, when it has one.
    public var descriptions: [String?]
    /// The option the cursor is on.
    public var selected: Int
    public var tabs: [Tab]
    /// The footer saying how to answer ("Enter to select · ↑/↓ to navigate · Esc to cancel").
    public var hint: String?

    public init(question: String, options: [String], descriptions: [String?]? = nil, selected: Int, tabs: [Tab] = [], hint: String? = nil) {
        self.question = question
        self.options = options
        self.descriptions = descriptions ?? Array(repeating: nil, count: options.count)
        self.selected = selected
        self.tabs = tabs
        self.hint = hint
    }

    /// The question being answered when there are tabs: the first not yet answered.
    public var currentTab: Int? { tabs.isEmpty ? nil : tabs.firstIndex { !$0.done } }

    /// The last menu on the screen: options "1. …", "2. …" in order (description lines, rules and blank lines may
    /// sit between them), one of them marked with ❯ / › / >.
    public static func parse(_ screen: [String]) -> ScreenMenu? {
        let lines = screen.map(clean)
        guard let last = lines.lastIndex(where: { option($0) != nil }), let lastOption = option(lines[last]) else { return nil }
        // Walk up from the last option, number by number, down to 1.
        var found = [(index: last, option: lastOption)]
        var index = last - 1
        while index >= 0, let wanted = found.last.map({ $0.option.number - 1 }), wanted >= 1, last - index < 60 {
            if let candidate = option(lines[index]) {
                guard candidate.number == wanted else { return nil }
                found.append((index, candidate))
            }
            index -= 1
        }
        found.reverse()
        guard found.count >= 2, found.first?.option.number == 1,
              found.filter(\.option.marked).count == 1, let selected = found.firstIndex(where: \.option.marked) else { return nil }
        // Descriptions: the text lines right under an option, up to the next option, rule or blank line.
        let descriptions: [String?] = found.enumerated().map { position, entry in
            let stop = position + 1 < found.count ? found[position + 1].index : lines.count
            var text: [String] = []
            for line in lines[(entry.index + 1)..<stop] {
                if line.isEmpty || isSeparator(line) || isHint(line) { break }
                text.append(line)
            }
            return text.isEmpty ? nil : text.joined(separator: " ")
        }
        var tabs: [Tab] = []
        var question: [String] = []
        index = found[0].index - 1
        while index >= 0, question.count < 6 {
            let line = lines[index]
            if isSeparator(line) { break }
            if let parsed = tabBar(line) {
                tabs = parsed
                break
            }
            if !line.isEmpty { question.insert(line, at: 0) }
            index -= 1
        }
        let hint = lines[found[found.count - 1].index...].last(where: isHint)
        return ScreenMenu(question: question.joined(separator: "\n"), options: found.map(\.option.label),
                          descriptions: descriptions, selected: selected, tabs: tabs, hint: hint)
    }

    /// Arrow keys from the cursor to `index`, then Enter.
    public func keys(toChoose index: Int) -> [HostInput.Write] {
        var writes = arrows(to: index)
        writes.append(HostInput.Write(bytes: [13], delay: writes.isEmpty ? 0 : 0.08))
        return writes
    }

    /// For a free-text option ("Type something."): move to it, type the answer, then Enter.
    public func keys(toChoose index: Int, typing text: String) -> [HostInput.Write] {
        var writes = arrows(to: index)
        let clean = String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        writes.append(HostInput.Write(bytes: Array(clean.utf8), delay: writes.isEmpty ? 0 : 0.08))
        writes.append(HostInput.Write(bytes: [13], delay: 0.08))
        return writes
    }

    private func arrows(to index: Int) -> [HostInput.Write] {
        let steps = index - selected
        let arrow: [UInt8] = steps > 0 ? [27, 91, 66] : [27, 91, 65]
        return (0..<abs(steps)).map { HostInput.Write(bytes: arrow, delay: $0 == 0 ? 0 : 0.03) }
    }

    private static func clean(_ line: String) -> String {
        line.trimmingCharacters(in: CharacterSet(charactersIn: "│┃║").union(.whitespaces))
    }

    private static func isSeparator(_ line: String) -> Bool {
        !line.isEmpty && line.allSatisfy { "─━═╭╮╰╯┌┐└┘-".contains($0) || $0 == " " }
    }

    private static func isHint(_ line: String) -> Bool {
        line.contains("to select") || line.contains("to navigate") || line.contains("Esc to cancel")
    }

    /// `←  ☐ Fruit  ☐ Toppings  ✔ Submit  →`
    private static func tabBar(_ line: String) -> [Tab]? {
        guard line.contains("☐") || line.contains("✔") || line.contains("☒"), line.contains("←") || line.contains("→") || line.contains("Submit")
        else { return nil }
        let body = line.replacingOccurrences(of: "←", with: "").replacingOccurrences(of: "→", with: "")
        let parts = body.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let tabs = parts.compactMap { part -> Tab? in
            guard let mark = part.first, "☐✔☒☑".contains(mark) else { return nil }
            return Tab(title: part.dropFirst().trimmingCharacters(in: .whitespaces), done: mark != "☐")
        }
        return tabs.isEmpty ? nil : tabs
    }

    private static func option(_ line: String) -> (number: Int, label: String, marked: Bool)? {
        var rest = Substring(line)
        var marked = false
        if let first = rest.first, "❯›>".contains(first) {
            marked = true
            rest = rest.dropFirst().drop { $0 == " " }
        }
        let digits = rest.prefix { $0.isNumber }
        guard (1...2).contains(digits.count), let number = Int(digits) else { return nil }
        rest = rest.dropFirst(digits.count)
        guard rest.hasPrefix(". ") else { return nil }
        let label = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : (number, label, marked)
    }
}

/// The permission mode Claude Code shows in its footer; shift+tab cycles through them.
public enum AgentMode: String, Equatable, Sendable {
    case normal, acceptEdits, plan, auto, bypass

    public static let cycleKey: [UInt8] = [27, 91, 90]   // shift+tab (ESC [ Z)

    public var label: String {
        switch self {
        case .normal: return "Ask before edits"
        case .acceptEdits: return "Accept edits"
        case .plan: return "Plan mode"
        case .auto: return "Auto mode"
        case .bypass: return "Bypass permissions"
        }
    }

    public static func parse(_ screen: [String]) -> AgentMode? {
        for line in screen.reversed() {
            let lower = line.lowercased()
            if lower.contains("plan mode on") { return .plan }
            if lower.contains("accept edits on") { return .acceptEdits }
            if lower.contains("auto mode on") { return .auto }
            if lower.contains("bypass permissions on") { return .bypass }
            if lower.contains("? for shortcuts") { return .normal }
        }
        return nil
    }
}
