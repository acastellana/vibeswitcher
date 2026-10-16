import Foundation

/// A numbered choice an agent shows in its terminal (permission prompts, questions): read off the screen so the
/// chat can offer it as buttons, then answered with the arrow keys and Enter, like a person would.
public struct ScreenMenu: Equatable, Sendable {
    /// The text above the options ("Bash command … Do you want to proceed?").
    public var question: String
    public var options: [String]
    /// The option the cursor is on.
    public var selected: Int

    public init(question: String, options: [String], selected: Int) {
        self.question = question
        self.options = options
        self.selected = selected
    }

    /// The last menu on the screen: consecutive "1. …", "2. …" lines, one of them marked with ❯ / › / >.
    public static func parse(_ screen: [String]) -> ScreenMenu? {
        let lines = screen.map(clean)
        guard let last = lines.lastIndex(where: { option($0) != nil }) else { return nil }
        var first = last
        while first > 0, let above = option(lines[first - 1]), let here = option(lines[first]), above.number == here.number - 1 {
            first -= 1
        }
        let block = lines[first...last].compactMap(option)
        guard block.count >= 2, block.first?.number == 1,
              block.filter(\.marked).count == 1, let selected = block.firstIndex(where: \.marked) else { return nil }
        var question: [String] = []
        var index = first - 1
        while index >= 0, question.count < 6 {
            let line = lines[index]
            if isSeparator(line) { break }
            if !line.isEmpty { question.insert(line, at: 0) }
            index -= 1
        }
        return ScreenMenu(question: question.joined(separator: "\n"), options: block.map(\.label), selected: selected)
    }

    /// Arrow keys from the cursor to `index`, then Enter.
    public func keys(toChoose index: Int) -> [HostInput.Write] {
        let steps = index - selected
        let arrow: [UInt8] = steps > 0 ? [27, 91, 66] : [27, 91, 65]
        var writes = (0..<abs(steps)).map { HostInput.Write(bytes: arrow, delay: $0 == 0 ? 0 : 0.03) }
        writes.append(HostInput.Write(bytes: [13], delay: writes.isEmpty ? 0 : 0.08))
        return writes
    }

    private static func clean(_ line: String) -> String {
        line.trimmingCharacters(in: CharacterSet(charactersIn: "│┃║").union(.whitespaces))
    }

    private static func isSeparator(_ line: String) -> Bool {
        !line.isEmpty && line.allSatisfy { "─━═╭╮╰╯┌┐└┘-".contains($0) || $0 == " " }
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
