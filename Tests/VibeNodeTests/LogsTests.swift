import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// `vibeswitcher logs` (the parity table's Logs row): the host's session log's last lines and the node unit's journal,
/// read by the command line itself, printed inert, with where each is kept. Run on a `ScratchNode`.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct LogsTests {
    private let scratch = Scratch()

    @Test func theSessionLogsLastLinesAndWhereEachLogIs() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let log = node.root.appendingPathComponent("host.log")
        // The scratch host writes its own lines there too: these go after them, the last one with a terminal escape.
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("first test line\nsecond test line\nthird \u{1B}[2J line\n".utf8))
        try handle.close()

        let two = try await node.run(["logs", "--sessions", "--lines", "2"])
        #expect(two.status == 0, "\(two.output)\(two.errors)")
        // The host goes on writing its own lines (a connection its server makes while the command runs: the CI flake of
        // 2026-11-22), so the last two can be later than the test's: two consecutive lines of the log from the test's
        // second on, never its first, each inert.
        let said = two.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let header = said.firstIndex { $0.contains("its last 2 lines:") } ?? said.count
        let shown = said.dropFirst(header + 1).prefix(2).map { String($0.drop { $0 == " " }) }
        let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map { $0.replacingOccurrences(of: "\u{1B}", with: "�") }
        let tail = Array(lines.drop { !$0.hasPrefix("second test line") })
        let pairs = zip(tail, tail.dropFirst()).map { [$0, $1] }
        #expect(shown.count == 2 && !two.output.contains("first test line") && pairs.contains(shown), "\(shown) of \(tail)")
        #expect(!two.output.contains("\u{1B}"), "inert: \(two.output)")
        if shown.first == "second test line" { #expect(shown.last?.hasPrefix("third ") == true, "\(shown)") }
        #expect(two.output.contains("the host's session log: \(log.path)"), "\(two.output)")

        let server = try await node.run(["logs"])
        #expect(server.status == 0 && server.output.contains("the node unit's journal")
                && server.output.contains("`journalctl --user -u vibeswitcher-node.service`")
                && server.output.contains("`vibeswitcher logs --sessions`") && server.output.contains("`vibeswitcher status --health`"),
                "\(server.output)\(server.errors)")

        #expect(try await node.run(["logs", "--lines", "0"]).status == 64)
        #expect(try await node.run(["logs", "now"]).status == 64)
    }

    /// A log that isn't a file the command can read through no link is said so, not followed.
    @Test func aLinkInPlaceOfTheLogIsNotFollowed() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let log = node.root.appendingPathComponent("host.log")
        let elsewhere = scratch.url("elsewhere.txt")
        try "not the log\n".write(to: elsewhere, atomically: true, encoding: .utf8)
        // The link takes the log's place in one step (a rename over it): the host can write its log again between a
        // removal and a link made after it, and the link then fails with "file exists" (CI, 2026-11-24 and 11-25).
        let link = node.root.appendingPathComponent("host.log.link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        try #require(rename(link.path, log.path) == 0, "errno \(errno)")
        let ran = try await node.run(["logs", "--sessions"])
        #expect(ran.status == 0 && !ran.output.contains("not the log") && ran.output.contains("couldn't be read"), "\(ran.output)")
    }
}
