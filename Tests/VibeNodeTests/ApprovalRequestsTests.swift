import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The Mac's rule on the server (`VoiceRule.Mode.approval`, `Requests.approvalVoice`): the server's own `Requests` on a
/// scratch host with that rule and a fake person (`ApprovalVoiceTests.Person`): no dialog is ever shown. A read is
/// answered without asking; a state change only once the person agrees to what the server built of it
/// (`approvalCard`), never what the command line said; a caller that isn't the command line, a wrong card code or an
/// approval already waiting is refused before anything is asked. Runs on both systems.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct ApprovalRequestsTests {
    private let scratch = Scratch()

    /// A person who waits for `release` before answering (an approval held at the Mac).
    final class SlowPerson: ApprovalVoice.Authenticator, @unchecked Sendable {
        let release = DispatchSemaphore(value: 0)
        let asking = DispatchSemaphore(value: 0)
        func ask(_ reason: String) -> Platform.Approval.Outcome {
            asking.signal()
            release.wait()
            return .approved
        }
    }

    static let commandLine = Data(repeating: 0xc1, count: 20)

    /// The world's host and link, with a `Requests` on the Mac's rule: `person` asked, the user's peer (`CardWorld.user`)
    /// running the command line's code unless `commandLinePeer` is false.
    private func requests(_ world: CardWorld, _ person: any ApprovalVoice.Authenticator, commandLinePeer: Bool = true) -> Requests {
        let rule = VoiceRule(mode: .approval, scopes: [], uid: getuid(), says: VoiceRule.approvalSays)
        let requests = Requests(link: world.world.link, sessions: nil, rule: rule, root: world.host.root, hostSocket: world.host.socket,
                                commit: "test", hostPID: 1)
        requests.engine = world.engine
        requests.approval = ApprovalVoice(authenticator: person, commandLine: Self.commandLine, runs: { token, code in
            commandLinePeer && code == Self.commandLine && token.pid == CardWorld.userPID
        }, hardened: { _ in true })
        return requests
    }

    private func ask(_ world: CardWorld, _ requests: Requests, _ kind: String, _ args: [String: NodeWire.Value] = [:],
                     action: String? = UUID().uuidString.lowercased()) async -> NodeWire.Reply? {
        let reply = Locked<NodeWire.Reply?>(nil)
        let request = NodeWire.Request(id: UUID().uuidString, kind: kind, args: args, action: action)
        let token = ApprovalVoiceTests.token(CardWorld.userPID)
        world.queue.async { requests.handle(request, from: CardWorld.user, token: token) { reply.value = $0 } }
        _ = await eventually(timeout: 60) { reply.value != nil }
        return reply.value
    }

    private func leadMail(_ world: CardWorld) -> String? {
        NodeSettings.node(files: NodeSettings.Files(root: world.host.root)).first { $0.setting.key == "lead_mail" }?.value
    }

    @Test func aReadIsAnsweredWithoutAskingAndAStateChangeOnlyOnceApproved() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let person = ApprovalVoiceTests.Person(.approved)
        let requests = requests(world, person)
        let status = try #require(await ask(world, requests, "status", action: nil))
        #expect(status.ok, "\(status)")
        #expect(person.asked.isEmpty)

        let set = try #require(await ask(world, requests, "set", ["key": .string("lead_mail"), "value": .string("off")]))
        #expect(set.ok, "\(set)")
        #expect(leadMail(world) == "off")
        // What the person was asked: the server's words for the request, its own arguments.
        let reason = try #require(person.asked.first)
        #expect(reason.hasPrefix("change a VibeSwitcher setting: ") && reason.contains("set lead_mail to “off”"), "\(reason)")
        #expect(person.asked.count == 1)
    }

    @Test func aDeclinedOrUnavailableApprovalChangesNothing() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        for answer: Platform.Approval.Outcome in [.declined("cancelled at the Mac"), .unavailable("no session to show the dialog in")] {
            let person = ApprovalVoiceTests.Person(answer)
            let set = try #require(await ask(world, requests(world, person), "set", ["key": .string("lead_mail"), "value": .string("off")]))
            #expect(set.error?.code == NodeWire.Code.voice.rawValue, "\(set)")
            #expect(person.asked.count == 1)
            #expect(leadMail(world) == "on")
        }
        // Nothing recorded as the user's either.
        #expect(await world.actions().filter { $0.kind == "set" }.isEmpty)
    }

    /// Never asked: a caller that isn't the installed command line, a state change missing its action id, a card's
    /// wrong code.
    @Test func whatFailsTheCheapChecksIsNeverAsked() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let person = ApprovalVoiceTests.Person(.approved)
        let stranger = try #require(await ask(world, requests(world, person, commandLinePeer: false), "set", ["key": .string("lead_mail"), "value": .string("off")]))
        #expect(stranger.error?.code == NodeWire.Code.voice.rawValue && stranger.error?.message.contains("isn't the installed command line") == true, "\(stranger)")
        let requests = requests(world, person)
        let noAction = try #require(await ask(world, requests, "set", ["key": .string("lead_mail"), "value": .string("off")], action: nil))
        #expect(noAction.error?.code == NodeWire.Code.badArgs.rawValue, "\(noAction)")
        let lead = try await world.sleepingLead()
        let (_, card) = try await world.asked("Ship it?", lead: lead)
        let wrongCode = try #require(await ask(world, requests, "answer", ["card": .string(card.id), "code": .string("ZZZZ"), "text": .string("yes")]))
        #expect(wrongCode.error?.code == NodeWire.Code.voice.rawValue, "\(wrongCode)")
        #expect(person.asked.isEmpty)

        // The right code: asked, naming the card's question and the words sent, never the command line's.
        let answered = try #require(await ask(world, requests, "answer", ["card": .string(card.id), "code": .string(card.code), "text": .string("yes")]))
        #expect(answered.ok, "\(answered)")
        let reason = try #require(person.asked.first)
        #expect(reason.hasPrefix("answer a lead's question for you: ") && reason.contains("answer “yes” in") && reason.contains("Ship it?"), "\(reason)")
    }

    /// While one approval waits at the Mac, another state change is refused, not stacked; a read still answers.
    @Test func oneApprovalAtATime() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let person = SlowPerson()
        let requests = requests(world, person)
        let first = Locked<NodeWire.Reply?>(nil)
        let request = NodeWire.Request(id: "first", kind: "set", args: ["key": .string("lead_mail"), "value": .string("off")],
                                       action: UUID().uuidString.lowercased())
        let token = ApprovalVoiceTests.token(CardWorld.userPID)
        world.queue.async { requests.handle(request, from: CardWorld.user, token: token) { first.value = $0 } }
        try #require(await offPool { person.asking.wait(timeout: .now() + 60) == .success })
        let second = try #require(await ask(world, requests, "set", ["key": .string("lead_mail"), "value": .string("on")]))
        #expect(second.error?.message.contains("dialog is open at the Mac right now, so this one wasn't asked") == true, "\(second)")
        let status = try #require(await ask(world, requests, "status", action: nil))
        #expect(status.ok)
        person.release.signal()
        #expect(await eventually(timeout: 60) { first.value?.ok == true })
        #expect(leadMail(world) == "off")
    }
}
