import Foundation
import Testing
@testable import VibeCore

/// A retry of message() after Codex's composer becomes available must retire the copy that waited for turn end.
/// Static screens and scratch inboxes only; no session receives keys.
struct CodexMidTurnInboxTests {
    let temp = Scratch()
    let agent = LeadAgent(pid: 4242, tty: "ttys961", session: "fake-codex", agent: .codex)
    let sender = SteerMessage.Sender.lead("lead of vibeswitcher")
    let text = "Yes: continue with the agreed scope."
    let empty = LeadDelivery.Screen(text: "• Working (41s • esc to interrupt)\n\n› Ask Codex to do anything\n\n  gpt-5.1 medium · ~/repo\n  ? for shortcuts")

    func stalls(root: URL, now: Date) -> [LeadStall] {
        let held = SteerInbox.pending(tty: agent.tty, root: root).first { $0.agentPid == agent.pid }
        let seen = LeadWitness.Seen(live: true, status: .working, activity: .working("Bash"),
                                    lastActivity: now.timeIntervalSince1970, heldSince: held?.at,
                                    heldFrom: held == nil ? nil : "lead of vibeswitcher")
        var task = LeadTask(slug: "fake", title: "fake", contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""))
        task.status = .running
        return LeadStall.detect(seen, task: task, now: now)
    }

    @Test(arguments: [true, false])
    func aQueuedMessageRetriedIntoCodexLeavesNoInboxStallOrTurnEndDuplicate(working: Bool) throws {
        let root = temp.url("inbox")
        // The first message() couldn't read the composer, so its copy waits for turn end.
        #expect(try LeadDelivery.deliver(text, from: sender, to: agent, activity: .working("Bash"),
                                         styledScreen: nil, typeInto: nil, root: root) == .atTurnEnd(draft: nil))
        let held = try #require(SteerInbox.pending(tty: agent.tty, root: root).first)
        let later = Date(timeIntervalSince1970: held.at + 7 * 60)
        #expect(stalls(root: root, now: later).map(\.reason) == [.undelivered])
        var typed: [String] = []
        #expect(LeadDelivery.box(in: empty) == .empty)
        #expect(try LeadDelivery.deliver(text, from: sender, to: agent, activity: working ? .working("Bash") : .idle(background: nil),
                                         styledScreen: { empty }, typeInto: { typed.append($0); return true },
                                         root: root) == (working ? .typedWhileWorking : .typed))
        #expect(SteerInbox.pending(tty: agent.tty, root: root).isEmpty)
        #expect(stalls(root: root, now: later).isEmpty)
        #expect(!LeadDelivery.flush(agent, betweenTurns: true, inputIsEmpty: { true },
                                    typeInto: { typed.append($0); return true }, root: root))
        #expect(typed == [LeadDelivery.typed(text, from: sender)])
    }

    @Test func typingARetryRetiresOnlyItsExistingCopies() throws {
        let root = temp.url("inbox")
        let copies = (0..<2).map { _ in SteerMessage(text: text, from: sender, agentPid: agent.pid) }
        let unrelated = [
            SteerMessage(text: text + " Also run lints.", from: sender, agentPid: agent.pid),
            SteerMessage(text: text, from: .lead("another lead"), agentPid: agent.pid),
            SteerMessage(text: text, from: sender, agentPid: agent.pid + 1)
        ]
        for message in copies + unrelated { try SteerInbox.post(message, tty: agent.tty, root: root) }
        let concurrent = SteerMessage(text: text, from: sender, agentPid: agent.pid)
        #expect(try LeadDelivery.deliver(text, from: sender, to: agent, activity: .working("Bash"),
                                         styledScreen: { empty }, typeInto: { _ in
                                             try! SteerInbox.post(concurrent, tty: agent.tty, root: root)
                                             return true
                                         }, root: root) == .typedWhileWorking)
        #expect(SteerInbox.pending(tty: agent.tty, root: root).map(\.id) == (unrelated + [concurrent]).map(\.id))
    }
}
