import Foundation
import Testing
import VibeCore
import VibeNode

/// `vibeswitcher start` and the typed word (the engine plan's E1, EN-D5; the security architecture document's S1, S3
/// and S11), run as built against a scratch node, whose interop the test sets (`<root>/v2/test/binfmt_misc/`) and whose
/// journal is the recording stand-in.
@Suite(NodeTraits.linuxOnly)
struct StartCommandTests {
    private let scratch = Scratch()

    @Test func startRefusesWhileInteropIsOnUnlessTold() async throws {
        let node = try await ScratchNode(scratch)
        // `WSLInterop` off, as `echo 0 >` leaves it; `WSLInterop-late`, which WSL with systemd registers too, still on.
        try "enabled\ninterpreter /init\nflags: P\n".write(to: node.testFolder.appendingPathComponent("binfmt_misc/WSLInterop-late"),
                                                          atomically: true, encoding: .utf8)
        let refused = try await node.run(["start"])
        #expect(refused.status == 77, "\(refused.errors)")
        #expect(refused.errors.contains("WSL interop is on") && refused.errors.contains("--interop-is-on"), "\(refused.errors)")
        // Nothing reached the server.
        let quiet = try #require(WireClient.reply(try WireClient(node).request("status", action: nil))?.result)
        #expect(quiet["accepted"]?.array?.isEmpty == true)
        // Told, it goes on, and says interop is on.
        let told = try await node.runOnTerminal(["start", "--interop-is-on"])
        #expect(told.status == 0, "\(told.output)")
        #expect(told.output.contains("interop: on"), "\(told.output)")
        #expect(told.output.contains("the node runs"), "\(told.output)")
    }

    @Test func startPrintsTheNotPromisedListOnceAndRecordsTheAck() async throws {
        let node = try await ScratchNode(scratch)
        let first = try await node.runOnTerminal(["start"])
        #expect(first.status == 0, "\(first.output)")
        #expect(first.output.contains(NotPromised.heading), "\(first.output)")
        #expect(first.output.contains("1. While WSL interop is on"), "\(first.output)")
        #expect(first.output.contains("recorded: you read what plain mode doesn't promise"), "\(first.output)")
        let acks = node.recorder?.entries.filter { $0.event == NotPromised.ackEvent } ?? []
        #expect(acks.count == 1)
        #expect(acks.first.map { NodeJournal.passes($0, rule: VoiceRule(mode: .systemd, scopes: [.init(ScratchNode.ownScope ?? "/", basis: "t")],
                                                                          uid: getuid(), says: "")) } == true)
        // The second start prints nothing of it, and asks for nothing (no terminal needed).
        let second = try await node.run(["start"])
        #expect(second.status == 0, "\(second.errors)")
        #expect(!second.output.contains(NotPromised.heading), "\(second.output)")
        #expect(node.recorder?.entries.filter { $0.event == NotPromised.ackEvent }.count == 1)
    }

    @Test func aStateChangeWithNoTerminalIsRefused() async throws {
        let node = try await ScratchNode(scratch)
        // stdin from /dev/null, in a session of its own: no /dev/tty.
        let ran = try await run(URL(fileURLWithPath: "/usr/bin/setsid"), ["--wait", commandLine.path, "stop"], environment: node.environment())
        #expect(ran.status == 77, "\(ran.errors)")
        #expect(ran.errors.contains("needs a code typed on a terminal"), "\(ran.errors)")
        // The server got no stop: it runs, and accepted nothing.
        let status = try #require(WireClient.reply(try WireClient(node).request("status", action: nil))?.result)
        #expect(status["accepted"]?.array?.isEmpty == true)
        #expect(node.process.isRunning)
        // A wrong code typed: refused the same.
        let wrong = try await node.runOnTerminal(["stop"]) { _ in "ZZZZ" }
        #expect(wrong.status == 77, "\(wrong.output)")
        #expect(node.process.isRunning)
        // With a terminal and the right code, it goes.
        let typed = try await node.runOnTerminal(["stop"])
        #expect(typed.status == 0, "\(typed.output)")
        #expect(await exited(node.process, within: 60), "\(node.said)")
    }
}
