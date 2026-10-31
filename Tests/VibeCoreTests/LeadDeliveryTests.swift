import Foundation
import Testing
@testable import VibeCore

struct LeadDeliveryTests {
    let temp = Scratch()
    func state(_ event: String) -> HookState { HookState(agent: .claude, tty: "ttys1", lastEvent: event, lastEventAt: 0) }

    @Test func idleAgentsGetATypedPromptWorkingOnesASteer() {
        #expect(LeadDelivery.way(for: state("Stop")) == .type)
        #expect(LeadDelivery.way(for: state("SessionStart")) == .type)
        #expect(LeadDelivery.way(for: state("PreToolUse")) == .steer)
        #expect(LeadDelivery.way(for: state("PostToolUse")) == .steer)
        #expect(LeadDelivery.way(for: state("UserPromptSubmit")) == .steer)
        #expect(LeadDelivery.way(for: nil) == .type)
    }

    /// A session by the hook event the store's scan read for it: idle (typed) or working (steered) alike.
    @Test func aSessionsWayIsByTheHookEventTheScanRead() {
        var session = Session(tty: "ttys1", agent: .claude, pid: 1, startedAt: Date(), cwd: nil, project: "p", task: nil,
                              status: .idle, statusSince: Date(), detail: nil, hasHooks: true, inTerminalApp: false)
        for event in ["Stop", "SessionStart", "SessionEnd", "Notification", "PermissionRequest"] {
            session.hookEvent = event
            #expect(LeadDelivery.way(for: session) == .type, "\(event)")
            #expect(LeadDelivery.way(for: session) == LeadDelivery.way(for: state(event)))
        }
        for event in ["PreToolUse", "PostToolUse", "UserPromptSubmit"] {
            session.hookEvent = event
            #expect(LeadDelivery.way(for: session) == .steer, "\(event)")
        }
        session.hookEvent = nil
        #expect(LeadDelivery.way(for: session) == .type)
    }

    @Test func typedSystemMessagesAreMarkedAndNotTheUsers() {
        let text = LeadDelivery.typed("Worker add-b finished.", from: .system("worker add-b"))
        #expect(text.hasPrefix("[VibeSwitcher"))
        #expect(TypedText.agentMessage(text)?.body == "Worker add-b finished.")
        #expect(ChatReader.humanText(text) == nil)
        // An answer from the user is the user's words.
        #expect(LeadDelivery.typed("SQLite", from: .user) == "SQLite")
    }

    func scratch() -> URL { temp.url("deliver") }

    @Test func typedOnlyIntoTheEmptyBoxOfAnIdleAgent() throws {
        let root = scratch()
        let agent = LeadAgent(pid: 7, tty: "ttys901", session: "s")
        var typed: [String] = []
        let type: (String) -> Bool = { typed.append($0); return true }
        #expect(try LeadDelivery.deliver("a", from: .system("w"), to: agent, state: state("PreToolUse"), inputIsEmpty: { true }, typeInto: type, root: root) == .steered)
        #expect(try LeadDelivery.deliver("b", from: .system("w"), to: agent, state: state("Stop"), inputIsEmpty: { true }, typeInto: type, root: root) == .typed)
        // Your draft is in the box: it waits, and rides along with your next prompt.
        #expect(try LeadDelivery.deliver("c", from: .system("w"), to: agent, state: state("Stop"), inputIsEmpty: { false }, typeInto: type, root: root) == .queued)
        #expect(try LeadDelivery.deliver("d", from: .system("w"), to: agent, state: state("Stop"), inputIsEmpty: { true }, typeInto: { _ in false }, root: root) == .queued)
        #expect(typed.count == 1 && typed[0].hasSuffix("b"))
        #expect(SteerInbox.pending(tty: "ttys901", root: root).map(\.text) == ["a", "c", "d"])
    }

