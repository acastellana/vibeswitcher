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
        #expect(two.output.contains("  second test line") && !two.output.contains("first test line"), "\(two.output)")
        #expect(!two.output.contains("\u{1B}") && two.output.contains("third "), "inert: \(two.output)")
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
        try FileManager.default.removeItem(at: log)
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: elsewhere)
        let ran = try await node.run(["logs", "--sessions"])
        #expect(ran.status == 0 && !ran.output.contains("not the log") && ran.output.contains("couldn't be read"), "\(ran.output)")
    }
}
