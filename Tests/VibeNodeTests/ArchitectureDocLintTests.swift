import Foundation
import Testing
@testable import VibeNode

/// docs/guide/v2-architecture.md stays one current page (the architecture review's row 15): its kinds table is the one
/// the code makes (`KindsTable`), it stays short enough to read, and the docs' index links it.
@Suite struct ArchitectureDocLintTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let path = "docs/guide/v2-architecture.md"

    @Test func theKindsTableIsTheCodes() throws {
        let page = try String(contentsOf: Self.repo.appendingPathComponent(Self.path), encoding: .utf8)
        let made = try #require(KindsTable.replacing(in: page), "\(Self.path) has lost its kinds table's markers")
        #expect(made == page, "\(Self.path)'s kinds table is stale: run `.build/debug/vibeswitcher-cli kinds-doc --write \(Self.path)` and commit it")
        for kind in NodeWire.kinds.keys { #expect(page.contains("| `\(kind)` |"), "\(kind) isn't in the table") }
    }

    @Test func thePageStaysShortAndIsLinked() throws {
        let page = try String(contentsOf: Self.repo.appendingPathComponent(Self.path), encoding: .utf8)
        let lines = page.split(separator: "\n", omittingEmptySubsequences: false).count
        #expect(lines < 250, "\(Self.path) has \(lines) lines: one page, under 250")
        let index = try String(contentsOf: Self.repo.appendingPathComponent("docs/README.md"), encoding: .utf8)
        #expect(index.contains("(guide/v2-architecture.md)"))
    }

    /// The writer puts the table between the markers and nowhere else, and finds no markers in a page without them.
    @Test func theWriterReplacesOnlyBetweenTheMarkers() {
        let page = "# A page\n\nbefore\n\(KindsTable.begin)\nold table\n\(KindsTable.end)\nafter\n"
        let made = KindsTable.replacing(in: page)
        #expect(made == "# A page\n\nbefore\n\(KindsTable.begin)\n\(KindsTable.markdown())\n\(KindsTable.end)\nafter\n")
        #expect(KindsTable.replacing(in: "# no markers") == nil)
        #expect(KindsTable.markdown().split(separator: "\n").count == NodeWire.kinds.count + 2)
    }
}
