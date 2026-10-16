import Foundation
import Testing
@testable import VibeCore

struct LineDiffTests {
    func render(_ lines: [DiffLine]) -> String {
        lines.map { line in
            switch line.kind {
            case .same: return " \(line.text)"
            case .removed: return "-\(line.text)"
            case .added: return "+\(line.text)"
            case .gap: return "…\(line.text)"
            }
        }.joined(separator: "\n")
    }

    @Test func replacementInsertionAndDeletion() {
        #expect(render(LineDiff.lines(old: "a\nb\nc", new: "a\nB\nc")) == " a\n-b\n+B\n c")
        #expect(render(LineDiff.lines(old: "a\nc", new: "a\nb\nc")) == " a\n+b\n c")
        #expect(render(LineDiff.lines(old: "a\nb\nc", new: "a\nc")) == " a\n-b\n c")
        #expect(render(LineDiff.lines(old: "", new: "x")) == "+x")
        #expect(render(LineDiff.lines(old: "same", new: "same")) == " same")
    }

    @Test func hunksKeepContextAndMarkGaps() {
        let old = (1...20).map(String.init).joined(separator: "\n")
        let new = old.replacingOccurrences(of: "\n10\n", with: "\nten\n")
        let rendered = render(LineDiff.hunks(LineDiff.lines(old: old, new: new), context: 2))
        #expect(rendered == "…7\n 8\n 9\n-10\n+ten\n 11\n 12\n…8")
    }

    @Test func nearbyChangesShareAHunk() {
        let old = "1\n2\n3\n4\n5\n6"
        let new = "1\nX\n3\n4\nY\n6"
        #expect(render(LineDiff.hunks(LineDiff.lines(old: old, new: new), context: 1)) == " 1\n-2\n+X\n 3\n 4\n-5\n+Y\n 6")
    }

    @Test func hugeInputsFallBackToRemovedThenAdded() {
        let old = (1...4000).map { "o\($0)" }.joined(separator: "\n")
        let lines = LineDiff.lines(old: old, new: "n")
        #expect(lines.filter { $0.kind == .removed }.count == 4000)
        #expect(lines.last == DiffLine(kind: .added, text: "n"))
    }
}
