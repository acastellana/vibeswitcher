import Foundation
import Testing

/// Any process can post the app a distributed notification, a worker's Bash too, and none says who sent it: no
/// handler may read a session's screen and write it where the sender says (the `--screen` debug aid did, and went).
/// Scans the app's sources, so a handler that starts reading screens fails here.
struct DebugAidsLintTests {
    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/VibeSwitcher")

    /// What reads a session's screen: the host's copy, or a terminal view's lines.
    static let screenReads = ["hostClient.screen(", ".screen(session", "getTerminal()", "getLine(row:", "translateToString("]

    /// Each block that starts on a line containing `opening`, up to the line closing it at the same indentation.
    static func blocks(in text: String, opening: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var found: [String] = []
        for (index, line) in lines.enumerated() where line.contains(opening) {
            let indent = line.prefix { $0 == " " }
            let end = lines[(index + 1)...].firstIndex { $0 == indent + "}" } ?? lines.count - 1
            found.append(lines[index...end].joined(separator: "\n"))
        }
        return found
    }

    @Test func noNotificationHandlerReadsASessionsScreen() throws {
        let delegate = try String(contentsOf: Self.sources.appendingPathComponent("AppDelegate.swift"), encoding: .utf8)
        let handlers = Self.blocks(in: delegate, opening: "DistributedNotificationCenter.default().addObserver(")
        #expect(handlers.count >= 6, "found \(handlers.count) handlers: the scan no longer finds them")
        // The window capture a notification asks for, and what it writes beside the picture.
        let capture = Self.blocks(in: delegate, opening: "func captureWindows(")
        #expect(capture.count == 1)
        for block in handlers + capture {
            let reads = Self.screenReads.filter(block.contains)
            #expect(reads.isEmpty, "reads a screen (\(reads)) in:\n\(block)")
        }
    }

    @Test func theScreenAidIsGone() throws {
        let files = try #require(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            scanned += 1
            #expect(!text.contains("dev.vibeswitcher.screen"), "\(url.lastPathComponent) still names the screen notification")
            #expect(!text.contains("\"--screen\""), "\(url.lastPathComponent) still takes --screen")
        }
        #expect(scanned > 10)
    }

    @Test func theBlockScanFindsWhatItShould() {
        let sample = """
            center.addObserver(forName: x) { note in
                self.hostClient.screen(id) { _ in }
            }
            other()
        """
        let found = Self.blocks(in: sample, opening: "addObserver(")
        #expect(found.count == 1)
        #expect(Self.screenReads.contains(where: found[0].contains))
        #expect(!found[0].contains("other()"))
    }
}
