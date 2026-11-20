import Foundation
import Testing

/// docs/process/v2-port-map.md merges by git's union driver (.gitattributes): two branches that each add a row at a
/// table's end merge with both rows instead of conflicting (`PortMapMergeTests`). The union driver keeps both sides'
/// lines wherever they overlap, so two branches that edit the same row each differently leave both versions of it,
/// and lines that overlap a table's end could leave a row outside its table. Nothing stops on either; this check does:
/// the file's tables are whole (a header, its `| --- |` line, rows with the header's number of cells), no two rows of a
/// table have one name (its first cell; a dated table's first two), and no conflict marker is left.
/// Part of DocLinksLint, the docs' lint.
extension DocLinksLintTests {
    static let portMap = "docs/process/v2-port-map.md"

    /// A table line's cells as GitHub splits them: at every `|` not escaped with `\` (inside inline code too), the
    /// outer pipes dropped.
    static func tableCells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in line.trimmingCharacters(in: .whitespaces) {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { current.append(character); escaped = true; continue }
            if character == "|" { cells.append(current); current = ""; continue }
            current.append(character)
        }
        cells.append(current)
        // "| a | b |" splits to "", " a ", " b ", "".
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// What's wrong with `text`'s tables, one line each with its line number (1-based); empty when nothing is.
    static func tableProblems(in text: String) -> [String] {
        var found: [String] = []
        let lines = text.components(separatedBy: "\n")
        var fenced = false
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fenced.toggle() }
            for marker in ["<<<<<<< ", ">>>>>>> "] where !fenced && line.hasPrefix(marker) {
                found.append("line \(index + 1): a conflict marker (\(marker.trimmingCharacters(in: .whitespaces)))")
            }
            guard !fenced, line.hasPrefix("|") else { index += 1; continue }
            // A table: the run of `|` lines from here.
            var end = index
            while end + 1 < lines.count, lines[end + 1].hasPrefix("|") { end += 1 }
            let header = tableCells(lines[index])
            let separator = index + 1 <= end ? tableCells(lines[index + 1]) : []
            let isSeparator = !separator.isEmpty && separator.allSatisfy { cell in
                !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" } && cell.contains("-")
            }
            if !isSeparator || separator.count != header.count {
                found.append("line \(index + 1): a table line without a table's header and `| --- |` line above it "
                             + "(a row left outside its table?): \(lines[index].prefix(80))")
                index = end + 1
                continue
            }
            // A row is named by its first cell; in a table of dated lines (Merges: one date, many lines) by its first two.
            let named = header.first?.lowercased() == "date" ? 2 : 1
            var seen: [String: Int] = [:]
            for row in stride(from: index + 2, through: end, by: 1) {
                let rowCells = tableCells(lines[row])
                if rowCells.count != header.count {
                    found.append("line \(row + 1): \(rowCells.count) cells, the table's header has \(header.count) "
                                 + "(a `|` in a cell is written `\\|`): \(lines[row].prefix(80))")
                }
                let name = rowCells.prefix(named).joined(separator: " | ")
                guard !name.isEmpty else { continue }
                if let earlier = seen[name] {
                    found.append("line \(row + 1): the same row name as line \(earlier + 1) (two edits of one row, both kept by a union merge?): \(name.prefix(80))")
                } else {
                    seen[name] = row
                }
            }
            index = end + 1
        }
        return found
    }

    @Test func thePortMapsTablesAreWhole() throws {
        let text = try String(contentsOf: Self.repo.appendingPathComponent(Self.portMap), encoding: .utf8)
        let problems = Self.tableProblems(in: text)
        #expect(problems.isEmpty, "\(Self.portMap):\n\(problems.joined(separator: "\n"))")
    }

    /// The table check finds each thing it's for, so the test above can't pass for nothing.
    @Test func theTableCheckFindsADuplicatedRowAStrayRowAShortRowAndAMarker() {
        let table = "| File | What |\n| --- | --- |\n| `a.swift` 1 | one |\n"
        #expect(Self.tableProblems(in: "# Doc\n\n" + table + "\nText.\n").isEmpty)
        #expect(Self.tableProblems(in: table + "| `a.swift` 1 | one, edited elsewhere |\n").count == 1)
        #expect(Self.tableProblems(in: table + "\nText.\n| `b.swift` 2 | two |\n").count == 1)
        #expect(Self.tableProblems(in: table + "| `b.swift` 2 | two | three |\n").count == 1)
        #expect(Self.tableProblems(in: table + "<<<<<<< HEAD\n").count == 1)
        // A `|` escaped in a cell doesn't split it; one inside a fenced block isn't a table.
        #expect(Self.tableProblems(in: table + "| `b.swift` 2 | `x \\| y` |\n").isEmpty)
        #expect(Self.tableProblems(in: "```\n| not a table\n```\n").isEmpty)
        // A table of dated lines names a row by its first two cells: one date has many lines.
        let dated = "| Date | Commit | Outcome |\n| --- | --- | --- |\n| 2026-11-17 | `1a` | ported |\n| 2026-11-17 | `2b` | owed |\n"
        #expect(Self.tableProblems(in: dated).isEmpty)
        #expect(Self.tableProblems(in: dated + "| 2026-11-17 | `2b` | ported |\n").count == 1)
    }
}
