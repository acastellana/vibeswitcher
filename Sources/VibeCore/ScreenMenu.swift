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
    /// The option the cursor is on; `options.count` for a multi-select's Submit / Next row.
    public var selected: Int
    public var tabs: [Tab]
    /// The footer saying how to answer ("Enter to select · ↑/↓ to navigate · Esc to cancel").
    public var hint: String?
    /// A multi-select's boxes (`[✔] Cream`), one per option; nil for a single choice.
    public var checked: [Bool]?
    /// A multi-select's row under its options: "Submit", or "Next" when more questions follow.
    public var submit: String?
    /// The open tab, as drawn (Claude marks it only by its background): nil when that wasn't seen.
    public var openTab: Int?
    /// Claude's slash-command menu (under the prompt box while `/…` is typed), not a question: Esc closes it.
    public var commands = false

    public init(question: String, options: [String], descriptions: [String?]? = nil, selected: Int, tabs: [Tab] = [], hint: String? = nil,
                checked: [Bool]? = nil, submit: String? = nil, openTab: Int? = nil) {
        self.question = question
        self.options = options
        self.descriptions = descriptions ?? Array(repeating: nil, count: options.count)
        self.selected = selected
        self.tabs = tabs
        self.hint = hint
        self.checked = checked
        self.submit = submit
        self.openTab = openTab
    }

    /// The question being answered when there are tabs: the open one (you can go back to one already answered),
    /// else the first not yet answered.
    public var currentTab: Int? { tabs.isEmpty ? nil : openTab ?? tabs.firstIndex { !$0.done } }

    public var multiSelect: Bool { checked != nil }

    /// The same question as `other` (its cursor, ticks or free text may have moved): an answer meant for one
    /// fits the other.
    public func sameQuestion(as other: ScreenMenu) -> Bool {
        question == other.question && tabs.map(\.title) == other.tabs.map(\.title) && currentTab == other.currentTab
            && options.count == other.options.count && submit == other.submit && multiSelect == other.multiSelect
            && commands == other.commands && (!commands || options == other.options)
    }

    /// The last menu on the screen: options "1. …", "2. …" in order (description lines, rules and blank lines may
    /// sit between them), one of them marked with ❯ / › / > (or a multi-select's Submit row under them).
    /// `highlights`: per line, the stretches drawn on a coloured background or inverted (Claude's open tab).
    public static func parse(_ screen: [String], highlights: [[String]] = []) -> ScreenMenu? {
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
        // A multi-select's Submit / Next row: after the last option and its description, before the footer.
        var submit: (label: String, marked: Bool)?
        for line in lines[(last + 1)...] {
            if let row = submitRow(line) {
                submit = row
                break
            }
            if isHint(line) { break }
        }
        let marked = found.filter(\.option.marked).count + (submit?.marked == true ? 1 : 0)
        guard found.count >= 2, found.first?.option.number == 1, marked == 1 else { return nil }
        let selected = found.firstIndex(where: \.option.marked) ?? found.count
        // Descriptions: the text lines right under an option, up to the next option, rule or blank line.
        let descriptions: [String?] = found.enumerated().map { position, entry in
            let stop = position + 1 < found.count ? found[position + 1].index : lines.count
            var text: [String] = []
            for line in lines[(entry.index + 1)..<stop] {
                if line.isEmpty || isSeparator(line) || isHint(line) || submitRow(line) != nil { break }
                text.append(line)
            }
            return text.isEmpty ? nil : text.joined(separator: " ")
        }
        // `[✔] Cream`, `[ ] Nuts`: a multi-select (every option has its box).
        let boxes = found.map { box($0.option.label) }
        let checked = boxes.allSatisfy { $0 != nil } ? boxes.map { $0!.checked } : nil
        let labels = checked == nil ? found.map(\.option.label) : boxes.map { $0!.label }
        var tabs: [Tab] = []
        var openTab: Int?
        var question: [String] = []
        index = found[0].index - 1
        // The question: the lines just above the options (at most 6); the tab bar may be further up (the review tab
        // lists every answer).
        while index >= 0, found[0].index - index <= 30 {
            let line = lines[index]
            if isSeparator(line) { break }
            if let parsed = tabBar(line) {
                tabs = parsed
                let marks = highlights.indices.contains(index) ? highlights[index] : []
                openTab = parsed.firstIndex { tab in marks.contains { $0.contains(tab.title) } }
                break
            }
            if !line.isEmpty, question.count < 6 { question.insert(line, at: 0) }
            index -= 1
        }
        let hint = lines[found[found.count - 1].index...].last(where: isHint)
        return ScreenMenu(question: question.joined(separator: "\n"), options: labels, descriptions: descriptions, selected: selected,
                          tabs: tabs, hint: hint, checked: checked, submit: submit?.label, openTab: openTab)
    }

    /// Arrow keys from the cursor to `index`, then Enter.
    public func keys(toChoose index: Int) -> [HostInput.Write] {
        var writes = arrows(to: index)
        writes.append(HostInput.Write(bytes: [13], delay: writes.isEmpty ? 0 : 0.08))
        return writes
    }

    /// For a free-text option ("Type something."): move to it, erase what's in it (`replacing` characters), type
    /// the answer, then Enter. A multi-select's field is ticked by typing into it, and Enter would untick it: no
    /// Enter there (its Submit row sends it).
    public func keys(toChoose index: Int, typing text: String, replacing: Int = 0) -> [HostInput.Write] {
        var writes = arrows(to: index)
        if replacing > 0 {
            writes.append(HostInput.Write(bytes: Array(repeating: 0x7F, count: replacing), delay: writes.isEmpty ? 0 : 0.08))
        }
        let clean = String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        writes.append(HostInput.Write(bytes: Array(clean.utf8), delay: writes.isEmpty ? 0 : 0.08))
        if !multiSelect { writes.append(HostInput.Write(bytes: [13], delay: 0.08)) }
        return writes
    }

    /// How long `writes` take to go in (their delays added up).
    public static func duration(_ writes: [HostInput.Write]) -> TimeInterval { writes.reduce(0) { $0 + $1.delay } }

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

    /// Claude's slash-command menu: under the prompt box (its last rule) while `/…` is typed, rows `/name  description`
    /// with no numbers, the chosen one marked ❯, and no footer. Enter runs the chosen command, Esc closes the menu.
    public static func parseCommands(_ screen: [String]) -> ScreenMenu? {
        let lines = screen.map(clean)
        guard let rule = lines.lastIndex(where: isSeparator), rule + 1 < lines.count else { return nil }
        var rows: [(name: String, description: String?, marked: Bool)] = []
        for line in lines[(rule + 1)...] {
            if line.isEmpty, rows.isEmpty { continue }
            guard let row = commandRow(line) else { break }
            rows.append(row)
        }
        guard !rows.isEmpty, rows.filter(\.marked).count == 1, let selected = rows.firstIndex(where: \.marked) else { return nil }
        let typed = lines[..<rule].last { $0.hasPrefix("❯") }.map { $0.dropFirst().trimmingCharacters(in: .whitespaces) } ?? "/"
        var menu = ScreenMenu(question: "Commands for \(typed)", options: rows.map(\.name), descriptions: rows.map(\.description),
                              selected: selected)
        menu.commands = true
        return menu
    }

    /// `❯ /model   Set the AI model` → "/model", its description, marked.
    private static func commandRow(_ line: String) -> (name: String, description: String?, marked: Bool)? {
        var rest = Substring(line)
        var marked = false
        if let first = rest.first, "❯›".contains(first) {
            marked = true
            rest = rest.dropFirst().drop { $0 == " " }
        }
        guard rest.first == "/", rest.count > 1, rest.dropFirst().first?.isWhitespace == false else { return nil }
        let name = rest.prefix { !$0.isWhitespace }
        let description = rest.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
        return (String(name), description.isEmpty ? nil : description, marked)
    }

    /// A multi-select's `Submit` / `Next` row (`❯    Submit` when the cursor is on it).
    private static func submitRow(_ line: String) -> (label: String, marked: Bool)? {
        var rest = Substring(line)
        var marked = false
        if let first = rest.first, "❯›>".contains(first) {
            marked = true
            rest = rest.dropFirst()
        }
        let label = rest.trimmingCharacters(in: .whitespaces)
        return label == "Submit" || label == "Next" ? (label, marked) : nil
    }

    /// `[✔] Cream` → ticked, "Cream"; `[ ] Nuts` → not ticked, "Nuts".
    private static func box(_ label: String) -> (checked: Bool, label: String)? {
        let characters = Array(label)
        guard characters.count >= 4, characters[0] == "[", characters[2] == "]", characters[3] == " " else { return nil }
        return (characters[1] != " ", String(characters[4...]).trimmingCharacters(in: .whitespaces))
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
