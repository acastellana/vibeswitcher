import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The Mac's rule's decision on the server (`Requests.approvalJudgment`), on both systems and with no host: a fake
/// person (`ApprovalVoiceTests.Person`), never a dialog. What runs on the Mac's CI runner of the Touch ID path; the whole
/// request on a scratch host is `ApprovalRequestsTests` (Linux).
struct ApprovalJudgmentTests {
    private let scratch = Scratch()

    private struct NoHost: HostDialer {
        func connect(queue: DispatchQueue, patience: TimeInterval) throws -> HostConnection { throw HostLink.Failure("no host in this test") }
    }

    static let pid: pid_t = 9_000_901
    static let commandLine = Data(repeating: 0xc1, count: 20)
    static let user = PeerFacts(pid: pid, uid: getuid(), cgroup: nil, ancestry: [.init(pid: pid, startTicks: 5)], terminal: .named("ttytest-mac"),
                                sessionMarker: nil, underRunner: false)

    private func requests(_ person: any ApprovalVoice.Authenticator, commandLinePeer: Bool = true) -> Requests {
        let queue = DispatchQueue(label: "approval-judgment")
        let link = HostLink(dialer: NoHost(), root: scratch.url("link"), queue: queue)
        let requests = Requests(link: link, sessions: nil, rule: VoiceRule(mode: .approval, scopes: [], uid: getuid(), says: VoiceRule.approvalSays),
                                root: scratch.url("root"), hostSocket: scratch.url("h.sock").path, commit: "test", hostPID: 1)
        requests.approval = ApprovalVoice(authenticator: person, commandLine: Self.commandLine) { token, code in
            commandLinePeer && code == Self.commandLine && token.pid == Self.pid
        }
        return requests
    }

    private func judge(_ requests: Requests, _ kind: String, _ args: [String: NodeWire.Value] = [:],
                       action: String? = UUID().uuidString.lowercased(), facts: PeerFacts = user) async -> (done: Bool, refused: NodeWire.Reply?) {
        let result = Locked<(Bool, NodeWire.Reply?)>((false, nil))
        let request = NodeWire.Request(id: UUID().uuidString, kind: kind, args: args, action: action)
        let token = ApprovalVoiceTests.token(Self.pid)
        requests.queue.async { requests.approvalJudgment(request, from: facts, token: token) { result.value = (true, $0) } }
        _ = await eventually(timeout: 60) { result.value.0 }
        return result.value
    }

    @Test func aReadPassesWithoutAskingAndAStateChangeOnlyOnceApproved() async {
        let person = ApprovalVoiceTests.Person(.approved)
        let requests = requests(person)
        let read = await judge(requests, "status", action: nil)
        #expect(read.done && read.refused == nil && person.asked.isEmpty)
        let set = await judge(requests, "set", ["key": .string("lead_mail"), "value": .string("off")])
        #expect(set.done && set.refused == nil, "\(String(describing: set.refused))")
        #expect(person.asked == ["change a VibeSwitcher setting: key lead_mail; value off"])
    }

    @Test func declinedUnavailableOrNotTheCommandLineIsRefused() async {
        for answer: Platform.Approval.Outcome in [.declined("cancelled at the Mac"), .unavailable("over ssh")] {
            let refused = await judge(requests(ApprovalVoiceTests.Person(answer)), "session.end", ["session": .string("local:abcd")]).refused
            #expect(refused?.error?.code == NodeWire.Code.voice.rawValue, "\(String(describing: refused))")
        }
        let person = ApprovalVoiceTests.Person(.approved)
        let stranger = await judge(requests(person, commandLinePeer: false), "session.end", ["session": .string("local:abcd")]).refused
        #expect(stranger?.error?.message.contains("isn't the installed command line") == true)
        // Under a live session's program: refused before asking (the guard rails).
        let underSession = PeerFacts(pid: Self.pid, uid: getuid(), cgroup: nil, ancestry: [.init(pid: Self.pid, startTicks: 5), .init(pid: 1, startTicks: 1)],
                                     terminal: .named("ttytest-mac"), sessionMarker: nil, underRunner: false)
        let hosted = await judge(requests(person), "session.end", ["session": .string("local:abcd")], facts: underSession).refused
        #expect(hosted?.error?.message.contains("session host") == true, "\(String(describing: hosted))")
        let noAction = await judge(requests(person), "session.end", ["session": .string("local:abcd")], action: nil).refused
        #expect(noAction?.error?.code == NodeWire.Code.badArgs.rawValue)
        // A card's request on a server that holds no cards: refused before asking.
        let card = await judge(requests(person), "answer", ["card": .string("local:card:x"), "code": .string("ABCD"), "text": .string("yes")]).refused
        #expect(card != nil)
        #expect(person.asked.isEmpty)
    }

    @Test func aSecondStateChangeWhileOneWaitsIsRefused() async throws {
        let person = ApprovalRequestsTests.SlowPerson()
        let requests = requests(person)
        let first = Locked<(Bool, NodeWire.Reply?)>((false, nil))
        let request = NodeWire.Request(id: "first", kind: "session.end", args: ["session": .string("local:abcd")], action: UUID().uuidString.lowercased())
        let token = ApprovalVoiceTests.token(Self.pid)
        requests.queue.async { requests.approvalJudgment(request, from: Self.user, token: token) { first.value = (true, $0) } }
        try #require(await offPool { person.asking.wait(timeout: .now() + 60) == .success })
        let second = await judge(requests, "session.end", ["session": .string("local:efgh")])
        #expect(second.refused?.error?.message.contains("waiting for your approval at the Mac") == true)
        #expect(await judge(requests, "status", action: nil).refused == nil)
        person.release.signal()
        #expect(await eventually(timeout: 60) { first.value.0 && first.value.1 == nil })
    }
}
