import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// T41 narrowed (the engine plan's EN-D11, the security architecture document's S11 item 29): the user's answer reaches
/// the lead as a `.user` message the host seals for the server (whose root is the node's: its seals go to the host's
/// vault through the connector), and a copy of that sealed line put back into the lead's inbox arrives as unverified once
/// the server saw the lead take it or the line gone (it retires the seal), or else once the seal's life is over. Against a `ScratchNode`, the lead started from the command line and asking through its tool server.
@Suite(NodeTraits.linuxOnly, .serialized, .timeLimit(.minutes(10)))
struct UserSealTests {
    private let scratch = Scratch()

    /// The answer's `.user` message in the lead's inbox, sealed by the host.
    private func answered(_ node: ScratchNode) async throws -> (lead: ScratchNode.AskingLead, message: SteerMessage, line: Data) {
        let lead = try await node.askingLead("Name the parser?", options: ["Parser", "Reader"])
        let answered = try await node.runOnTerminal(["answer", lead.card, "Parser"])
        #expect(answered.status == 0, "\(answered.output)\n\(node.said)")
        #expect(answered.output.contains("answered: the lead is told"), "\(answered.output)")
        let found = Locked<(SteerMessage, Data)?>(nil)
        let inbox = node.root.appendingPathComponent("steer/\(lead.session.tty).jsonl")
        try #require(await eventually(timeout: 60) {
            let data = (try? Data(contentsOf: inbox)) ?? Data()
            for line in data.split(separator: 0x0A) {
                if let message = try? JSONDecoder().decode(SteerMessage.self, from: Data(line)), message.from == .user, message.text.contains("Parser") {
                    found.value = (message, Data(line))
                    return true
                }
            }
            return false
        }, "no answer in the lead's inbox: \(node.said)")
        let (message, line) = try #require(found.value)
        #expect(message.seal != nil)
        return (lead, message, line)
    }

    /// The lead's hook at its next step, checking seals with the scratch host's vault (as `vibeswitcher-hook` does with
    /// the node's): the messages it handed over.
    private func take(_ node: ScratchNode, _ lead: ScratchNode.AskingLead, recordDelivered: Bool = true) -> [SteerMessage] {
        let socket = node.socket
        let sealer = SteerSeal(seal: { _ in throw LeadVault.Refused("the test seals nothing") }, verify: { messages in
            guard case .verified(let valid)? = try? HostCall.vault(.verify(messages), socket: socket) else { return nil }
            return valid
        })
        var handed: [SteerMessage] = []
        SteerInbox.deliver(tty: lead.session.tty, agentPid: lead.agentPid, root: node.root, sealer: sealer, check: { _, _ in true },
                           wholeBatch: true) { messages in
            handed = messages
            return messages.count
        }
        if !recordDelivered { try? FileManager.default.removeItem(at: node.root.appendingPathComponent("steer/\(lead.session.tty).delivered")) }
        return handed
    }

    /// Whether the host's vault takes `message`'s seal now.
    private func verifies(_ node: ScratchNode, _ message: SteerMessage) -> Bool? {
        guard case .verified(let valid)? = try? HostCall.vault(.verify([message]), socket: node.socket) else { return nil }
        return valid.first
    }

    private func putBack(_ line: Data, _ node: ScratchNode, _ lead: ScratchNode.AskingLead) throws {
        let handle = try FileHandle(forWritingTo: node.root.appendingPathComponent("steer/\(lead.session.tty).jsonl"))
        handle.seekToEndOfFile()
        handle.write(line + Data("\n".utf8))
        try handle.close()
    }

    @Test func aReplayedUserMessageIsNotDeliveredTwice() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let (lead, message, line) = try await answered(node)
        let first = take(node, lead)
        #expect(first.contains { $0.id == message.id && $0.from == .user }, "\(first)")
        // The server sees the lead took it and retires its seal (at its next look).
        #expect(await eventually(timeout: 60) { verifies(node, message) == false }, "\(node.said)")
        try putBack(line, node, lead)
        let replayed = take(node, lead)
        let copy = try #require(replayed.first { $0.id == message.id }, "\(replayed)")
        #expect(copy.from != .user, "\(copy.from)")
    }

    /// The E6 review: an answer that waits in the lead's inbox past its seal's life (the lead's tool call runs on, a
    /// merge's tests: no hook takes the inbox) is still the user's when the lead takes it, since the server renews the
    /// seal of each of the user's messages it still sees waiting.
    @Test func anAnswerWaitingPastItsSealsLifeIsStillTheUsers() async throws {
        let life = 6
        let node = try await ScratchNode(scratch, sealLife: life)
        defer { node.stop() }
        let (lead, message, _) = try await answered(node)
        // The event: twice the seal's life has gone by since it was sealed, the message untaken.
        try #require(await eventually(timeout: 60) { Date().timeIntervalSince1970 > message.at + Double(2 * life) })
        let taken = take(node, lead)
        let answer = try #require(taken.first { $0.id == message.id }, "\(taken) \(node.said)")
        #expect(answer.from == .user, "\(answer.from)")
    }

    /// The security follow-ups' item 16: the server renews only a waiting line that is still what it posted (the user's,
    /// for the same agent, with the same text). A process that takes the sealed answer out of the inbox and leaves a line
    /// of its own under the answer's id keeps no seal alive: the sealed copy it puts back after the seal's life is not the
    /// user's.
    @Test func aLineRewrittenUnderAPostedIdKeepsNoSealAlive() async throws {
        let life = 6
        let node = try await ScratchNode(scratch, sealLife: life)
        defer { node.stop() }
        let (lead, message, line) = try await answered(node)
        let inbox = node.root.appendingPathComponent("steer/\(lead.session.tty).jsonl")
        func replace(with data: Data) throws {
            let handle = try FileHandle(forWritingTo: inbox)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data + Data("\n".utf8))
            try handle.close()
        }
        var other = message
        other.text = "Answer to your question: Reader"
        try replace(with: try JSONEncoder().encode(other))
        // The event: twice the seal's life has gone by since it was sealed, the server looking all the while.
        try #require(await eventually(timeout: 60) { Date().timeIntervalSince1970 > message.at + Double(2 * life) })
        try replace(with: line)
        let taken = take(node, lead)
        let copy = try #require(taken.first { $0.id == message.id }, "\(taken) \(node.said)")
        #expect(copy.from != .user, "\(copy.from)")
    }

    /// A seal the server never retires still ends with its life: taken with no delivered record left behind and a copy
    /// put straight back (so the server sees its id waiting, never gone, and never taken), the copy is the user's no
    /// more once the seal's life is over (the take's check passed it, so it isn't renewed). Expired, not retired: it
    /// verifies until its life from its sealing (no earlier than the message's time) is over, longer than the server's
    /// looks would take to retire it.
    @Test func aReplayIsRefusedEvenWithTheDeliveredRecordRemoved() async throws {
        let life = 12.0
        let node = try await ScratchNode(scratch, sealLife: Int(life))
        defer { node.stop() }
        let (lead, message, line) = try await answered(node)
        let first = take(node, lead, recordDelivered: false)
        #expect(first.contains { $0.id == message.id && $0.from == .user }, "\(first)")
        try putBack(line, node, lead)
        // Inside its life a copy is still the user's (S11 item 29: as often as it is copied back); past it, not.
        let ended = Locked<Double?>(nil)
        #expect(await eventually(timeout: 60) {
            guard verifies(node, message) == false else { return false }
            ended.value = Date().timeIntervalSince1970
            return true
        }, "\(node.said)")
        let at = try #require(ended.value)
        #expect(at >= message.at + life, "verified false \(at - message.at) s after the message's time: retired, not expired")
        let replayed = take(node, lead)
        let copy = try #require(replayed.first { $0.id == message.id }, "\(replayed)")
        #expect(copy.from != .user, "\(copy.from)")
    }
}

