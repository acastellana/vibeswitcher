import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// Delivering to a project's lead (the engine plan's E5, EN-D9, EN-D14), on a scratch host in the test process with
/// `FakeClaude` as the lead (`DeliveryWorld`): the app's `ReplacedLeadRoutingTests` and `SteerInboxReadOffMainTests`
/// cases restated on the engine ("off the main thread" is off the engine's queue), and the node's own: a message goes
/// to the lead the vault binds while the board names it and its agent runs; otherwise it's held, in order, at rest.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(10)))
struct DeliveryTests {
    private let scratch = Scratch()

    /// The session `harness` runs in has ended, as the link has it.
    private func ended(_ harness: NodeHarness, in world: DeliveryWorld) async -> Bool {
        await eventually(timeout: 120) { world.queue.sync { world.link.sessions.first { $0.id == harness.session.id }?.isLive == false } }
    }

    @Test func aMessageForALeadThatIsntRunningIsHeldAndGoesOnceOneRuns() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        let first = try await world.lead(idle: false)
        #expect(await world.deliver("The worker on parser says it's done.", from: .system("witness")) == true)
        #expect(world.pending(first).map(\.text) == ["The worker on parser says it's done."])

        // The lead's agent ends (a restart under way): the board still names it, but it doesn't run.
        first.tell(["op": "exit"])
        #expect(await ended(first, in: world))
        #expect(await world.deliver("The worker on lexer is blocked.", from: .system("witness")) == false)
        #expect(world.held().map(\.text) == ["The worker on lexer is blocked."])
        #expect(world.stored?.held == 1)
        // At rest, for a restarted server (EN-D9).
        #expect(await eventually(timeout: 60) { EngineState.load(root: world.host.root).state.held.map(\.text) == ["The worker on lexer is blocked."] })

