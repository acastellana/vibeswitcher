import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// A retry of a recorded action (the architecture review's row 10): the vault says it was recorded already, so it is
/// never done again; it is answered with the reply it got when this server kept it, and otherwise told honestly that
/// whether it was carried out isn't known (a server restarted since its record), never "done".
struct RecordedRetryTests {
    private let scratch = Scratch()

    @Test func aRetryAfterARestartIsToldTheOutcomeIsntKnown() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let action = UUID().uuidString.lowercased()
        let args: [String: NodeWire.Value] = ["folder": .string(world.repo), "do": .string("snooze")]
        let first = try #require(await world.ask("prompt-audit", args, action: action))
        #expect(first.ok, "\(first)")
        // The same server: the reply it kept.
        let kept = try #require(await world.ask("prompt-audit", args, action: action))
        #expect(kept.ok && kept.result == first.result, "\(kept)")
        // A server started since (no reply kept), on the same host and vault: recorded already, its outcome unknown.
        let restarted = Requests(link: world.world.link, sessions: nil, rule: CardWorld.rule, root: world.host.root,
                                 hostSocket: world.host.socket, commit: "test", hostPID: 1)
        restarted.engine = world.engine
        let reply = Locked<NodeWire.Reply?>(nil)
        let request = NodeWire.Request(id: "retry", kind: "prompt-audit", args: args, action: action)
        world.queue.async { restarted.handle(request, from: CardWorld.user) { reply.value = $0 } }
        #expect(await eventually(timeout: 120) { reply.value != nil })
        let again = try #require(reply.value)
        #expect(!again.ok && again.re == "retry" && again.error?.code == NodeWire.Code.refused.rawValue, "\(again)")
        #expect(again.error?.message == Requests.outcomeUnknown(action: action), "\(again)")
        #expect(await world.actions().filter { $0.action == action }.count == 1, "recorded once")
    }

    /// The command line's side: a state change whose server goes before it answers (killed here while the code is
    /// typed) says so, names its action id and that its outcome isn't known, and writes that to the journal.
    @Test(NodeTraits.linuxOnly)
    func aStateChangeWhoseServerWentSaysItsActionAndThatItsOutcomeIsntKnown() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let server = try #require(node.serverPID)
        let set = try await node.runOnTerminal(["set", "node_max_sessions", "7"]) { code in
            kill(server, SIGKILL)
            return code
        }
        let said = set.output + set.errors
        #expect(set.status != 0, "\(said)")
        #expect(said.contains("whether it was carried out isn't known") && said.contains("Action "), "\(said)\n\(node.said)")
        let action = try said.firstMatch(of: Regex("Action ([0-9a-f-]{36})"))?.output[1].substring.map(String.init)
        let entries = (try? String(contentsOf: node.testFolder.appendingPathComponent("journal.jsonl"), encoding: .utf8)) ?? ""
        #expect(action.map { id in entries.split(separator: "\n").contains { $0.contains("unanswered") && $0.contains(id) } } == true,
                "\(String(describing: action))\n\(entries)")
    }
}
