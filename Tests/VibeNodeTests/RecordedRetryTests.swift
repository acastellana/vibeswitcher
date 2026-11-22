import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// A retry of a recorded action (the architecture review's row 10): the vault says it was recorded already, so it is
/// answered with the reply it got when this server kept it; otherwise from its record's outcome (done: the result;
/// failed: why); and a record begun with no outcome (its server ended in between) is done again when its kind leaves a
/// second act as one (`Requests.rerunnable`), else told it began and its outcome isn't known, never "done".
struct RecordedRetryTests {
    private let scratch = Scratch()

    /// A server started since (no reply kept), on the same host and vault: answered from the record's outcome, the
    /// result the first got, and not done again.
    @Test func aRetryAfterARestartIsAnsweredFromTheRecord() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let action = UUID().uuidString.lowercased()
        let args: [String: NodeWire.Value] = ["folder": .string(world.repo), "do": .string("snooze")]
        let first = try #require(await world.ask("prompt-audit", args, action: action))
        #expect(first.ok, "\(first)")
        // The same server: the reply it kept.
        let kept = try #require(await world.ask("prompt-audit", args, action: action))
        #expect(kept.ok && kept.result == first.result, "\(kept)")
        // A server started since (no reply kept), on the same host and vault: recorded already, done, its result.
        let restarted = Requests(link: world.world.link, sessions: nil, rule: CardWorld.rule, root: world.host.root,
                                 hostSocket: world.host.socket, commit: "test", hostPID: 1)
        restarted.engine = world.engine
        let reply = Locked<NodeWire.Reply?>(nil)
        let request = NodeWire.Request(id: "retry", kind: "prompt-audit", args: args, action: action)
        world.queue.async { restarted.handle(request, from: CardWorld.user) { reply.value = $0 } }
        #expect(await eventually(timeout: 120) { reply.value != nil })
        let again = try #require(reply.value)
        #expect(again.ok && again.re == "retry" && again.result == first.result, "\(again)")
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

