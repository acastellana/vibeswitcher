import Foundation
import Testing
import VibeCore
@testable import VibeHost
@testable import VibeNode

/// A restored session's parser is rebuilt from the tail an attach is given (`HostedSession.restoredReplayLimit`), not
/// all of its output (the architecture review's row 19): what a client sees after a handover (the screen and the lines
/// the parser keeps above it) is byte for byte what it saw before, for a session with more than that limit of output
/// whose last reset is outside the tail, and one whose last reset is inside it; and a terminal query begun in the tail
/// and finished after the handover is still answered (the reply check reads the same tail the parser does).
@Suite(NodeTraits.linuxOnly)
struct HandoverReplayTests {
    private let scratch = Scratch()

    /// `count` lines, each drawn whole (its colour set and reset on it).
    static func lines(_ count: Int, from start: Int = 0) -> Data {
        var text = ""
        for index in start..<(start + count) {
            text += "\u{1B}[3\(index % 7 + 1)m\(String(format: "%07d", index))\u{1B}[0m the quick brown fox jumps over the lazy dog; step ok\n"
        }
        return Data(text.utf8)
    }

    /// The screen and the parser's lines above it, as a client asks for them.
    static func view(_ node: ScratchNode, _ id: UUID) async throws -> (history: String, screen: String) {
        let reply = try await offPool { [socket = node.socket] in
            try HostCall.request(.history(id: id, lines: SessionParser.scrollback), socket: socket, appKey: nil, timeout: 60)
        }
        guard case .historyText(_, let history, let screen) = reply else { throw HostCall.Failure(description: "no history: \(reply)") }
        return (history, screen)
    }

    @Test func whatAClientSeesIsTheSameAfterAHandover() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let reset = Data("\u{1B}c".utf8)
        // Over the 1 MiB limit after the reset: the tail starts at a line inside it.
        let outside = reset + Self.lines(30_000)
        // A reset inside the tail: the tail starts at it.
        let inside = Self.lines(30_000) + reset + Self.lines(300, from: 30_000)
        try #require(outside.count > HostedSession.restoredReplayLimit + 1_000_000 && inside.count > HostedSession.restoredReplayLimit)
        var sessions: [(UUID, String)] = []
        for (name, data) in [("outside", outside), ("inside", inside)] {
            let file = node.root.appendingPathComponent("\(name).txt")
            try data.write(to: file)
            let done = node.root.appendingPathComponent("\(name).done").path
            let session = try await node.spawn("cat \(file.path); touch \(done); exec sleep 600")
            sessions.append((session.id, done))
        }
        try #require(await eventually(timeout: 120) { sessions.allSatisfy { FileManager.default.fileExists(atPath: $0.1) } })
        var before: [(history: String, screen: String)] = []
        for (id, _) in sessions { before.append(try await Self.view(node, id)) }
        try await node.handOver()
        for (index, (id, _)) in sessions.enumerated() {
            let after = try await Self.view(node, id)
            #expect(after.screen == before[index].screen, "session \(index): the screen")
            #expect(after.history == before[index].history, "session \(index): the lines above it")
            #expect(!after.screen.isEmpty && !after.history.isEmpty)
        }
    }

    @Test func aQueryBegunInTheTailAndFinishedAfterTheHandoverIsAnswered() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let file = node.root.appendingPathComponent("big.txt")
        // Its last bytes begin a cursor position query (CSI 6 n) that the program finishes after the handover.
        try (Self.lines(30_000) + Data("\u{1B}[".utf8)).write(to: file)
        let half = node.root.appendingPathComponent("half").path, go = node.root.appendingPathComponent("go").path
        let got = node.root.appendingPathComponent("got").path
        _ = try await node.spawn("""
            stty raw -echo; cat \(file.path); touch \(half); while [ ! -f \(go) ]; do sleep 0.05; done; printf '6n'; \
            IFS= read -r -t 20 -d R reply; printf '%s' "$reply" > \(got).part; mv \(got).part \(got); exec sleep 600
            """)
        try #require(await eventually(timeout: 120) { FileManager.default.fileExists(atPath: half) })
        try await node.handOver()
        FileManager.default.createFile(atPath: go, contents: nil)
        try #require(await eventually(timeout: 60) { FileManager.default.fileExists(atPath: got) }, "\(node.said)")
        let reply = (try? String(contentsOfFile: got, encoding: .utf8)) ?? ""
        #expect(reply.contains("\u{1B}[") && reply.contains(";"), "the position report: \(reply.debugDescription)\n\(node.said)")
    }
}