    @Test func waitingMessagesAreTypedOnceTheBoxIsEmpty() throws {
        let root = scratch()
        let agent = LeadAgent(pid: 7, tty: "ttys902", session: "s")
        try SteerInbox.post(SteerMessage(text: "first", from: .system("witness"), agentPid: 7), tty: agent.tty, root: root)
        try SteerInbox.post(SteerMessage(text: "second", from: .user, agentPid: 7), tty: agent.tty, root: root)
        var typed: [String] = []
        #expect(!LeadDelivery.flush(agent, state: state("Stop"), inputIsEmpty: { false }, typeInto: { typed.append($0); return true }, root: root))
        #expect(!LeadDelivery.flush(agent, state: state("PreToolUse"), inputIsEmpty: { true }, typeInto: { typed.append($0); return true }, root: root))
        #expect(typed.isEmpty)
        // Typing fails: they stay for the next try.
        #expect(!LeadDelivery.flush(agent, state: state("Stop"), inputIsEmpty: { true }, typeInto: { _ in false }, root: root))
        #expect(SteerInbox.pending(tty: agent.tty, root: root).count == 2)
        // Nothing went in, so nothing is marked delivered.
        #expect(SteerInbox.delivered(tty: agent.tty, root: root).isEmpty)
        #expect(LeadDelivery.flush(agent, state: state("Stop"), inputIsEmpty: { true }, typeInto: { typed.append($0); return true }, root: root))
        // The first is typed, marked as the witness's; your answer isn't put under that mark but goes with it
        // through the prompt's hook.
        #expect(typed.count == 1)
        #expect(typed[0].hasPrefix("[VibeSwitcher") && typed[0].hasSuffix("first") && !typed[0].contains("second"))
        #expect(SteerInbox.pending(tty: agent.tty, root: root).map(\.text) == ["second"])
        // Only the typed one is marked delivered, once.
        let ids = SteerInbox.delivered(tty: agent.tty, root: root)
        #expect(ids.count == 1 && !SteerInbox.pending(tty: agent.tty, root: root).contains { ids.contains($0.id) })
        let log = try String(contentsOf: root.appendingPathComponent("steer/\(agent.tty).delivered"), encoding: .utf8)
        #expect(log.split(separator: "\n").count == 1)
    }
}

