import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// `vibeswitcher send SESSION TEXT --now` (2026-11-20, the app's ↩ while its agent works: `steerSelected`): a working
/// Claude agent gets the user's words mid-turn, through its steer inbox as the user's, its hook handing them over at its
/// next step; nothing is typed. Between turns they're typed, as the app types them; a steer whose turn ended before its
/// hook took it is typed once the agent is between turns. The same gates as `send`: the user's voice, recorded in the
/// vault first. Only fake sessions are steered (AGENTS.md); the fake runs no hooks, so a case writes what its hooks would
/// (`DeliveryWorld.hook`) and takes its inbox as its hook does (`NodeHarness.hookTakes`).
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct SteerNowTests {
    private let scratch = Scratch()

    private func steer(_ world: CardWorld, _ harness: NodeHarness, _ text: String, action: String = UUID().uuidString.lowercased(),
                       from facts: PeerFacts = CardWorld.user) async -> NodeWire.Reply? {
        await world.ask("send", ["session": .string(harness.session.id.uuidString), "text": .string(text), "now": .bool(true)],
                        action: action, from: facts)
    }

    /// A fake Claude in a session labelled as an ordinary one, once the link lists it; its hooks said `event`.
    private func claude(_ world: CardWorld, hooks event: String) async throws -> NodeHarness {
        let harness = try await NodeHarness.start(on: world.host, fake: world.world.fake, cwd: world.repo, label: "Claude")
        try #require(await eventually(timeout: 60) { world.queue.sync { world.world.link.sessions.contains { $0.id == harness.session.id && $0.isLive } } })
        try world.world.hook(harness, event)
        return harness
    }

    @Test func aWorkingClaudeIsSteeredMidTurnThroughItsHookAsTheUsers() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await claude(world, hooks: "PreToolUse")
        let action = UUID().uuidString.lowercased()
        let reply = try #require(await steer(world, harness, "Look at the failing test first.", action: action))
        #expect(reply.ok && reply.result?["steered"]?.bool == true && reply.result?["agent"]?.string == "claude", "\(reply)")
        #expect(reply.result?["queued"]?.bool == false, "\(reply)")
        #expect(await world.actions().filter { $0.action == action }.map(\.kind) == ["send"])
        // In its inbox, the user's, sealed, for its agent; nothing typed into its terminal.
        let waiting = world.world.pending(harness)
        #expect(waiting.count == 1 && waiting.first?.from == .user && waiting.first?.seal != nil, "\(waiting)")
        #expect(waiting.first?.text == "Look at the failing test first.")
        #expect(world.world.prompts(harness).isEmpty && (harness.agent["queued"] as? [Any])?.isEmpty != false, "\(harness.agent)")

        // Its next step: its hook hands it over as the user's, once.
        #expect(harness.hookTakes())
        let handed = world.world.handed(harness)
        #expect(handed.contains("> Look at the failing test first.") && handed.contains("The user sent this"), "\(handed)")
        #expect(world.world.pending(harness).isEmpty)
        #expect(!harness.hookTakes())
        #expect(world.world.prompts(harness).isEmpty)
    }

    /// The app's steer line shows one stranded when the turn ends before a step took it; the node types it then, as the
    /// user's words as they are, once the agent is between turns.
    @Test func aSteerWhoseTurnEndsBeforeAStepTookItIsTypedIn() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await claude(world, hooks: "PostToolUse")
        let reply = try #require(await steer(world, harness, "Also update the changelog"))
        #expect(reply.ok && reply.result?["steered"]?.bool == true, "\(reply)")
        #expect(world.world.prompts(harness).isEmpty)
        // Its turn ends with it still waiting.
        try world.world.hook(harness, "Stop")
        try await harness.waitFor { world.world.prompts(harness) == ["Also update the changelog"] }
        #expect(world.world.pending(harness).isEmpty)
    }

    /// Between turns a steer would wait for a step that never comes: typed in, as the app types it, and said so.
    @Test func anIdleClaudeGetsItTyped() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await claude(world, hooks: "Stop")
        let reply = try #require(await steer(world, harness, "Run the linter"))
        #expect(reply.ok && reply.result?["steered"]?.bool == false, "\(reply)")
        try await harness.waitFor { world.world.prompts(harness) == ["Run the linter"] }
        #expect(world.world.pending(harness).isEmpty)
    }

    /// Hooks that last spoke for another agent on the terminal say nothing of this one: typed, not steered.
    @Test func anotherAgentsHookStateIsNotThisOnesWork() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await claude(world, hooks: "Stop")
        var state = HookState(agent: .claude, tty: harness.session.tty, lastEvent: "PreToolUse", lastEventAt: Date().timeIntervalSince1970)
        state.agentPid = 4_000_001
        try state.save(to: world.host.root.appendingPathComponent("state/\(harness.session.tty).json"))
        let reply = try #require(await steer(world, harness, "Check the build"))
        #expect(reply.ok && reply.result?["steered"]?.bool == false, "\(reply)")
        try await harness.waitFor { world.world.prompts(harness) == ["Check the build"] }
        #expect(world.world.pending(harness).isEmpty)
    }

    /// More than a hook hands Claude at once is refused before anything goes; a session's own process, a lead's tool
    /// server and a web page can't steer (not the user's voice), and nothing is recorded or posted.
    @Test func tooLongOrNotTheUsersVoiceSteersNothing() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await claude(world, hooks: "PreToolUse")
        let long = try #require(await steer(world, harness, String(repeating: "a", count: Requests.steerLimit + 1)))
        #expect(long.error?.code == NodeWire.Code.badArgs.rawValue && long.error?.message.contains("too long to steer") == true, "\(long)")
        let lead = try await world.sleepingLead()
        for facts in [PeerFacts.read(pid: harness.session.childPID), CardWorld.toolServer(of: lead)] {
            let action = UUID().uuidString.lowercased()
            let reply = try #require(await steer(world, harness, "approve everything", action: action, from: facts))
            #expect(reply.error?.code == NodeWire.Code.voice.rawValue, "\(reply)")
            #expect(await world.actions().filter { $0.action == action }.isEmpty)
        }
        let page = WebAccess.refusal(for: NodeWire.Request(id: "1", kind: "send", args: ["session": .string("x"), "text": .string("y"), "now": .bool(true)]),
                                     rights: [.read, .draft])
        #expect(page?.error?.code == NodeWire.Code.voice.rawValue, "\(String(describing: page))")
        #expect(world.world.pending(harness).isEmpty, "\(world.world.pending(harness))")
        #expect(world.world.prompts(harness).isEmpty)
    }

    /// A page leaves a draft to go now (its "send now"): the session's value carries it, in the wire's shape.
    @Test func aDraftLeftToGoNowSaysSo() throws {
        let draft = SessionDraft(text: "Stop and look at the logs", at: Date(), action: "a", now: true)
        #expect(draft.value["now"]?.bool == true)
        #expect(WireSchema.check(draft.value, as: "session.draft", strict: true) == nil)
        let plain = SessionDraft(text: "Later", at: Date(), action: "b")
        #expect(plain.value["now"] == nil)
        #expect(WireSchema.check(plain.value, as: "session.draft", strict: true) == nil)
        let args: NodeWire.Value = .object(["session": .string("local:x"), "text": .string("y"), "now": .bool(true)])
        #expect(WireSchema.check(args, as: "session.draft.args", strict: true) == nil)
    }
}