extension ScratchNode {
    /// A lead started from the command line on a scratch repository, busy (its hooks say so: nothing is typed into it),
    /// that asked through its tool server: its session, its agent's pid, and the card the server made.
    struct AskingLead {
        var repo: URL
        var session: HostSession
        var agentPid: Int32
        var card: String
    }

    func askingLead(_ question: String, options: [String]) async throws -> AskingLead {
        let repo = root.appendingPathComponent("repo")
        if !FileManager.default.fileExists(atPath: repo.path) { try await scratchRepository(repo) }
        let started = try await runOnTerminal(["lead", repo.path, "--goal", "plan the work"])
        try #require(started.status == 0, "\(started.output)\n\(said)")
        let lead = try #require(try sessions().first { $0.isLive && $0.label.hasPrefix("Lead · ") }, "\(said)")
        let files = fake.files(terminal: lead.tty)
        try #require(await eventually(timeout: 60) { FileManager.default.fileExists(atPath: files.state.path) })
        let state = { (try? JSONSerialization.jsonObject(with: Data(contentsOf: files.state))) as? [String: Any] ?? [:] }
        try #require(await eventually(timeout: 60) { state()["pid"] != nil })
        let pid = try #require((state()["pid"] as? Int).map(Int32.init))
        // Mid-turn, as its hooks would say: the wake and the flush type nothing into it.
        var hook = HookState(agent: .claude, tty: lead.tty, lastEvent: "PreToolUse", lastEventAt: Date().timeIntervalSince1970)
        hook.agentPid = pid
        let stateFile = root.appendingPathComponent("state/\(lead.tty).json")
        try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try hook.save(to: stateFile)
        // It asks through its tool server.
        let command: [String: Any] = ["op": "mcp", "tool": "ask_user", "arguments": ["question": question, "options": options] as [String: Any]]
        let line = try JSONSerialization.data(withJSONObject: command) + Data("\n".utf8)
        let handle = try FileHandle(forWritingTo: files.control)
        handle.seekToEndOfFile()
        handle.write(line)
        try handle.close()
        let calls = { (state()["mcp"] as? [[String: Any]]) ?? [] }
        try #require(await eventually(timeout: 120) { !calls().isEmpty }, "\(said)")
        // The card the server made from the post, as `questions` lists it (polled as `eventually` polls).
        var listed: String?
        let deadline = MacTime.real.awake() + 60
        while listed == nil, MacTime.real.awake() < deadline {
            let ran = try await run(["questions", "--json"])
            if ran.status == 0, let object = try? JSONSerialization.jsonObject(with: Data(ran.output.utf8)) as? [String: Any],
               let cards = object["cards"] as? [[String: Any]],
               let card = cards.first(where: { ($0["question"] as? [String: Any])?["text"] as? String == question }) {
                listed = card["id"] as? String
            } else {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        try #require(listed != nil, "no card for the question: \(calls()) \(said)")
        return AskingLead(repo: repo, session: lead, agentPid: pid, card: try #require(listed))
    }
}
