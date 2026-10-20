import Darwin
import Foundation
import SwiftTerm
import Testing
@testable import VibeHost

/// Claude Code 2.1.304's status rows (the status line under the box, the spinner row, the permission prompt) at 110 and
/// 160 columns, fed to `SessionParser` and compared row for row with Terminal.app's screen for the same bytes.
///
/// Captured byte for byte from scratch PTYs by `Tests/Tools/capture-claude-status-rows.py` (a scratch HOME with
/// `tui: fullscreen` and a two-line status line like claude-hud's, a scratch project, a fake Messages API on
/// 127.0.0.1: never a real session or account). The `.json` beside each capture holds the byte offsets of the three
/// moments and Terminal.app's 40 rows at each, read (AppleScript `contents`) from a scratch Terminal window of the
/// same size that `cat` the capture up to that offset.
struct StatusRowsTests {
    struct Capture {
        let bytes: [UInt8]
        let cols: Int
        let rows: Int
        let marks: [String: Int]
        let terminalApp: [String: [String]]

        init(cols: Int) throws {
            let name = "claude-2.1.304-status-rows-\(cols)x40"
            let raw = try #require(Bundle.module.url(forResource: name, withExtension: "raw", subdirectory: "Fixtures"))
            let json = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
            struct Reference: Decodable {
                let cols: Int
                let rows: Int
                let marks: [String: Int]
                let terminalApp: [String: [String]]
            }
            let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: json))
            bytes = Array(try Data(contentsOf: raw))
            self.cols = reference.cols
            rows = reference.rows
            marks = reference.marks
            terminalApp = reference.terminalApp
        }

        func upTo(_ mark: String) -> [UInt8] { Array(bytes[0..<marks[mark]!]) }
    }

    static let moments = ["idle", "spinner", "permission"]

    /// The screen a `SessionParser` (on one end of a socket pair, as the host runs it) sends for `bytes`, as rows of
    /// cells: a wide character's second cell (NUL) a space, as on Terminal.app's screen; trailing blanks dropped.
    static func parsed(_ bytes: [UInt8], cols: Int, rows: Int) throws -> [String] {
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let (ours, its) = (fds[0], fds[1])
        // Ends when our end closes.
        Thread {
            SessionParser.run(fd: its, cols: cols, rows: rows, testHooks: false)
            close(its)
        }.start()
        defer { close(ours) }
        SessionParser.writeAll(ours, SessionParser.Wire.frame(SessionParser.ToParser.feed.rawValue, Data(bytes)))
        SessionParser.writeAll(ours, SessionParser.Wire.frame(SessionParser.ToParser.view.rawValue,
                                                               SessionParser.Wire.number(Int32(1)) + SessionParser.Wire.number(Int32(-1))))
        var reader = SessionParser.Wire.Reader()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(ours, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        while true {
            let count = read(ours, &buffer, buffer.count)
            try #require(count > 0, "the parser sent no view")
            reader.append(buffer[0..<count])
            while let (kind, payload) = reader.next() {
                guard kind == SessionParser.FromParser.view.rawValue else { continue }
                let view = try JSONDecoder().decode(ParserView.self, from: payload.dropFirst(4))
                return view.screen.replacingOccurrences(of: "\u{0}", with: " ").components(separatedBy: "\n")
                    .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            }
        }
    }

    @Test(arguments: [110, 160])
    func theParsersRowsAreTerminalAppsRows(cols: Int) throws {
        let capture = try Capture(cols: cols)
        for moment in Self.moments {
            let rows = try Self.parsed(capture.upTo(moment), cols: capture.cols, rows: capture.rows)
            let reference = try #require(capture.terminalApp[moment])
            #expect(rows.count == capture.rows, "\(cols) columns, \(moment)")
            for (index, (row, expected)) in zip(rows, reference).enumerated() {
                #expect(row == expected, "\(cols) columns, \(moment), row \(index)")
            }
        }
        // What the comparison looks at: the status line, the spinner row, the permission prompt.
        let idle = try Self.parsed(capture.upTo("idle"), cols: capture.cols, rows: capture.rows)
        #expect(idle.contains { $0.contains("[Opus 5.5]") && $0.contains("5 MCPs | ⏱️  12m") })
        #expect(idle.contains { $0.contains("⏸ manual mode on") })
        let spinner = try Self.parsed(capture.upTo("spinner"), cols: capture.cols, rows: capture.rows)
        #expect(spinner.contains { $0.hasSuffix("…") })
        let permission = try Self.parsed(capture.upTo("permission"), cols: capture.cols, rows: capture.rows)
        #expect(permission.contains(" Do you want to proceed?"))
    }

    /// A cell holding more than one scalar (an emoji with VS16, here written the way Claude writes its status line's
    /// emoji: a space where its second cell goes, then the emoji over it, then on past both) reads back as itself.
    @Test(arguments: [110, 160])
    func aClusterReadsBackAsItself(cols: Int) throws {
        let line = "\u{1B}[2;82H| \u{1B}[85G \u{1B}[84G\u{23F1}\u{FE0F}\u{1B}[86G 12m"
        let rows = try Self.parsed(Array(line.utf8), cols: cols, rows: 40)
        #expect(rows[1] == String(repeating: " ", count: 81) + "| ⏱️  12m")
        let terminal = Terminal(delegate: HeadlessDelegate(), options: TerminalOptions(cols: cols, rows: 40, scrollback: 0))
        terminal.feed(text: line)
        #expect(HostedSession.styledScreen(of: terminal).text.components(separatedBy: "\n")[1].contains("⏱️"))
    }
}
