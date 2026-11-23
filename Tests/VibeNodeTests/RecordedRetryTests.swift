import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// A retry of a recorded action (the architecture review's row 10): the vault says it was recorded already, so it is
/// answered with the reply it got when this server kept it; otherwise from its record's outcome (done: the result;
/// failed: why); and a record begun with no outcome (its server ended in between) is done again when its kind leaves a
/// second act as one (`Requests.rerunnable`), else told it began and its outcome isn't known, never "done". Linux only:
/// the Mac's host keeps no record of the user's actions until a checked node start exists
/// (`HostImages.isCheckedMacNode`, docs/process/v2-mac-tasks.md items 13 and 14), so there every recorded request is
/// refused, by design, before it acts.
@Suite(NodeTraits.linuxOnly)
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

    /// The command line's side: its server killed while the code is typed (before the request is written): the request
    /// wasn't taken, so it goes to the host's next server, and is done there, once; nothing says its outcome isn't known.
    @Test(NodeTraits.linuxOnly)
    func aStateChangeWhoseServerWentBeforeItWasSentGoesToTheNextServer() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let server = try #require(node.serverPID)
        let set = try await node.runOnTerminal(["set", "node_max_sessions", "7"]) { code in
            kill(server, SIGKILL)
            return code
        }
        let said = set.output + set.errors
        #expect(set.status == 0 && said.contains("→ 7"), "\(said)\n\(node.said)")
        #expect(!said.contains("isn't known"), "\(said)")
    }

    /// Its server killed after the request was sent and recorded, before the act (held there): the command line sends it
    /// again on a fresh connection with the same action id; the next server finds it begun with no outcome, and `set`
    /// leaves things as one does, so it is done there; the user sees that one outcome.
    @Test(NodeTraits.linuxOnly)
    func aStateChangeLostAfterItWasSentIsAskedAgainWithItsActionID() async throws {
        let node = try await ScratchNode(scratch, hostArguments: ["--server-arg", ServerArguments.testStallFlag + "600"])
        defer { node.stop() }
        let hold = node.root.appendingPathComponent("test-hold-act").path
        _ = FileManager.default.createFile(atPath: hold, contents: nil)
        let running = Task { try await node.runOnTerminal(["set", "node_max_sessions", "7"]) }
        #expect(await eventually(timeout: 120) { node.said.contains("set (action ") && node.said.contains("recorded, and held for good") }, "\(node.said)")
        try await Self.killServer(node)
        let set = try await running.value
        let said = set.output + set.errors
        #expect(set.status == 0 && said.contains("→ 7"), "\(said)\n\(node.said)")
        #expect(!said.contains("isn't known"), "\(said)")
        #expect(node.said.contains("with no outcome recorded: done again"), "\(node.said)")
    }

    /// Its session host killed after the act and its outcome were recorded, before the reply (held there), and a new host
    /// started on the same root inside the command line's reconnect window: the vault went with the old host, so the
    /// request isn't sent to the new one (it would be done again); the user is told its outcome isn't known.
    @Test(NodeTraits.linuxOnly)
    func aStateChangeLostWithItsHostIsNotSentToTheNextHost() async throws {
        let node = try await ScratchNode(scratch, hostArguments: ["--server-arg", ServerArguments.testStallFlag + "600"])
        defer { node.stop() }
        _ = FileManager.default.createFile(atPath: node.root.appendingPathComponent("test-hold-reply").path, contents: nil)
        let running = Task { try await node.runOnTerminal(["set", "node_max_sessions", "7"]) }
        #expect(await eventually(timeout: 120) { node.said.contains("its reply held for good") }, "\(node.said)")
        let action = try #require(node.said.firstMatch(of: Regex("set \\(action ([0-9a-f-]{36})\\) done"))?.output[1].substring.map(String.init))
        let host = node.hostPID
        kill(host, SIGKILL)
        #expect(await eventually(timeout: 60) { kill(host, 0) != 0 || Self.isZombie(host) })
        let next = try await ScratchNode(scratch, reusing: node.root, hostArguments: ["--server-arg", ServerArguments.testStallFlag + "600"])
        defer { next.stop() }
        let set = try await running.value
        let said = set.output + set.errors
        #expect(set.status != 0 && said.contains("isn't known") && said.contains("session host restarted"), "\(said)\n\(next.said)")
        #expect(!next.said.contains(action), "the new host's server took the action again:\n\(next.said)")
    }

    /// The same, across a handover of the host (a build switch's): the host keeps its start and pid and carries the vault,
    /// so the request is sent again with its action id and answered from the carried record: done, not done again.
    @Test(NodeTraits.linuxOnly)
    func aStateChangeLostAcrossAHandoverIsAnsweredFromTheCarriedRecord() async throws {
        let node = try await ScratchNode(scratch, hostArguments: ["--server-arg", ServerArguments.testStallFlag + "600"])
        defer { node.stop() }
        let before = try WireClient(node).hello.host
        _ = FileManager.default.createFile(atPath: node.root.appendingPathComponent("test-hold-reply").path, contents: nil)
        let running = Task { try await node.runOnTerminal(["set", "node_max_sessions", "7"]) }
        #expect(await eventually(timeout: 120) { node.said.contains("its reply held for good") }, "\(node.said)")
        try await node.handOver()
        try await Self.killServer(node)
        let after = try WireClient(node).hello.host
        #expect(after.pid == before.pid && after.startedAt == before.startedAt, "\(before) → \(after)")
        let set = try await running.value
        let said = set.output + set.errors
        #expect(said.contains("was done at") && !said.contains("isn't known"), "\(said)\n\(node.said)")
        #expect(node.said.contains("answered from its record (done)"), "\(node.said)")
    }

    /// A resent `approve` while the first is still being done is told so, not that its batch is gone (taken by the first).
    @Test func aResentApproveWhileTheFirstRunsIsToldItIsBeingDone() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let action = UUID().uuidString.lowercased()
        let first = NodeWire.Request(id: "first", kind: "approve", args: ["batch": .string("b-gone")], action: action)
        world.queue.sync { world.requests.doing[action] = Requests.argsDigest(first) }
        let again = try #require(await world.ask("approve", ["batch": .string("b-gone")], action: action))
        #expect(again.error?.message == Requests.beingDoneNow(action: action), "\(again)")
        world.queue.sync { world.requests.doing[action] = nil }
    }

    /// The same action id with other arguments, on the same server: its kept reply isn't given (nor "being done"), as
    /// the vault's path says (`otherArguments`); with the first's arguments it is.
    @Test func aRetryWithOtherArgumentsIsGivenNothingFromMemory() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let action = UUID().uuidString.lowercased()
        let snooze: [String: NodeWire.Value] = ["folder": .string(world.repo), "do": .string("snooze")]
        let first = try #require(await world.ask("prompt-audit", snooze, action: action))
        #expect(first.ok, "\(first)")
        let same = try #require(await world.ask("prompt-audit", snooze, action: action))
        #expect(same.ok && same.result == first.result, "\(same)")
        let other = try #require(await world.ask("prompt-audit", ["folder": .string(world.repo), "do": .string("off")], action: action))
        #expect(!other.ok && other.error?.message == Requests.otherArguments(action: action), "\(other)")
        #expect(other.result == nil)
    }

    /// web.open's reply (its pairing link) isn't kept in memory past its answer: a retry by action id is told it was done
    /// and that its link went to the terminal that asked, never given the link; a kind whose result is kept keeps it.
    @Test func aLinkIsNotKeptInMemory() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let action = UUID().uuidString.lowercased()
        let open = NodeWire.Request(id: "open", kind: "web.open", args: [:], action: action)
        let given = NodeWire.Reply(re: "open", result: .object(["url": .string("http://127.0.0.1:1/#pair=SECRET-CODE")]))
        let kept = world.queue.sync { () -> NodeWire.Reply? in
            world.requests.keep(given, for: action, request: open)
            return world.requests.kept(NodeWire.Request(id: "again", kind: "web.open", args: [:], action: action), action: action)
        }
        #expect(kept.map { !"\($0)".contains("SECRET-CODE") } == true, "\(String(describing: kept))")
        #expect(kept?.error?.message.contains("its link went to the terminal that asked first") == true, "\(String(describing: kept))")
        #expect(world.queue.sync { world.requests.replies[action].map { !"\($0)".contains("SECRET-CODE") } } == true)
        let audit = UUID().uuidString.lowercased()
        let audited = NodeWire.Request(id: "a", kind: "prompt-audit", args: [:], action: audit)
        let result = NodeWire.Reply(re: "a", result: .object(["do": .string("snooze")]))
        world.queue.sync { world.requests.keep(result, for: audit, request: audited) }
        #expect(world.queue.sync { world.requests.kept(audited, action: audit)?.result } == result.result)
    }

    static func isZombie(_ pid: pid_t) -> Bool {
        ((try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8)) ?? "").split(separator: ")").last?.trimmingCharacters(in: .whitespaces).hasPrefix("Z") == true
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
    /// next is answered from the record (done; `set` keeps no result), not done again; asked with other arguments, given
    /// nothing.
    @Test(NodeTraits.linuxOnly)
    func aRetryAfterTheServerWasKilledIsAnsweredFromTheRecord() async throws {
        let node = try await ScratchNode(scratch, hostArguments: ["--server-arg", ServerArguments.testStallFlag + "600"])
        defer { node.stop() }
        let request = NodeWire.Request(id: "first", kind: "set", args: ["key": .string("node_max_sessions"), "value": .string("7")],
                                       action: UUID().uuidString.lowercased())
        let first = try await Self.voiced(node, request)
        #expect(first?.ok == true, "\(String(describing: first))\n\(node.said)")
        try await Self.killServer(node)
        // `set` keeps no result (a value can be a secret): the retry is told it was done, and given nothing of it.
        let again = try #require(try await Self.voiced(node, request), "\(node.said)")
        #expect(!again.ok && again.result == nil && again.error?.message.contains("was done at") == true, "\(again)")
        #expect(node.said.contains("answered from its record (done)"), "\(node.said)")
        // The same action id with other arguments: nothing of the record.
        var other = request
        other.args?["value"] = .string("9")
        let forged = try #require(try await Self.voiced(node, other), "\(node.said)")
        let action = try #require(request.action)
        #expect(!forged.ok && forged.error?.message == Requests.otherArguments(action: action), "\(forged)")
    }

    /// What the record keeps of a reply: a result only for a kind whose rule says it holds no secret.
    @Test func aResultIsRecordedOnlyForAKindWhoseRuleKeepsIt() {
        let link = NodeWire.Reply(re: "r", result: .object(["url": .string("http://127.0.0.1:1/#pair=SECRET")]))
        #expect(Requests.outcome(of: link, kind: "web.open").note == nil)
        #expect(Requests.outcome(of: link, kind: "answer").note == nil)
        #expect(Requests.outcome(of: link, kind: "no-such-kind").note == nil, "a kind with no rule keeps none")
        #expect(Requests.outcome(of: link, kind: "prompt-audit").note?.contains("SECRET") == true)
        let done = Requests.answer(.init(id: "x", kind: "web.open"), action: "a", outcome: Requests.outcome(of: link, kind: "web.open"))
        #expect(!done.ok && done.error?.message.contains("SECRET") == false && done.error?.message.contains("was done at") == true, "\(done)")
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
        // Begun, then the same setting changed by a later action: a retry would undo that, so it isn't done.
        let toggle = NodeWire.Request(id: "first", kind: "set", args: ["key": .string("node_max_sessions"), "value": .string("3")],
                                      action: UUID().uuidString.lowercased())
        _ = FileManager.default.createFile(atPath: node.root.appendingPathComponent("test-hold-act").path, contents: nil)
        let heldToggle = Task { try await Self.voiced(node, toggle) }
        #expect(await eventually(timeout: 120) { node.said.contains("set (action \(toggle.action ?? "-")) recorded, and held for good") }, "\(node.said)")
        try await Self.killServer(node)
        #expect(try await heldToggle.value == nil)
        let later = NodeWire.Request(id: "later", kind: "set", args: ["key": .string("node_max_sessions"), "value": .string("6")],
                                     action: UUID().uuidString.lowercased())
        #expect(try await Self.voiced(node, later)?.ok == true, "\(node.said)")
        let undone = try #require(try await Self.voiced(node, toggle), "\(node.said)")
        #expect(!undone.ok && undone.error?.message.contains("a later action changed the same thing") == true, "\(undone)")
        let sendAgain = try #require(try await Self.voiced(node, send), "\(node.said)")
        let message = sendAgain.error?.message ?? ""
        #expect(!sendAgain.ok && message.contains("began at") && message.contains("isn't known") && message.contains("the session's screen shows"),
                "\(sendAgain)")
        // Done again once, so its outcome is recorded now: a third ask, on the server after one more kill, is answered
        // from the record (done, `set` keeping no result), not done again.
        let third = try #require(try await Self.voiced(node, set), "\(node.said)")
        #expect(!third.ok && third.error?.message.contains("was done at") == true, "\(third)")
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
