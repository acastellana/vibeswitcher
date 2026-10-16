import Foundation

/// A block of a markdown reply. Inline markup (bold, code, links) stays in the text for the view to render.
public enum MDBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(ordered: Bool, start: Int, items: [MDListItem])
    case code(language: String?, text: String)
    case quote(String)
    case table(header: [String], alignments: [MDAlign], rows: [[String]])
    case rule
}

public struct MDListItem: Equatable, Sendable {
    public var text: String
    /// 0 for top-level items, 1 for items nested once, …
    public var depth: Int
    /// A task-list checkbox: true for "[x]", false for "[ ]", nil for none.
    public var checked: Bool?

    public init(text: String, depth: Int, checked: Bool? = nil) {
        self.text = text
        self.depth = depth
        self.checked = checked
    }
}

public enum MDAlign: Equatable, Sendable { case leading, center, trailing }

/// Splits markdown into blocks: the subset agents write (GitHub-flavored headings, lists, fences, tables, quotes,
/// rules). Anything else is a paragraph.
public enum MarkdownBlocks {
    public static func parse(_ text: String) -> [MDBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [MDBlock] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
                i += 1
            } else if let fence = fenceMarker(trimmed) {
                flush()
                let language = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                i += 1   // the closing fence (or past the end)
                blocks.append(.code(language: language.isEmpty ? nil : language, text: code.joined(separator: "\n")))
            } else if let heading = heading(trimmed) {
                flush()
                blocks.append(heading)
                i += 1
            } else if isRule(trimmed) {
                flush()
                blocks.append(.rule)
                i += 1
            } else if trimmed.hasPrefix(">") {
                flush()
                var quoted: [String] = []
                while i < lines.count, case let t = lines[i].trimmingCharacters(in: .whitespaces), t.hasPrefix(">") {
                    var rest = t.dropFirst()
                    if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                    quoted.append(String(rest))
                    i += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
            } else if i + 1 < lines.count, trimmed.contains("|"), let alignments = delimiterRow(lines[i + 1]) {
                flush()
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, case let t = lines[i].trimmingCharacters(in: .whitespaces), !t.isEmpty, t.contains("|") {
                    var row = cells(t)
                    row = Array(row.prefix(header.count)) + Array(repeating: "", count: max(0, header.count - row.count))
                    rows.append(row)
                    i += 1
                }
                let aligned = Array(alignments.prefix(header.count))
                    + Array(repeating: MDAlign.leading, count: max(0, header.count - alignments.count))
                blocks.append(.table(header: header, alignments: aligned, rows: rows))
            } else if let first = listItem(line) {
                flush()
                var items: [MDListItem] = []
                var indents: [Int] = []
                func add(_ item: (indent: Int, ordered: Bool, number: Int, text: String)) {
                    while let last = indents.last, last > item.indent { indents.removeLast() }
                    if indents.last != item.indent { indents.append(item.indent) }
                    var text = item.text
                    var checked: Bool?
                    for (box, value) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where text.hasPrefix(box) {
                        checked = value
                        text = String(text.dropFirst(box.count))
                    }
                    items.append(MDListItem(text: text, depth: min(indents.count - 1, 4), checked: checked))
                }
                add(first)
                i += 1
                while i < lines.count {
                    let next = lines[i]
                    let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                    if let item = listItem(next) {
                        // A top-level item of the other kind starts a new list.
                        if item.indent <= (indents.first ?? 0), item.ordered != first.ordered { break }
                        add(item)
                        i += 1
                    } else if nextTrimmed.isEmpty {
                        // A blank line ends the list unless the next item continues it.
                        var j = i + 1
                        while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                        guard j < lines.count, let item = listItem(lines[j]), item.ordered == first.ordered || item.indent > (indents.first ?? 0)
                        else { break }
                        i = j
                    } else if next.first?.isWhitespace == true, !items.isEmpty {
                        items[items.count - 1].text += " " + nextTrimmed
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(ordered: first.ordered, start: first.number, items: items))
            } else {
                paragraph.append(trimmed)
                i += 1
            }
        }
        flush()
        return blocks
    }

    private static func fenceMarker(_ trimmed: String) -> String? {
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) { return marker }
        return nil
    }

    private static func heading(_ trimmed: String) -> MDBlock? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    /// "- text", "* text", "+ text", "12. text", "3) text", with its indent.
    private static func listItem(_ line: String) -> (indent: Int, ordered: Bool, number: Int, text: String)? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.drop { $0 == " " || $0 == "\t" }
        if let marker = rest.first, "-*+".contains(marker), rest.dropFirst().first == " " {
            return (indent, false, 1, rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
        let digits = rest.prefix { $0.isNumber }
        guard (1...9).contains(digits.count), let number = Int(digits) else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let punctuation = after.first, ".)".contains(punctuation), after.dropFirst().first == " " else { return nil }
        return (indent, true, number, after.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }

    /// The cells of a table line; `\|` is a literal pipe.
    private static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in text {
            if escaped {
                current.append(character == "|" ? "|" : "\\\(character)")
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func delimiterRow(_ line: String) -> [MDAlign]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") || trimmed.contains(":") || trimmed.allSatisfy({ "-: ".contains($0) })
        else { return nil }
        var alignments: [MDAlign] = []
        for cell in cells(trimmed) {
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
            let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            alignments.append(left && right ? .center : right ? .trailing : .leading)
        }
        return alignments.isEmpty ? nil : alignments
    }
}
