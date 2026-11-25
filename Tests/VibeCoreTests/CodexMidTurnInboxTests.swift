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

    // MARK: What its rollout shows it took

    /// A rollout line at `at`, as Codex writes it.
    static func line(_ at: Double, _ type: String, _ payload: [String: Any]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date(timeIntervalSince1970: at))
        let data = try! JSONSerialization.data(withJSONObject: ["timestamp": stamp, "type": type, "payload": payload], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func userMessage(_ at: Double, _ text: String) -> String {
        line(at, "response_item", ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]])
    }

    static func call(_ at: Double, _ command: String) -> String {
        line(at, "response_item", ["type": "function_call", "name": "exec_command", "call_id": "call-\(Int(at))",
                                   "arguments": "{\"cmd\":\"\(command)\"}"])
    }

    /// A fake Codex worker's session (nothing runs: a hosted session as the host lists it, its hooks' state and its
    /// rollout in a scratch home), and an observer that reads them.
    func fakeCodex(rollout lines: [String], agent kind: Agent = .codex, startedAt: Double) throws -> (HostSession, LeadObserver, URL) {
        let home = temp.url("codex-home").resolvingSymlinksInPath()
        let rollout = home.appendingPathComponent(kind == .codex
            ? ".codex/sessions/2026/11/19/rollout-2026-11-19T10-04-25-01a1f30c-cf5c-71c0-aaa9-daa61295153f.jsonl"
            : ".claude/projects/-scratch-repo/5f0c9a1e.jsonl")
        try FileManager.default.createDirectory(at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: rollout)
        var hook = HookState(agent: kind, tty: agent.tty, lastEvent: "PostToolUse", lastEventAt: startedAt + 60)
        hook.agentPid = agent.pid
        hook.transcriptPath = rollout.path
        let stateFile = home.appendingPathComponent("state/\(agent.tty).json")
        try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try hook.save(to: stateFile)
        let session = HostSession(id: UUID(), tty: agent.tty, childPID: agent.pid, cwd: "/scratch/repo", command: kind.rawValue,
                                  label: "Worker", agent: kind.rawValue, title: "", startedAt: Date(timeIntervalSince1970: startedAt),
                                  cols: 120, rows: 40, exit: nil)
        return (session, LeadObserver(home: home.path, stateFile: { _ in stateFile }), home.appendingPathComponent("vibe"))
    }

    func idleStalls(root: URL, now: Date) -> [LeadStall] {
        let held = SteerInbox.pending(tty: agent.tty, root: root).first { $0.agentPid == agent.pid }
        let seen = LeadWitness.Seen(live: true, status: .idle, activity: .idle(background: nil),
                                    lastActivity: held.map { $0.at - 60 }, heldSince: held?.at,
                                    heldFrom: held == nil ? nil : "lead of vibeswitcher")
        var task = LeadTask(slug: "fake", title: "fake", contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""))
        task.status = .running
        return LeadStall.detect(seen, task: task, now: now)
    }

    /// audits-run-on-codex, 2026-11-19: the lead's message went into the Codex worker's box mid-turn and the worker
    /// answered it in that turn, but a copy waited in its inbox (posted when the host's answer to the typing didn't
    /// come in time), and the witness told it as undelivered at 5 min, 27 min, 38 min and 1 h. Its rollout records
    /// the message in the turn, with the turn's steps after it: the copy is recorded as delivered, nothing is told,
    /// and the turn's end doesn't type it again.
    @Test func aMessageCodexTookIntoItsRunningTurnIsntToldAsUndelivered() throws {
        let typedAt = 1_795_600_000.0
        let typedText = LeadDelivery.typed(text, from: sender)
        // Its box wraps the typed text: the rollout has it as submitted, line breaks and all.
        let wrapped = typedText.replacingOccurrences(of: "continue with", with: "continue\nwith")
        let (session, observer, root) = try fakeCodex(rollout: [
            Self.call(typedAt - 300, "swift build"),
            Self.call(typedAt - 30, "bash scripts/test.sh --filter LeadStallTests"),
            Self.userMessage(typedAt + 5, wrapped),
            Self.call(typedAt + 40, "git commit -m 'The lead confirmed the scope'"),
            Self.call(typedAt + 600, "bash scripts/test.sh --filter 'LintTests/'"),
        ], startedAt: typedAt - 3600)
        // Posted after the keys went in: the host's answer to the typing didn't come in time.
        let copy = SteerMessage(text: text, from: sender, agentPid: agent.pid, at: typedAt + 41)
        try SteerInbox.post(copy, tty: agent.tty, root: root)
        let later = Date(timeIntervalSince1970: copy.at + 7 * 60)
        // As the witness read it before: stalled on an undelivered message, though Codex works on it.
        #expect(stalls(root: root, now: later).map(\.reason) == [.undelivered])

        #expect(observer.retireTaken(session, agentPid: agent.pid, root: root).map(\.id) == [copy.id])
        #expect(SteerInbox.pending(tty: agent.tty, root: root).isEmpty)
        #expect(SteerInbox.delivered(tty: agent.tty, root: root) == [copy.id])
        #expect(stalls(root: root, now: later).isEmpty)
        #expect(stalls(root: root, now: Date(timeIntervalSince1970: copy.at + 3600)).isEmpty)
        var typed: [String] = []
        #expect(!LeadDelivery.flush(agent, betweenTurns: true, inputIsEmpty: { true }, typeInto: { typed.append($0); return true }, root: root))
        #expect(typed.isEmpty)
    }

    /// A message Codex never took (its turn ended with it in its box, or it waits for the turn's end) stays in the
    /// inbox, and an idle Codex worker with it there is still told as stalled once it has waited past the threshold.
    @Test func aMessageCodexNeverTookIsStillToldAsUndelivered() throws {
        let postedAt = 1_795_600_000.0
        // It answered an earlier message of the same text, long before this one was posted, and nothing since.
        let (session, observer, root) = try fakeCodex(rollout: [
            Self.userMessage(postedAt - 1800, LeadDelivery.typed(text, from: sender)),
            Self.call(postedAt - 1700, "swift build"),
            Self.line(postedAt - 60, "response_item", ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Done."]]]),
        ], startedAt: postedAt - 3600)
        let waiting = SteerMessage(text: text, from: sender, agentPid: agent.pid, at: postedAt)
        try SteerInbox.post(waiting, tty: agent.tty, root: root)

        #expect(observer.retireTaken(session, agentPid: agent.pid, root: root).isEmpty)
        #expect(SteerInbox.pending(tty: agent.tty, root: root).map(\.id) == [waiting.id])
        #expect(idleStalls(root: root, now: Date(timeIntervalSince1970: postedAt + LeadStall.undeliveredAfter - 30)).isEmpty)
        #expect(idleStalls(root: root, now: Date(timeIntervalSince1970: postedAt + LeadStall.undeliveredAfter + 30)).map(\.reason) == [.undelivered])
        // The turn's end still types it.
        var typed: [String] = []
        #expect(LeadDelivery.flush(agent, betweenTurns: true, inputIsEmpty: { true }, typeInto: { typed.append($0); return true }, root: root))
        #expect(typed == [LeadDelivery.typed(text, from: sender)])
    }

    /// A Claude worker's inbox is its hooks' to hand over: a transcript holding the message's text retires nothing.
    @Test func aClaudeWorkersInboxIsLeftToItsHooks() throws {
        let postedAt = 1_795_600_000.0
        let (session, observer, root) = try fakeCodex(rollout: [Self.userMessage(postedAt + 5, LeadDelivery.typed(text, from: sender))],
                                                      agent: .claude, startedAt: postedAt - 3600)
        try SteerInbox.post(SteerMessage(text: text, from: sender, agentPid: agent.pid, at: postedAt), tty: agent.tty, root: root)
        #expect(observer.retireTaken(session, agentPid: agent.pid, root: root).isEmpty)
        #expect(SteerInbox.pending(tty: agent.tty, root: root).count == 1)
    }

    @Test func eachRecordStandsForOneCopyAndABatchPromptForEachOfItsMessages() {
        let at = 1_795_600_000.0
        let other = "Run the lints too."
        let first = SteerMessage(text: text, from: sender, agentPid: agent.pid, at: at)
        let second = SteerMessage(text: text, from: sender, agentPid: agent.pid, at: at + 10)
        let fyi = SteerMessage(text: other, from: sender, agentPid: agent.pid, at: at + 20)
        let user = SteerMessage(text: other, from: .user, agentPid: agent.pid, at: at + 30)
        // One record of the text: one copy taken; the other waits for a record of its own.
        let once = [CodexInbox.Recorded(text: LeadDelivery.typed(text, from: sender), at: at + 15)]
        #expect(CodexInbox.taken([first, second], recorded: once).map(\.id) == [first.id])
        // The turn's end typed the whole queue as one prompt: each message in it is taken.
        let batch = [first, second, fyi].map { LeadDelivery.typed($0.text, from: $0.from) }.joined(separator: "\n\n")
        #expect(CodexInbox.taken([first, second, fyi], recorded: [CodexInbox.Recorded(text: batch, at: at + 100)]).map(\.id)
                == [first.id, second.id, fyi.id])
        // The lead's text as the user's own words (no frame) isn't the lead's message, nor the reverse.
        #expect(CodexInbox.taken([fyi], recorded: [CodexInbox.Recorded(text: other, at: at + 100)]).isEmpty)
        #expect(CodexInbox.taken([user], recorded: [CodexInbox.Recorded(text: other, at: at + 100)]).map(\.id) == [user.id])
        // A later, longer message that starts with its text isn't it.
        let short = SteerMessage(text: "Merged.", from: sender, agentPid: agent.pid, at: at)
        #expect(CodexInbox.taken([short], recorded: [CodexInbox.Recorded(text: LeadDelivery.typed("Merged. Next: the docs.", from: sender),
                                                                         at: at + 100)]).isEmpty)
        #expect(CodexInbox.taken([short], recorded: [CodexInbox.Recorded(text: LeadDelivery.typed("Merged.", from: sender) + "\n\n"
                                                                         + LeadDelivery.typed("Next: the docs.", from: sender), at: at + 100)]).map(\.id) == [short.id])
        // Recorded long before it was posted: an earlier message of the same text.
        #expect(CodexInbox.taken([first], recorded: [CodexInbox.Recorded(text: LeadDelivery.typed(text, from: sender),
                                                                         at: at - CodexInbox.typedBefore - 1)]).isEmpty)
    }

    @Test func onlyTheRolloutsUserMessagesAreRecorded() {
        let at = 1_795_600_000.0
        let lines = [
            Self.userMessage(at, "first"),
            Self.line(at + 1, "event_msg", ["type": "user_message", "role": "user", "message": "first"]),
            Self.line(at + 2, "event_msg", ["type": "item_completed", "item": ["type": "UserMessage", "content": [["type": "text", "text": "first"]]]]),
            Self.line(at + 3, "response_item", ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "ok"]]]),
            Self.userMessage(at + 4, "second"),
        ]
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let recorded = CodexInbox.recorded(in: data)
        #expect(recorded.map(\.text) == ["first", "second"])
        #expect(recorded.map { $0.at.rounded() } == [at, at + 4])
        // A partial last line isn't read yet.
        #expect(CodexInbox.recorded(in: data + Data(Self.userMessage(at + 5, "third").utf8.dropLast(4))).map(\.text) == ["first", "second"])
    }
}
