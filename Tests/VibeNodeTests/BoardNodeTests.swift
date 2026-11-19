import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// A lead's board end to end on a scratch node (the parity table's gap 4): a lead started as the user starts one, a
/// made-up board written where its tools write it; `vibeswitcher board FOLDER` prints it grouped, `--json` gives the
/// server's values, a folder with no lead is refused politely; and a page subscribed to `boards` gets the board in its
/// snapshot, then the next change of the file as a delta.
struct BoardNodeTests {
    private let scratch = Scratch()

    @Test func aLeadsBoardOnTheCommandLineAndThePage() async throws {
        let node = try await ScratchNode(scratch, holdFirstLook: true, hostArguments: LiveScratch.webArguments)
        defer { node.stop() }
        let repo = node.root.appendingPathComponent("example-app")
        try await scratchRepository(repo)
        try EngineEndToEndTests.workflow(repo)
        let head = Git.run(["rev-parse", "main"], in: repo.path).output
        try await node.acceptConfig(repo)
        try await node.acceptBase(repo, from: head)
        let started = try await node.runOnTerminal(["lead", repo.path, "--goal", "Ship the onboarding page"])
        try #require(started.status == 0, "the lead didn't start: \(started.output)\n\(node.said)")

        // The board as the lead's tools keep it, with the made-up tasks in it (its lead and questions as they are).
        let now = Date().timeIntervalSince1970
        var sample = WireVectors.sampleBoard(now: now)
        // Merged a moment ago, so it's today's whenever this runs.
        sample.tasks[4].merged?.at = now - 1
        sample.tasks[4].since = now - 1
        try BoardStore(root: repo.path).update { $0.tasks = sample.tasks }

        // The board is read when its folder changes: the command prints it once the node has.
        var printed: CommandRun?
        let deadline = MacTime.real.awake() + 60
        while MacTime.real.awake() < deadline {
            printed = try await node.run(["board", repo.path])
            if printed?.output.contains("Rewrite the pricing page's copy") == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try #require(printed?.output.contains("Rewrite the pricing page's copy") == true,
                     "the board never printed its tasks: \(printed?.output ?? "")\(printed?.errors ?? "")\n\(node.said)")
        let lines = try #require(printed?.output.split(separator: "\n").map(String.init))
        #expect(lines.contains("Needs attention") && lines.contains("Running") && lines.contains("Waiting") && lines.contains("Done today"), "\(lines)")
        #expect(lines.contains { $0.hasPrefix("  Blocked ") && $0.hasSuffix("— Which plan names do we launch with?") }, "\(lines)")
        #expect(lines.last == "1 needs attention · 2 running · 1 waiting · 1 done today", "\(lines)")

        let json = try await node.run(["board", repo.path, "--json"])
        let result = try #require(try JSONSerialization.jsonObject(with: Data(json.output.utf8)) as? [String: Any], "\(json.output)\(json.errors)")
        let boards = try #require(result["boards"] as? [[String: Any]])
        #expect(boards.count == 1 && boards.first?["project"] as? String == NodeIds.project(root: repo.resolvingSymlinksInPath().path), "\(boards)")

        let elsewhere = node.root.appendingPathComponent("no-lead-here")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let refused = try await node.run(["board", elsewhere.path])
        #expect(refused.status == 1 && refused.errors.contains("gone: no lead in") && refused.errors.contains("vibeswitcher lead"), "\(refused.errors)")

        // The page: the board in the snapshot, the next write a delta whose `prev` is the snapshot's `seq`.
        let opened = try LiveScratch.open(node)
        let socket = try LivePage(port: opened.port)
        _ = try socket.send("auth", ["pair": .string(opened.code), "client": .string("test")])
        let hello = try #require(try socket.next())
        #expect(hello["kinds"]?.array?.contains(.string("board")) == true, "\(hello)")
        let id = try socket.send("subscribe", ["sub": .string("b1"), "collection": .string("boards")])
        let replied = try #require(try socket.until { $0["re"]?.string == id }?.last)
        #expect(replied["result"]?["mode"]?.string == "snapshot", "\(replied)")
        let snapshot = try #require(try socket.until { $0["sub"]?.string == "b1" }?.last)
        let board = try #require(snapshot["entries"]?.array?.first?["value"], "\(snapshot)")
        #expect(board["tasks"]?.array?.count == 5, "\(board)")

        try BoardStore(root: repo.path).update { $0.tasks[0].status = .running; $0.tasks[0].blocker = nil }
        let moved = try #require(try socket.until { frame in
            frame["sub"]?.string == "b1" && frame["kind"]?.string == "delta"
                && frame["changes"]?.array?.first?["value"]?["tasks"]?.array?.first?["state"]?.string == "Working"
        }, "the change never came: \(node.said)")
        let first = try #require(moved.first { $0["kind"]?.string == "delta" })
        #expect(first["prev"]?.int == snapshot["seq"]?.int, "\(first)")
        #expect(socket.unsound.isEmpty, "\(socket.unsound)")
    }
}