struct LeadWitnessTests {
    func task(_ slug: String, _ status: LeadTask.Status, worker: String? = nil, verifier: String? = nil, passed: Bool? = nil) -> LeadTask {
        var task = LeadTask(slug: slug, title: slug, contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        task.status = status
        task.worker = worker
        task.verifier = verifier
        if let passed { task.evidence = LeadEvidence(completion: passed ? .complete : .incomplete, integrity: .clean, summary: "") }
        return task
    }

    @Test func toldWhatTheLeadCantSee() {
        let now = Date()
        var board = LeadBoard()
        board.tasks = [task("dies", .running, worker: "w1"),
                       task("judging", .review, worker: "w0", verifier: "v1"),
                       task("fixing", .failed, worker: "w2"),
                       task("quiet", .running, worker: "w3"),
                       task("thinking", .running, worker: "w4"),
                       task("merged", .done, worker: "w5", verifier: "v5"),
                       task("passed", .review, worker: "w6", verifier: "v6", passed: true)]
        let seen: [String: LeadWitness.Seen] = [
            "w1": .init(live: false, exit: 1), "v1": .init(live: false, exit: 0), "w0": .init(live: true, status: .idle, since: now - 500),
            "w2": .init(live: true, status: .needsInput, since: now - 5, detail: "Allow Bash?"),
            "w3": .init(live: true, status: .idle, since: now - 100), "w4": .init(live: true, status: .idle, since: now - 30),
            "w5": .init(live: false, exit: 0), "v5": .init(live: false, exit: 0), "v6": .init(live: false, exit: 0),
        ]
        let events = LeadWitness.events(board: board, seen: seen, now: now)
        let about = Set(events.map { $0.text.components(separatedBy: " ").prefix(6).joined(separator: " ") })
        #expect(events.count == 4, "\(events.map(\.text))")
        #expect(events.contains { $0.text.contains("dies") && $0.text.contains("ended") })
        #expect(events.contains { $0.text.contains("verifier") && $0.text.contains("judging") })
        #expect(events.contains { $0.text.contains("fixing") && $0.text.contains("Allow Bash?") })
        #expect(events.contains { $0.text.contains("quiet") && $0.text.contains("report") })
        #expect(!about.isEmpty)
        // Each event is about one session: a new worker on the same task is watched afresh.
        #expect(events.allSatisfy { key in ["w1", "v1", "w2", "w3"].contains { key.key.contains($0) } })
    }

    /// An audit by finders: one that submitted and ended is no news; one that ended without submitting is, whichever
    /// it is, even while an earlier one still works.
    @Test func eachFinderThatHasntSubmittedIsWatched() {
        let now = Date()
        var board = LeadBoard()
        var audited = task("judging", .review, worker: "w0", verifier: "v1")
        audited.panel = LeadAuditPanel(focuses: ["contract and acceptance", "bugs and regressions", "tests and edge cases"], sessions: ["v1", "v2", "v3"],
                                       reported: [1], commit: "c1", logs: [], run: "the test command passed")
        board.tasks = [audited]
        let seen: [String: LeadWitness.Seen] = [
            "w0": .init(live: true, status: .idle, since: now - 5), "v1": .init(live: false, exit: 0),
            "v2": .init(live: true, status: .working, since: now - 5), "v3": .init(live: false, exit: 1),
        ]
        let events = LeadWitness.events(board: board, seen: seen, now: now)
        #expect(events.map(\.key) == ["v3|ended"], "\(events.map(\.text))")
        #expect(LeadWitness.messages(board: board, seen: seen, now: now, told: { _ in false }).flatMap(\.keys) == ["v3|ended"])
    }

    @Test func anAgentThatQuitLeavingItsShellHasEnded() {
        let now = Date()
        var board = LeadBoard()
        board.tasks = [task("phone", .running, worker: "w1"), task("judging", .review, worker: "w0", verifier: "v1"),
                       task("merged", .done, worker: "w2")]
        // "agent ended · shell": the session lives, its agent doesn't (so no status from its hooks).
        let seen: [String: LeadWitness.Seen] = [
            "w1": .init(live: true, agentQuit: true), "v1": .init(live: true, agentQuit: true), "w2": .init(live: true, agentQuit: true),
            "w0": .init(live: true, status: .idle, since: now - 5),
        ]
        let events = LeadWitness.events(board: board, seen: seen, now: now)
        #expect(events.count == 2, "\(events.map(\.text))")
        let worker = events.first { $0.key == "w1|ended" }
        #expect(worker?.text.contains("phone") == true)
        #expect(worker?.text.contains("without reporting") == true)
        #expect(worker?.text.contains("shell") == true)
        #expect(events.contains { $0.key == "v1|ended" && $0.text.contains("without a verdict") })
        // The same event as the session ending: once the shell exits too, it isn't told again.
        let closed = LeadWitness.events(board: board, seen: ["w1": .init(live: false, exit: 129)], now: now)
        #expect(closed.map(\.key) == ["w1|ended"])
    }

    /// 2026-10-18 ~19:40, twice (a-successful-handover-is, the-user-s-own): audit() started a verifier, and seconds
    /// later the witness said it stopped without calling submit_audit; it had only just begun, and passed minutes on.
    /// Its first sighting reads as finished, since long ago: before its hooks fire there is only the title's ✳ and no
    /// time (`.distantPast`), or the status the terminal it reuses had under an earlier session.
    @Test func aJustStartedVerifierIsntStopped() {
        let t0 = Date(timeIntervalSince1970: 1_792_352_400)  // 2026-10-18 19:40
        let started = t0.timeIntervalSince1970
        let reviewing = { (passed: Bool?) in
            var board = LeadBoard()
            board.tasks = [self.task("the-user-s-own", .review, worker: "w1", verifier: "v2", passed: passed)]
            return board
        }
        let firstSightings: [LeadWitness.Seen] = [
            // Nothing from its hooks or transcript yet.
            .init(live: true, status: .idle, since: .distantPast, activity: .unknown, started: started),
            // The prompt and one command in its transcript.
            .init(live: true, status: .idle, since: .distantPast, activity: .working("Bash"), lastActivity: started + 3, started: started),
            // The terminal's earlier session finished there a quarter of an hour ago.
            .init(live: true, status: .done, since: t0 - 900, activity: .unknown, started: started),
        ]
        for seen in firstSightings {
            for after in [2.0, 4, 10] {
                let events = LeadWitness.events(board: reviewing(nil), seen: ["v2": seen, "w1": .init(live: false, exit: 0)], now: t0 + after)
                #expect(events.isEmpty, "\(after)s in: \(events.map(\.text))")
            }
        }
        // At work, then its verdict: nothing to tell either.
        let working = LeadWitness.Seen(live: true, status: .working, since: t0 + 5, activity: .working("Bash"), lastActivity: started + 60, started: started)
        #expect(LeadWitness.events(board: reviewing(nil), seen: ["v2": working], now: t0 + 120).isEmpty)
        let submitted = LeadWitness.Seen(live: true, status: .done, since: t0 + 360, activity: .idle(background: nil), lastActivity: started + 360, started: started)
        #expect(LeadWitness.events(board: reviewing(true), seen: ["v2": submitted], now: t0 + 600).isEmpty)
    }

    /// A verifier whose turn really ended without a verdict is still told, once it has been quiet a while.
    @Test func aVerifierWhoseTurnEndedWithoutAVerdictIsTold() {
        let t0 = Date(timeIntervalSince1970: 1_792_352_400)
        let started = t0.timeIntervalSince1970
        var board = LeadBoard()
        board.tasks = [task("checked", .review, worker: "w1", verifier: "v2")]
        let ended = LeadWitness.Seen(live: true, status: .done, since: t0 + 240, activity: .idle(background: nil), lastActivity: started + 239, started: started)
        #expect(LeadWitness.events(board: board, seen: ["v2": ended], now: t0 + 240 + 30).isEmpty)
        let told = LeadWitness.events(board: board, seen: ["v2": ended], now: t0 + 240 + LeadWitness.quiet + 1)
        #expect(told.count == 1, "\(told.map(\.text))")
        #expect(told.first?.key.hasPrefix("v2|stopped-") == true)
        #expect(told.first?.text.contains("The verifier on checked stopped without calling submit_audit") == true)
        // Never moving at all once started counts too, though its status gives no time of its own.
        let idle = LeadWitness.Seen(live: true, status: .idle, since: .distantPast, activity: .unknown, started: started)
        #expect(LeadWitness.events(board: board, seen: ["v2": idle], now: t0 + LeadWitness.quiet + 1).map(\.text)
                    .contains { $0.contains("stopped without calling submit_audit") })
    }

