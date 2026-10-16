import Foundation

public struct DiffLine: Equatable, Sendable {
    public enum Kind: Sendable { case same, removed, added, gap }
    public var kind: Kind
    /// The line; for a gap, how many unchanged lines it hides.
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// Line diffs for the chat's edit views.
public enum LineDiff {
    /// Beyond this many cells of the comparison table the middle is shown as removed, then added.
    static let maxCells = 2_000_000

    public static func lines(old: String, new: String) -> [DiffLine] {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let b = new.isEmpty ? [] : new.components(separatedBy: "\n")
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let midA = Array(a[prefix..<(a.count - suffix)])
        let midB = Array(b[prefix..<(b.count - suffix)])
        var out = a[..<prefix].map { DiffLine(kind: .same, text: $0) }
        out += middle(midA, midB)
        out += a[(a.count - suffix)...].map { DiffLine(kind: .same, text: $0) }
        return out
    }

    private static func middle(_ a: [String], _ b: [String]) -> [DiffLine] {
        guard !a.isEmpty, !b.isEmpty, a.count * b.count <= maxCells else {
            return a.map { DiffLine(kind: .removed, text: $0) } + b.map { DiffLine(kind: .added, text: $0) }
        }
        // Longest common subsequence lengths, from the end.
        let width = b.count + 1
        var table = [Int32](repeating: 0, count: (a.count + 1) * width)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i * width + j] = a[i] == b[j] ? table[(i + 1) * width + j + 1] + 1
                                                    : max(table[(i + 1) * width + j], table[i * width + j + 1])
            }
        }
        var out: [DiffLine] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                out.append(DiffLine(kind: .same, text: a[i])); i += 1; j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                out.append(DiffLine(kind: .removed, text: a[i])); i += 1
            } else {
                out.append(DiffLine(kind: .added, text: b[j])); j += 1
            }
        }
        out += a[i...].map { DiffLine(kind: .removed, text: $0) }
        out += b[j...].map { DiffLine(kind: .added, text: $0) }
        return out
    }

    /// The changed lines with `context` unchanged lines around each; longer unchanged runs become gaps.
    public static func hunks(_ lines: [DiffLine], context: Int) -> [DiffLine] {
        let changed = lines.indices.filter { lines[$0].kind != .same }
        guard !changed.isEmpty else { return lines }
        var keep = [Bool](repeating: false, count: lines.count)
        for index in changed {
            for k in max(0, index - context)...min(lines.count - 1, index + context) { keep[k] = true }
        }
        var out: [DiffLine] = []
        var hidden = 0
        for (index, line) in lines.enumerated() {
            if keep[index] {
                if hidden > 0 { out.append(DiffLine(kind: .gap, text: "\(hidden)")); hidden = 0 }
                out.append(line)
            } else {
                hidden += 1
            }
        }
        if hidden > 0 { out.append(DiffLine(kind: .gap, text: "\(hidden)")) }
        return out
    }
}
