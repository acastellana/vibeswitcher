import AppKit
import SwiftTerm
import Testing
import VibeCore
@testable import VibeSwitcher

/// The window's terminal pane (`HostTerminalView`, as `TerminalPaneController` makes it) fed the scratch captures of
/// Claude Code 2.1.304's status rows that `StatusRowsTests` gives the host's parser: its cells, row for row, are
/// Terminal.app's at 110 and 160 columns. With `STATUS_ROWS_SNAPSHOT_DIR=/some/folder` it also draws each moment
/// into `pane-COLS-MOMENT.png` there (offscreen; nothing is typed anywhere).
@MainActor
@Suite(.serialized)
struct StatusRowsPaneTests {
    nonisolated static let folder = ProcessInfo.processInfo.environment["STATUS_ROWS_SNAPSHOT_DIR"]
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("VibeHostTests/Fixtures")

    struct Reference: Decodable {
        let cols: Int
        let rows: Int
        let marks: [String: Int]
        let terminalApp: [String: [String]]
    }

    static func capture(cols: Int) throws -> (bytes: [UInt8], reference: Reference) {
        let name = "claude-2.1.304-status-rows-\(cols)x40"
        let bytes = Array(try Data(contentsOf: fixtures.appendingPathComponent("\(name).raw")))
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: fixtures.appendingPathComponent("\(name).json")))
        return (bytes, reference)
    }

    /// A pane's terminal view of `cols` x `rows`, in the app's default look, fed `bytes`.
    static func pane(cols: Int, rows: Int, bytes: [UInt8]) -> HostTerminalView {
        let view = HostTerminalView(frame: NSRect(x: 0, y: 0, width: 2_000, height: 1_000), font: nil, options: TerminalOptions(scrollback: 10_000))
        view.apply(TerminalAppearance(), darkMode: true)
        view.resize(cols: cols, rows: rows)
        view.frame = view.getOptimalFrameSize()
        view.feed(byteArray: bytes[...])
        return view
    }

    /// Its rows as cells (a wide character's second cell a space, as on Terminal.app's screen), trailing blanks dropped.
    static func rows(of view: HostTerminalView) -> [String] {
        let terminal = view.getTerminal()
        return (0..<terminal.rows).map { row in
            (terminal.getLine(row: row)?.translateToString(trimRight: true, characterProvider: terminal.getCharacter(for:)) ?? "")
                .replacingOccurrences(of: "\u{0}", with: " ")
                .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
    }

    @Test(arguments: [110, 160])
    func thePanesRowsAreTerminalAppsRows(cols: Int) throws {
        let (bytes, reference) = try Self.capture(cols: cols)
        for (moment, mark) in reference.marks.sorted(by: { $0.value < $1.value }) {
            let view = Self.pane(cols: cols, rows: reference.rows, bytes: Array(bytes[0..<mark]))
            #expect(view.getTerminal().cols == cols && view.getTerminal().rows == reference.rows)
            let rows = Self.rows(of: view), expected = try #require(reference.terminalApp[moment])
            for (index, (row, want)) in zip(rows, expected).enumerated() {
                #expect(row == want, "\(cols) columns, \(moment), row \(index)")
            }
            if let folder = Self.folder {
                let text = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: text)
                // The view paints its background on its layer, not in `draw`: under the text here.
                let picture = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: picture)
                view.nativeBackgroundColor.setFill()
                view.bounds.fill()
                text.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
                try picture.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: folder).appendingPathComponent("pane-\(cols)-\(moment).png"))
            }
        }
    }
}
