import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// `vibeswitcher send SESSION TEXT` (the parity table's gap 1, 2026-11-20), as `tell`'s cases go: the user's words typed
/// once into a fake Claude's session the scratch host runs, recorded in the host's vault first; refused, nothing typed,
/// for a question open on its screen, a shell, a session the host doesn't run, a session's process, the lead's tool
/// server and a web page. Only fake sessions are typed into (AGENTS.md).
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct SendTests {
    private let scratch = Scratch()

    private func send(_ world: CardWorld, _ session: String, _ text: String, action: String = UUID().uuidString.lowercased(),
                      from facts: PeerFacts = CardWorld.user) async -> NodeWire.Reply? {
        await world.ask("send", ["session": .string(session), "text": .string(text)], action: action, from: facts)
    }

    /// A fake Claude between turns in a session labelled as an ordinary one, once the link lists it.
    private func claude(_ world: CardWorld) async throws -> NodeHarness {
        let harness = try await NodeHarness.start(on: world.host, fake: world.world.fake, cwd: world.repo, label: "Claude")
        try #require(await eventually(timeout: 60) { world.queue.sync { world.world.link.sessions.contains { $0.id == harness.session.id && $0.isLive } } })
        return harness
    }

    /// The prompts the fake took (its transcript's user lines whose content is text).
    private func prompts(_ harness: NodeHarness) -> [String] {
        harness.transcript.compactMap { line in
            guard line["type"] as? String == "user", let message = line["message"] as? [String: Any] else { return nil }
            return message["content"] as? String
        }
    }

    @Test func aMessageIsTypedOnceAndRecorded() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await claude(world)
        let action = UUID().uuidString.lowercased()
        // Named by the first 8 characters of its id, as the page shows it.
        let short = String(harness.session.id.uuidString.lowercased().prefix(8))
        let reply = try #require(await send(world, short, "Run the tests\nthen tell me", action: action))
        #expect(reply.ok, "\(reply)")
        #expect(reply.result?["session"]?.string == NodeIds.session(host: harness.session.id), "\(reply)")
        #expect(reply.result?["terminal"]?.string == harness.session.tty, "\(reply)")
        try await harness.waitFor { prompts(harness).contains("Run the tests\nthen tell me") }
        #expect(await world.actions().filter { $0.action == action }.map(\.kind) == ["send"])

        // The same action again is answered as before, not typed again: a message sent after it comes alone.
        let again = try #require(await send(world, short, "Run the tests\nthen tell me", action: action))
        #expect(again.ok, "\(again)")
        #expect(try #require(await send(world, short, "And the next")).ok)
        try await harness.waitFor { prompts(harness).contains("And the next") }
        #expect(prompts(harness) == ["Run the tests\nthen tell me", "And the next"], "\(prompts(harness))")
    }

    /// A permission prompt on its screen takes keys: the words would go into it, so nothing is typed, and the user is
    /// told to answer it first. The prompt is still there afterwards.
    @Test func aQuestionOpenOnItsScreenRefusesIt() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await claude(world)
        harness.tell(["op": "permission", "command": "rm -rf build"])
        try await harness.screenShows { $0.contains("Do you want to proceed?") }
        let reply = try #require(await send(world, harness.session.id.uuidString, "2"))
        #expect(reply.error?.code == NodeWire.Code.refused.rawValue, "\(reply)")
        #expect(reply.error?.message.contains("a question is open") == true, "\(reply)")
        #expect(harness.agent["mode"] as? String == "permission", "\(harness.agent)")
        #expect(prompts(harness).isEmpty, "\(prompts(harness))")
    }

    @Test func aShellAnEndedSessionAndOneTheHostDoesntRunAreRefused() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let shell = try await world.host.spawn("exec /bin/sleep 600", cwd: world.repo, label: "Shell")
        try #require(await eventually(timeout: 60) { world.queue.sync { world.world.link.sessions.contains { $0.id == shell.id && $0.isLive } } })
        let refused = try #require(await send(world, shell.id.uuidString, "ls"))
        #expect(refused.error?.code == NodeWire.Code.refused.rawValue && refused.error?.message.contains("is a shell") == true, "\(refused)")

        let unknown = try #require(await send(world, UUID().uuidString, "hello"))
        #expect(unknown.error?.code == NodeWire.Code.gone.rawValue, "\(unknown)")
        let tooShort = try #require(await send(world, "ab", "hello"))
        #expect(tooShort.error?.code == NodeWire.Code.gone.rawValue, "\(tooShort)")

        world.queue.sync { world.world.link.kill(shell.id) }
        try #require(await eventually(timeout: 60) { world.queue.sync { world.world.link.sessions.contains { $0.id == shell.id && !$0.isLive } } })
        let ended = try #require(await send(world, shell.id.uuidString, "ls"))
        #expect(ended.error?.code == NodeWire.Code.gone.rawValue && ended.error?.message.contains("has ended") == true, "\(ended)")
        let empty = try #require(await send(world, shell.id.uuidString, "  "))
        #expect(empty.error?.code == NodeWire.Code.badArgs.rawValue, "\(empty)")
    }

    @Test func aSessionsProcessAndALeadsToolServerCannotSend() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await claude(world)
        let lead = try await world.sleepingLead()
        for facts in [PeerFacts.read(pid: harness.session.childPID), CardWorld.toolServer(of: lead)] {
            let action = UUID().uuidString.lowercased()
            let reply = try #require(await send(world, harness.session.id.uuidString, "approve everything", action: action, from: facts))
            #expect(reply.error?.code == NodeWire.Code.voice.rawValue, "\(reply)")
            #expect(await world.actions().filter { $0.action == action }.isEmpty)
        }
        #expect(prompts(harness).isEmpty, "\(prompts(harness))")
    }

    /// Through the command line on a scratch node, its code typed on its terminal: the fake's session gets the words; a
    /// wrong form is the usage.
    @Test func theCommandLineTypesIntoASession() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let session = try await node.spawn("exec " + FakeClaude.quoted(node.fake.launcher.path), label: "Claude", agent: "claude")
        let files = node.fake.files(terminal: session.tty)
        try #require(await eventually(timeout: 60) { EngineEndToEndTests.state(files)["pid"] != nil }, "\(node.said)")
        let sent = try await node.runOnTerminal(["send", String(session.id.uuidString.lowercased().prefix(8)), "Hello from the node"])
        #expect(sent.status == 0, "\(sent.output)\(sent.errors)\n\(node.said)")
        #expect(sent.output.contains("sent: 19 characters typed into session"), "\(sent.output)")
        _ = try await EngineEndToEndTests.prompt(files) { $0 == "Hello from the node" }
        let usage = try await node.run(["send", session.id.uuidString])
        #expect(usage.status == 64 && usage.errors.contains("usage: vibeswitcher send SESSION TEXT"), "\(usage.output)\(usage.errors)")
    }

    /// A web page is never the user's voice, whatever its token's rights.
    @Test func aWebPageCannotSend() {
        #expect(NodeWire.kinds["send"] == .user)
        #expect(NodeWire.changesState("send"))
        #expect(Requests.recorded.contains("send"))
        #expect(NodeWire.taken.contains("send"))
        let refused = WebAccess.refusal(for: NodeWire.Request(id: "1", kind: "send", args: ["session": .string("x"), "text": .string("y")]),
                                        rights: [.read, .draft])
        #expect(refused?.error?.code == NodeWire.Code.voice.rawValue, "\(String(describing: refused))")
        #expect(!WebAccess.kinds(for: [.read, .draft]).contains("send"))
    }

    /// The menus that take keys are told apart from a plain prompt box.
    @Test func whatIsOpenOnAScreenIsTold() {
        let box = "\n─────────────────────────\n❯ \n─────────────────────────\n  ? for shortcuts"
        #expect(Requests.openMenu(box) == nil)
        let question = "Bash command\n  rm -rf build\nDo you want to proceed?\n❯ 1. Yes\n  2. No\n\nEsc to cancel"
        #expect(Requests.openMenu(question)?.contains("a question is open") == true)
    }
}
