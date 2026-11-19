import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// `vibeswitcher tell FOLDER TEXT` (2026-11-19), as `answer`'s cases go: the user's words reach the project's running
/// lead once, as the user's, recorded in the host's vault first (the request's action, then the message's digest);
/// held while the lead can't take them; refused with no lead there, from a session's process, and from a web page.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct TellTests {
    private let scratch = Scratch()

    private func tell(_ world: CardWorld, _ text: String, folder: String? = nil, action: String = UUID().uuidString.lowercased(),
                      from facts: PeerFacts = CardWorld.user) async -> NodeWire.Reply? {
        await world.ask("tell", ["folder": .string(folder ?? world.repo), "text": .string(text)], action: action, from: facts)
    }

    @Test func aTellReachesTheRunningLeadOnceAsTheUsersAndIsRecorded() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await world.world.lead(idle: false)
        let action = UUID().uuidString.lowercased()
        let reply = try #require(await tell(world, "Prefer the small fix", action: action))
        #expect(reply.ok, "\(reply)")
        #expect(reply.result?["session"]?.string == NodeIds.session(host: harness.session.id), "\(reply)")
        let told = LeadEngine.toldText("Prefer the small fix")
        #expect(await eventually(timeout: 60) { world.world.pending(harness).contains { $0.from == .user && $0.text == told } },
                "\(world.world.pending(harness))")
        // Recorded: the request, then the message the lead got, by its digest.
        #expect(await world.actions().filter { $0.action == action }.map(\.kind) == ["tell", "message"])
        let client = world.world.link.vaultV2
        #expect(try await offPool { try client.holds(action: action, digest: LeadVaultV2.digest(told)) })

        // The same action again is answered as before, not sent again.
        let again = try #require(await tell(world, "Prefer the small fix", action: action))
        #expect(again.ok, "\(again)")
        await world.drained()
        #expect(world.world.pending(harness).filter { $0.text == told }.count == 1, "\(world.world.pending(harness))")
        #expect(world.held().isEmpty, "\(world.held())")
        #expect(await world.actions().filter { $0.action == action }.map(\.kind) == ["tell", "message"])
    }

    /// A folder inside the project is the project: the repository's top is the lead's root.
    @Test func aFolderInsideTheProjectTellsItsLead() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await world.world.lead(idle: false)
        let inside = world.repo + "/docs"
        try FileManager.default.createDirectory(atPath: inside, withIntermediateDirectories: true)
        #expect(try #require(await tell(world, "From a subfolder", folder: inside)).ok)
        #expect(await eventually(timeout: 60) {
            world.world.pending(harness).contains { $0.from == .user && $0.text == LeadEngine.toldText("From a subfolder") }
        })
    }

    /// A lead whose agent can't take it now (nothing but `sleep` runs): held as the user's, in order.
    @Test func aTellForALeadThatCantTakeItIsHeld() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        _ = try await world.sleepingLead()
        #expect(try #require(await tell(world, "first")).ok)
        #expect(try #require(await tell(world, "second")).ok)
        #expect(await eventually(timeout: 60) { world.held().count == 2 }, "\(world.held())")
        #expect(world.held().map(\.text) == [LeadEngine.toldText("first"), LeadEngine.toldText("second")])
        #expect(world.held().allSatisfy { $0.from == .user })
    }

    @Test func aTellWithNoLeadThereIsRefused() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let action = UUID().uuidString.lowercased()
        let reply = try #require(await tell(world, "Anyone there?", action: action))
        #expect(reply.error?.code == NodeWire.Code.refused.rawValue, "\(reply)")
        #expect(reply.error?.message.contains("no lead runs in") == true, "\(reply)")
        await world.drained()
        #expect(world.held().isEmpty, "\(world.held())")
        // The request is recorded (the voice passed), and no message is.
        #expect(await world.actions().filter { $0.action == action }.map(\.kind) == ["tell"])
    }

    @Test func aTellFromASessionsProcessIsRefused() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        _ = try await world.sleepingLead()
        let session = try await world.host.spawn("exec /bin/sleep 600", cwd: world.repo, label: "Worker · parser")
        try #require(await eventually(timeout: 60) { world.queue.sync { world.world.link.sessions.contains { $0.id == session.id && $0.isLive } } })
        let action = UUID().uuidString.lowercased()
        let reply = try #require(await tell(world, "Merge it all", action: action, from: PeerFacts.read(pid: session.childPID)))
        #expect(reply.error?.code == NodeWire.Code.voice.rawValue, "\(reply)")
        #expect(reply.error?.message.contains("live session") == true, "\(reply)")
        await world.drained()
        #expect(world.held().isEmpty, "\(world.held())")
        #expect(await world.actions().filter { $0.action == action }.isEmpty)
    }

    /// The lead's tool server (a session's child, carrying the session's marker) is no user either.
    @Test func aTellFromALeadsToolServerIsRefused() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.sleepingLead()
        let reply = try #require(await tell(world, "Approve yourself", from: CardWorld.toolServer(of: lead)))
        #expect(reply.error?.code == NodeWire.Code.voice.rawValue, "\(reply)")
        await world.drained()
        #expect(world.held().isEmpty, "\(world.held())")
    }

    /// Through the command line on a scratch node, its code typed on its terminal: the lead's inbox gets the words once,
    /// sealed as the user's; a folder with no lead is refused, nothing sent; a wrong form is the usage.
    @Test func theCommandLineTellsTheLeadAndRefusesAFolderWithNoLead() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let lead = try await node.askingLead("Name the parser?", options: ["Parser", "Reader"])
        let told = try await node.runOnTerminal(["tell", lead.repo.path, "Keep the parser small"])
        #expect(told.status == 0, "\(told.output)\n\(node.said)")
        #expect(told.output.contains("told: the lead (session"), "\(told.output)")
        let inbox = node.root.appendingPathComponent("steer/\(lead.session.tty).jsonl")
        let messages = {
            ((try? Data(contentsOf: inbox)) ?? Data()).split(separator: 0x0A).compactMap { try? JSONDecoder().decode(SteerMessage.self, from: Data($0)) }
                .filter { $0.text == LeadEngine.toldText("Keep the parser small") }
        }
        #expect(await eventually(timeout: 60) { !messages().isEmpty }, "\(node.said)")
        #expect(messages().count == 1 && messages().first?.from == .user && messages().first?.seal != nil, "\(messages())")

        let other = node.root.appendingPathComponent("other")
        try await scratchRepository(other)
        let refused = try await node.runOnTerminal(["tell", other.path, "Hello?"])
        #expect(refused.status == 77, "\(refused.output)\(refused.errors)\n\(node.said)")
        #expect((refused.output + refused.errors).contains("no lead runs in"), "\(refused.output)\(refused.errors)")
        let usage = try await node.run(["tell", lead.repo.path])
        #expect(usage.status == 64 && usage.errors.contains("usage: vibeswitcher tell FOLDER TEXT"), "\(usage.output)\(usage.errors)")
    }

    /// A web page is never the user's voice, whatever its token's rights.
    @Test func aWebPageCannotTell() {
        #expect(NodeWire.kinds["tell"] == .user)
        #expect(NodeWire.changesState("tell"))
        #expect(Requests.recorded.contains("tell"))
        let refused = WebAccess.refusal(for: NodeWire.Request(id: "1", kind: "tell", args: ["folder": .string("/r"), "text": .string("x")]),
                                        rights: [.read, .draft])
        #expect(refused?.error?.code == NodeWire.Code.voice.rawValue, "\(String(describing: refused))")
        #expect(!WebAccess.kinds(for: [.read, .draft]).contains("tell"))
    }
}
