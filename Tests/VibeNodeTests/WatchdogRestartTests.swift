import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The watchdog acts (the architecture review's row 3): a scratch node's server whose engine queue is blocked for good
/// exits once its watchdog has waited `--test-stall=` seconds (120 on the user's node), the host starts it again, the
/// sessions run on in the host, and the freeze is in `health.json`, saved by the watchdog before the exit. Linux only, as
/// every `ScratchNode` suite: a scratch node's server child and its connector are Linux's (on the Mac the node never came
/// up, and the three cases were cancelled together at their time limit, v2 macos at e14045a0).
@Suite(NodeTraits.linuxOnly)
struct WatchdogRestartTests {
    private let scratch = Scratch()

    @Test func aServerWhoseQueueIsStuckExitsAndTheHostStartsItAgainWithTheSessionsKept() async throws {
        let node = try await ScratchNode(scratch, hostArguments: ["--server-arg", ServerArguments.testStallFlag + "3"])
        defer { node.stop() }
        let session = try await node.spawn("sleep 600")
        let old = try WireClient(node).hello.server.pid
        FileManager.default.createFile(atPath: node.root.appendingPathComponent("test-block-engine").path, contents: nil)
        var again: NodeWire.Hello?
        let back = await eventually(timeout: 120) {
            again = try? WireClient(node).hello
            return again.map { $0.server.pid != old } == true
        }
        try #require(back, "\(node.said)")
        #expect(node.said.contains("the engine's queue hasn't answered for"), "\(node.said)")
        #expect(node.said.contains("server child pid \(old) ended"), "\(node.said)")
        let kept = try node.sessions().first { $0.id == session.id }
        #expect(kept?.isLive == true && kept?.childPID == session.childPID, "\(String(describing: kept))")
        let freezes = NodeHealth(file: node.root.appendingPathComponent("health.json")).value(serverRestarts: nil, refusedConnections: nil,
                                                                                               hostRestartAt: nil, waiting: [])["freezes"]?.array ?? []
        #expect(freezes.contains { ($0["seconds"]?.int ?? 0) >= 3 }, "\(freezes)")
    }

    /// The refresh's lane blocked: said as a refresh under way in `status --health`; the server runs on. Its watchdog
    /// ends a server only after 60 s here: on a loaded machine (2 × cores of busy loops) the engine's queue itself can
    /// take a few seconds to answer, which is no stall this case is about.
    @Test func aBlockedRefreshIsSaidUnderWayAndTheServerRunsOn() async throws {
        let node = try await ScratchNode(scratch, hostArguments: ["--server-arg", ServerArguments.testStallFlag + "60"])
        defer { node.stop() }
        let old = try WireClient(node).hello.server.pid
        FileManager.default.createFile(atPath: node.root.appendingPathComponent("test-block-reads").path, contents: nil)
        var health = ""
        let deadline = MacTime.real.awake() + 60
        while !health.contains("refresh under way"), MacTime.real.awake() < deadline, !Task.isCancelled {
            health = try await node.run(["status", "--health"]).output
        }
        #expect(health.contains("refresh under way"), "\(health)\n\(node.said)")
        #expect(try WireClient(node).hello.server.pid == old, "\(node.said)")
    }

    /// A server stuck at every start: each stuck end ends what it started too (its process group, here its test child),
    /// the host counts them in a row, and past three the next server's `status` says so.
    @Test func aServerStuckAtEveryStartIsSaidAndEndsWhatItStarted() async throws {
        let folder = try scratch.shortFolder("vsw")
        let pids = folder.appendingPathComponent("child-pids")
        let child = folder.appendingPathComponent("child.sh")
        try ScratchNode.script("#!/bin/sh\necho $$ >>'\(pids.path)'\nexec sleep 600\n", at: child)
        let node = try await ScratchNode(scratch, testChild: child.path, hostArguments: ["--server-arg", ServerArguments.testStallFlag + "3"])
        defer { node.stop() }
        let childPID = { () -> [pid_t] in ((try? String(contentsOf: pids, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { pid_t($0) } }
        for round in 1...ServerChildStuck.rounds {
            let old = try WireClient(node).hello.server.pid
            try #require(await eventually(timeout: 60) { childPID().count >= round }, "round \(round): \(node.said)")
            let started = try #require(childPID().last)
            FileManager.default.createFile(atPath: node.root.appendingPathComponent("test-block-engine").path, contents: nil)
            let back = await eventually(timeout: 120) { (try? WireClient(node).hello.server.pid).map { $0 != old } == true }
            try #require(back, "round \(round): \(node.said)")
            #expect(await eventually(timeout: 30) { kill(started, 0) != 0 }, "round \(round): the stuck server's child \(started) runs on")
        }
        #expect(node.said.contains("(stuck: its engine's queue didn't answer; \(ServerChildStuck.rounds) in a row)"), "\(node.said)")
        var notices: [String] = []
        let said = await eventually(timeout: 60) { [node] in
            notices = (try? WireClient(node)).flatMap { client in WireClient.reply(client.request("status", action: nil))?.result?["notices"]?.array?.compactMap(\.string) } ?? []
            return notices.contains { $0.contains("the server ended stuck \(ServerChildStuck.rounds) times in a row") }
        }
        #expect(said, "\(notices)")
    }
}

/// How many stuck ends in a row the case makes: `Requests.stuckNoticeAfter`'s.
private enum ServerChildStuck {
    static let rounds = 3
}
