import Foundation
import VibeCore

/// `vibeswitcher stats` as it prints (`stats`' value, the Mac's Statistics window's words): the range and its days, the
/// node's figures one a line (`Load: median 6.2 · … — 12 min at 24 or more…`, a usage limit with a bar of `#`), the
/// projects' table in columns with its totals, then each quality section's figures, the breakdown by who did the work,
/// the 8-week trend and the estimate against working solo. Every string goes through `ConfigSeal.inert` (the terminal's
/// own lock: a project's name is a folder's).
public enum StatisticsText {
    /// `stats`' typed result said: its figures, rows and quality are the page's shapes, read as values.
    public static func lines(_ result: WireKinds.Stats.Result) -> [String] { lines(NodeWire.Value(wire: result)) }

    static func inert(_ text: String?, limit: Int = 300) -> String { ConfigSeal.inert(text ?? "", limit: limit) }

    public static func lines(_ value: NodeWire.Value) -> [String] {
        var lines = ["Statistics · \(inert(value["title"]?.string, limit: 40)) · \(inert(value["span"]?.string, limit: 80))", ""]
        lines.append("This node")
        lines += (value["mac"]?.array ?? []).flatMap(figure)
        lines.append("")
        lines.append("Projects")
        let projects = (value["projects"]?.array ?? []) + [value["total"]].compactMap { $0 == .null ? nil : $0 }
        if projects.isEmpty {
            lines.append("  No project with a lead's board on this node yet.")
        } else {
            let columns = ["Project"] + (value["columns"]?.array ?? []).map { inert($0.string, limit: 40) }
            let rows = projects.map { row in [inert(row["name"]?.string, limit: 60)] + (row["cells"]?.array ?? []).map { inert($0.string, limit: 40) } }
            lines += table(columns, rows)
            for row in projects { if let note = row["note"]?.string { lines.append("  \(inert(row["name"]?.string, limit: 60)): \(inert(note))") } }
        }
        guard let quality = value["quality"], quality != .null else { return lines }
        for section in quality["sections"]?.array ?? [] {
            lines += ["", inert(section["title"]?.string, limit: 120)]
            lines += (section["figures"]?.array ?? []).flatMap(figure)
        }
        let breakdown = quality["breakdown"]?.array ?? []
        if !breakdown.isEmpty {
            lines += ["", "By who did the work"]
            let columns = [""] + (quality["columns"]?.array ?? []).map { inert($0.string, limit: 40) }
            lines += table(columns, breakdown.map { row in
                [((row["model"]?.bool == true) ? "  " : "") + inert(row["name"]?.string, limit: 60)] + (row["cells"]?.array ?? []).map { inert($0.string, limit: 40) }
            })
            if let note = quality["modelsNote"]?.string { lines.append("  " + inert(note)) }
        }
        let weeks = quality["trend"]?.array ?? []
        if !weeks.isEmpty {
            lines += ["", "The last 8 weeks"]
            lines += table(["Week of", "Merged", "First audit", "Cost / task"], weeks.map { week in
                [inert(week["label"]?.string, limit: 20), "\(week["merged"]?.int ?? 0)", inert(week["passRate"]?.string, limit: 20), inert(week["cost"]?.string, limit: 20)]
            })
        }
        if let compared = quality["compared"], let groups = compared["groups"]?.array, !groups.isEmpty {
            lines += ["", "\(inert(compared["title"]?.string, limit: 80)) (\(inert(compared["badge"]?.string, limit: 20)))", "  " + inert(compared["method"]?.string, limit: 600)]
            let columns = (compared["columns"]?.array ?? []).map { inert($0.string, limit: 20) }
            for group in groups {
                lines.append("  " + inert(group["title"]?.string, limit: 120))
                lines += table([""] + columns, (group["rows"]?.array ?? []).map { row in
                    [inert(row["label"]?.string, limit: 60)] + (row["cells"]?.array ?? []).map { cell in
                        inert(cell["value"]?.string, limit: 40) + (cell["detail"]?.string.map { " (\(inert($0, limit: 80)))" } ?? "")
                    }
                }).map { "  " + $0 }
            }
        }
        return lines
    }

    /// "  Claude weekly: 42% [########............] — on pace · resets …".
    static func figure(_ figure: NodeWire.Value) -> [String] {
        var line = "  \(inert(figure["label"]?.string, limit: 80)): \(inert(figure["value"]?.string, limit: 120))"
        if let meter = figure["meter"], meter != .null, let used = meter["used"]?.int {
            let filled = max(0, min(20, Int((Double(used) / 50).rounded())))
            line += " [" + String(repeating: "#", count: filled) + String(repeating: ".", count: 20 - filled) + "]"
        }
        if let detail = figure["detail"]?.string, !detail.isEmpty { line += " — " + inert(detail) }
        return [line]
    }

    /// Rows in columns: the first left-aligned, the rest right-aligned, two spaces apart, each line indented.
    static func table(_ columns: [String], _ rows: [[String]]) -> [String] {
        let all = [columns] + rows
        let count = all.map(\.count).max() ?? 0
        let widths = (0..<count).map { index in all.map { $0.count > index ? $0[index].count : 0 }.max() ?? 0 }
        return all.map { row in
            "  " + (0..<count).map { index in
                let cell = row.count > index ? row[index] : ""
                let pad = String(repeating: " ", count: widths[index] - cell.count)
                return index == 0 ? cell + pad : pad + cell
            }.joined(separator: "  ").replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        }
    }
}