    /// The record's side: an outcome kept on its action's record once (the first stands); the record read by this build
    /// from a build before outcomes (begun), and by such a build from this one (the outcome passed over, the rest kept),
    /// as a handover from an older host and back carries it.
    @Test func theRecordKeepsAnOutcomeOnceAndReadsAcrossBuilds() throws {
        var book: LeadVaultV2.Book?
        func ask(_ request: LeadVaultV2.Request) -> LeadVaultV2.Reply { LeadVaultV2.answer(request, from: .app, book: &book, now: 100, on: true) }
        #expect(ask(.recordUserAction(action: "a1", kind: "set", subject: nil, digest: "d")) == .recorded(first: true))
        #expect(ask(.userAction(action: "a1", kind: "set")) == .actions([.init(action: "a1", kind: "set", subject: nil, digest: "d", at: 100)]))
        #expect(ask(.userAction(action: "a1", kind: "send")) == .actions([]))
        let done = LeadVaultV2.UserAction.Outcome(done: true, note: #"{"key":"k"}"#, at: 101)
        #expect(ask(.finishUserAction(action: "a1", kind: "set", outcome: done)) == .ok)
        #expect(ask(.finishUserAction(action: "a1", kind: "set", outcome: .init(done: false, note: "later", at: 102))) == .ok)
        #expect(ask(.userAction(action: "a1", kind: "set")) == .actions([.init(action: "a1", kind: "set", subject: nil, digest: "d", at: 100, outcome: done)]))
        #expect(ask(.finishUserAction(action: "a2", kind: "set", outcome: done)) == .refused("No action a2 of set is recorded."))
        // A failure's why is cut, a done act's long answer not kept.
        #expect(LeadVaultV2.UserAction.Outcome(done: false, note: String(repeating: "é", count: 400)).note?.utf8.count == LeadVaultV2.outcomeBytes)
        #expect(LeadVaultV2.UserAction.Outcome(done: true, note: String(repeating: "x", count: 600)).note == nil)

        // A build before outcomes wrote its records with five fields: read here as begun.
        let old = Data(#"{"actions":[{"action":"a3","kind":"send","digest":"d3","at":12.5}],"seals":{}}"#.utf8)
        let read = try JSONDecoder().decode(LeadVaultV2.Book.self, from: old)
        #expect(read.actions == [.init(action: "a3", kind: "send", subject: nil, digest: "d3", at: 12.5)])
        // Such a build reads this one's record (its own `UserAction`, synthesized): the outcome passed over, the rest kept.
        struct OldAction: Codable, Equatable { var action: String; var kind: String; var subject: String?; var digest: String; var at: Double }
        struct OldBook: Codable { var actions: [OldAction] }
        let older = try JSONDecoder().decode(OldBook.self, from: JSONEncoder().encode(try #require(book)))
        #expect(older.actions == [OldAction(action: "a1", kind: "set", subject: nil, digest: "d", at: 100)])
        // And back: what it writes reads here as begun.
        let back = try JSONDecoder().decode(LeadVaultV2.Book.self, from: JSONEncoder().encode(older))
        #expect(back.actions.first?.outcome == nil && back.actions.first?.digest == "d")
        // The vault's whole state, as a handover hands it over, keeps the outcome.
        let restored = LeadVault.Book(restoring: LeadVault.Book(restoring: nil).serialized)
        _ = restored.v2 { $0 = book; return true }
        let handedOver = LeadVault.Book(restoring: restored.serialized)
        #expect(handedOver.v2 { $0?.actions.first?.outcome } == done)
    }

    /// Done: the act's reply was given, so its outcome was in the record first; the server killed, and the retry on the
    /// next is answered with the recorded result, not done again.
    @Test(NodeTraits.linuxOnly)
    func aRetryAfterTheServerWasKilledIsAnsweredWithTheRecordedResult() async throws {
        let node = try await ScratchNode(scratch, hostArguments: ["--server-arg", ServerArguments.testStallFlag + "600"])
        defer { node.stop() }
        let request = NodeWire.Request(id: "first", kind: "set", args: ["key": .string("node_max_sessions"), "value": .string("7")],
                                       action: UUID().uuidString.lowercased())
        let first = try await Self.voiced(node, request)
        #expect(first?.ok == true, "\(String(describing: first))\n\(node.said)")
        try await Self.killServer(node)
        let again = try await Self.voiced(node, request)
        #expect(again?.ok == true && again?.result == first?.result, "\(String(describing: again))\n\(node.said)")
        #expect(node.said.contains("answered from its record (done)"), "\(node.said)")
    }

    /// Failed: the retry on the next server is told the failure, under its code, and that a new attempt is allowed.
    @Test(NodeTraits.linuxOnly)
    func aRetryOfAFailedActionAfterTheServerWasKilledIsToldTheFailure() async throws {
        let node = try await ScratchNode(scratch, hostArguments: ["--server-arg", ServerArguments.testStallFlag + "600"])
        defer { node.stop() }
        let request = NodeWire.Request(id: "first", kind: "set", args: ["key": .string("no_such_setting"), "value": .string("1")],
                                       action: UUID().uuidString.lowercased())
        let first = try #require(try await Self.voiced(node, request), "\(node.said)")
        #expect(!first.ok, "\(first)")
        try await Self.killServer(node)
        let again = try #require(try await Self.voiced(node, request), "\(node.said)")
        let message = again.error?.message ?? ""
        #expect(!again.ok && again.error?.code == first.error?.code, "\(again)")
        #expect(message.contains("failed at") && message.contains(first.error?.message ?? "-") && message.contains("running the command again is a new attempt"),
                "\(again)")
    }

    /// Begun, no outcome (the server killed between the record and the act): a kind a second act leaves as one (`set`)
    /// is done on the retry; one that isn't (`send`) is told it began, that its outcome isn't known, and what to look at.
    @Test(NodeTraits.linuxOnly)
    func aRetryOfAnActionBegunWhenTheServerWasKilledIsDoneAgainOnlyWhenThatIsSafe() async throws {
        let node = try await ScratchNode(scratch, hostArguments: ["--server-arg", ServerArguments.testStallFlag + "600"])
        defer { node.stop() }
        let set = NodeWire.Request(id: "first", kind: "set", args: ["key": .string("node_max_sessions"), "value": .string("5")],
                                   action: UUID().uuidString.lowercased())
        let send = NodeWire.Request(id: "first", kind: "send", args: ["session": .string(UUID().uuidString), "text": .string("hello")],
                                    action: UUID().uuidString.lowercased())
        for request in [set, send] {
            let hold = node.root.appendingPathComponent("test-hold-act").path
            FileManager.default.createFile(atPath: hold, contents: nil)
            let held = Task { try await Self.voiced(node, request) }
            let marked = "\(request.kind) (action \(try #require(request.action))) recorded, and held for good"
            #expect(await eventually(timeout: 120) { node.said.contains(marked) }, "\(node.said)")
            try await Self.killServer(node)
            #expect(try await held.value == nil, "no answer from the killed server")
        }
        let setAgain = try #require(try await Self.voiced(node, set), "\(node.said)")
        #expect(setAgain.ok && setAgain.result?["value"]?.string == "5", "\(setAgain)")
        #expect(node.said.contains("with no outcome recorded: done again"), "\(node.said)")
        let sendAgain = try #require(try await Self.voiced(node, send), "\(node.said)")
        let message = sendAgain.error?.message ?? ""
        #expect(!sendAgain.ok && message.contains("began at") && message.contains("isn't known") && message.contains("the session's screen shows"),
                "\(sendAgain)")
        // Done again once, so its outcome is recorded now: a third ask is answered from the record, the same.
        let third = try #require(try await Self.voiced(node, set), "\(node.said)")
        #expect(third.ok && third.result == setAgain.result, "\(third)")
    }

    /// Kills the node's server and waits until the host's next one answers its socket.
    static func killServer(_ node: ScratchNode) async throws {
        let old = try #require(node.serverPID, "\(node.said)")
        kill(old, SIGKILL)
        let back = await eventually(timeout: 120) {
            guard let now = node.serverPID, now != old else { return false }
            return (try? WireClient(node, timeout: 2))?.hello.server.pid == now
        }
        try #require(back, "\(node.said)")
    }

    /// `request` sent as the user's (from a process on a terminal, as the command line is), asked again while the
    /// server's link isn't welcomed (`not-yet`): its reply, or nil when the connection closed first.
    static func voiced(_ node: ScratchNode, _ request: NodeWire.Request) async throws -> NodeWire.Reply? {
        let line = String(decoding: NodeWire.line(request).dropLast(), as: UTF8.self)
        let sender = """
            import json, socket, sys, time
            s = socket.socket(socket.AF_UNIX)
            s.connect(sys.argv[1])
            f = s.makefile("rwb")
            f.readline()
            deadline = time.monotonic() + 60
            while True:
                f.write(sys.argv[2].encode() + b"\\n"); f.flush()
                reply = f.readline()
                if not reply: sys.exit(3)
                if (json.loads(reply).get("error") or {}).get("code") == "not-yet" and time.monotonic() < deadline:
                    time.sleep(0.25); continue
                sys.stdout.write("REPLY " + reply.decode()); sys.exit(0)
            """
        let run = try await ScratchNodes.onTerminal("/usr/bin/python3", ["-I", "-c", sender, node.serverSocket, line],
                                                    environment: node.environment(), answer: { _ in nil })
        guard let at = run.output.range(of: "REPLY ") else { return nil }
        let reply = run.output[at.upperBound...].prefix { $0 != "\n" && $0 != "\r" }
        return NodeWire.decode(NodeWire.Reply.self, Data(reply.utf8))
    }
}