        // A lead runs again: what was held goes to it at the next look, and is held no more.
        let second = try await world.lead(idle: false)
        world.look()
        #expect(await eventually(timeout: 120) { world.pending(second).map(\.text) == ["The worker on lexer is blocked."] },
                "\(world.pending(second))")
        // Held no more once it's in (the store hears it on the engine's queue after the post).
        #expect(await eventually(timeout: 60) { world.held().isEmpty && world.stored?.held == 0 }, "\(world.held())")
        #expect(await eventually(timeout: 60) { EngineState.load(root: world.host.root).state.held.isEmpty })
    }

    /// ReplacedLeadRoutingTests' `heldMessagesGoInTheOrderTheyWereSent`: a message sent while what's held is being sent
    /// again goes behind it, and they reach the lead in the order they were sent.
    @Test func heldMessagesKeepTheOrderTheyWereSentIn() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.lead(idle: false)
        let runs = world.queue.sync { world.engine.leadRuns }
        world.queue.sync { world.engine.leadRuns = { _ in false } }
        #expect(await world.deliver("first words", from: .user, action: "action-1") == false)
        // A look sends what's held again (its read on the reads queue), and a second message is sent meanwhile.
        let second = Locked<Bool?>(nil)
        world.queue.async {
            world.engine.look()
            world.engine.deliver("second words", from: .user, project: world.project, action: "action-2") { second.value = $0 }
        }
        #expect(await eventually(timeout: 60) { second.value != nil })
        #expect(second.value == false)
        await world.drained()
        #expect(world.held().map(\.text) == ["first words", "second words"])
        #expect(world.held().map(\.action) == ["action-1", "action-2"])
        // At rest in that order, each with the action that made it.
        #expect(await eventually(timeout: 60) { EngineState.load(root: world.host.root).state.held.map(\.text) == ["first words", "second words"] })
        #expect(EngineState.load(root: world.host.root).state.held.map(\.action) == ["action-1", "action-2"])

        world.queue.sync { world.engine.leadRuns = runs }
        world.look()
        #expect(await eventually(timeout: 120) { world.pending(lead).count == 2 }, "\(world.pending(lead))")
        #expect(world.pending(lead).map(\.text) == ["first words", "second words"])
        #expect(world.pending(lead).allSatisfy { $0.from == .user })
    }

    /// ReplacedLeadRoutingTests' `aMessageForTheLeadReadsItsBoardOffTheMainThread`: a message for the lead finds the
    /// lead the board names off the engine's queue, and goes into its inbox there.
    @Test func aMessageForTheLeadReadsItsBoardOffTheEngineQueue() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.lead(idle: false)
        let looks = Locked<[(root: String, onEngine: Bool)]>([])
        world.queue.sync { world.engine.boardLooked = { root in looks.mutate { $0.append((root, world.onEngine)) } } }
        #expect(await world.deliver("one", from: .user) == true)
        #expect(await world.deliver("two", from: .user) == true)
        #expect(world.pending(lead).map(\.text) == ["one", "two"])
        #expect(looks.value.contains { $0.root == world.repo && !$0.onEngine })
        #expect(!looks.value.contains { $0.onEngine })
    }

    /// SteerInboxReadOffMainTests' `theHeartbeatsInboxReadsRunOffTheMainThread`: every read of a lead's inbox (to post,
    /// to wake, to type what waits) runs off the engine's queue.
    @Test func theInboxReadsRunOffTheEngineQueue() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.lead()
        let reads = Locked<[Bool]>([])
        world.queue.sync { world.engine.inboxRead = { _ in reads.mutate { $0.append(world.onEngine) } } }
        let before = world.steps.value.count
        #expect(await world.deliver("use port 8080", from: .user) == true)
        let typed = await world.step(after: before) { DeliveryWorld.typed($0) != nil }
        #expect(typed.flatMap(DeliveryWorld.typed) == "use port 8080")
        try await lead.waitFor { world.prompts(lead).contains("use port 8080") }
        let all = reads.value
        #expect(all.count >= 3, "\(all)")
        #expect(all.allSatisfy { !$0 }, "an inbox read ran on the engine's queue: \(all)")
    }

    /// EN-D14: a worker that names its own session as the lead in `board.json` gets nothing; the user's answer is held,
    /// and `status` says why. Once the board names the lead the vault binds, it goes there.
    @Test func aBoardNamingAnotherSessionGetsNoUserAnswer() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.lead(idle: false)
        let worker = try await NodeHarness.start(on: world.host, fake: world.fake, cwd: world.repo, label: "Worker · parser")
        let workerPid = try #require(worker.agentPid)
        try BoardStore(root: world.repo).update { board in
            board.leadSession = worker.session.id.uuidString
            board.leadPid = workerPid
            board.leadTTY = worker.session.tty
        }
        #expect(await world.deliver("yes, merge it", from: .user, action: "action-1") == false)
        #expect(world.pending(worker).isEmpty)
        #expect(world.pending(lead).isEmpty)
        #expect(world.held().map(\.text) == ["yes, merge it"])
        let notice = try #require(world.stored?.notice)
        #expect(notice.contains(worker.session.id.uuidString) && notice.contains("vault binds"), "\(notice)")
        #expect(notice.contains(lead.session.id.uuidString), "\(notice)")
        // In `status`: the lead's notice, and the node's notices.
        let requests = Requests(link: world.link, sessions: nil, rule: VoiceRule(mode: .weaker, scopes: [], uid: getuid(), says: "a test's"),
                                root: world.host.root, hostSocket: world.host.socket, commit: "test", hostPID: 1)
        requests.engine = world.engine
        let status = world.queue.sync { requests.statusValue() }
        #expect(status["notices"]?.array?.contains(.string(notice)) == true, "\(String(describing: status["notices"]))")
        #expect(status["leads"]?.array?.first?["notice"]?.string == notice)
        #expect(status["leads"]?.array?.first?["held"]?.int == 1)

        // The board names the lead the vault binds again: the answer goes to it, and the notice goes.
        let leadPid = try #require(lead.agentPid)
        try BoardStore(root: world.repo).update { board in
            board.leadSession = lead.session.id.uuidString
            board.leadPid = leadPid
            board.leadTTY = lead.session.tty
        }
        world.look()
        #expect(await eventually(timeout: 120) { world.pending(lead).map(\.text) == ["yes, merge it"] }, "\(world.pending(lead))")
        #expect(world.pending(worker).isEmpty)
        #expect(await eventually(timeout: 60) { world.stored?.notice == nil })
    }

    /// `tell` (the app's `tell(_:from:session:)` and `SessionDelivery`): before the host's welcome it says not yet; a
    /// session the host doesn't run, or that ended, it says ended; a live one gets the message in its inbox.
    @Test func tellingAnEndedSessionSaysEndedAndBeforeTheWelcomeSaysNotYet() async throws {
        let world = try await DeliveryWorld.make(scratch, connect: false)
        defer { world.stop() }
        let running = try await NodeHarness.start(on: world.host, fake: world.fake, cwd: world.repo, label: "Worker · parser")
        #expect(await world.tell("a wallet answer", session: running.session.id) == .notYet)
        await world.connect()
        #expect(await world.tell("a wallet answer", session: UUID()) == .ended)
        #expect(await world.tell("a wallet answer", session: running.session.id) == .delivered)
        #expect(world.pending(running).map(\.text) == ["a wallet answer"])
        running.tell(["op": "exit"])
        #expect(await ended(running, in: world))
        #expect(await world.tell("too late", session: running.session.id) == .ended)
        #expect(!world.pending(running).contains { $0.text == "too late" })
    }
}