    /// A task audited again: its earlier verifier (ended, or sitting at its prompt) tells nothing about the new one.
    @Test func anEarlierVerifierOfTheTaskTellsNothingAboutTheNewOne() {
        let t0 = Date(timeIntervalSince1970: 1_792_352_400)
        var board = LeadBoard()
        board.tasks = [task("a-successful-handover-is", .review, worker: "w1", verifier: "v2")]
        // The new one runs on the terminal the earlier one had, and inherits its status and since.
        let fresh = LeadWitness.Seen(live: true, status: .done, since: t0 - 1_200, activity: .unknown, started: t0.timeIntervalSince1970)
        for earlier in [LeadWitness.Seen(live: false, exit: 0),
                        LeadWitness.Seen(live: true, status: .done, since: t0 - 1_200, activity: .idle(background: nil),
                                         lastActivity: t0.timeIntervalSince1970 - 1_200, started: t0.timeIntervalSince1970 - 1_800)] {
            for after in [1.0, 5, 30] {
                let seen = ["v1": earlier, "v2": fresh]
                #expect(LeadWitness.events(board: board, seen: seen, now: t0 + after).isEmpty)
                #expect(LeadWitness.messages(board: board, seen: seen, now: t0 + after, told: { _ in false }).isEmpty)
            }
        }
    }
}

