import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// The incident of 2026-10-31 and 2026-11-01 (docs/lead/incidents.md): a verifier's session waited indefinitely on a
/// permission prompt the user couldn't see or reach, and the lead could only start the audit again, the finders' work
/// lost. Here a fake Claude Code (`FakeClaude`, on a scratch pty through a scratch session host: never a real session)
/// is the verifier, waiting on a permission prompt; the witness's look (`WitnessWork`, as the app's) at an injected
/// time, and the app's decline (`PromptDecline.handle`, as `LeadController` runs it) through the session host.
@MainActor
@Suite(.serialized)
struct StuckVerifierPromptTests {
    let temp = Scratch()

    @Test func aVerifierPromptNoOneAnswersIsDeclinedAfterTheWaitWithItsReasonAndTheLeadIsToldOnce() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        let command = "git ls-files -s Package.swift; git config --get remote.origin.url"
        // Claude Code 2.1.316's prompt: its No row takes the reason only once Tab opened its text field.
        h.tell(["op": "permission", "command": command, "ui": "2.1.316"])
        try await h.paneShows { $0.contains("Do you want to proceed?") && $0.contains("git config") }

        let verifier = h.session.id.uuidString
        var task = LeadTask(slug: "audit-me", title: "audit-me", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        task.status = .review
        task.verifier = verifier
        var board = LeadBoard()
        board.tasks = [task]
        let since = Date()
        let started = since.addingTimeInterval(-300).timeIntervalSince1970
        let seen = [verifier: LeadWitness.Seen(live: true, status: .needsInput, since: since, detail: "Bash: git ls-files -s Package.swift",
                                               pending: PendingPrompt(text: "Run: " + command, since: since.timeIntervalSince1970),
                                               started: started, boundAt: started, toolsAt: started + 2)]
        var told: Set<String> = []
        func look(_ after: TimeInterval) -> WitnessWork {
            WitnessWork(board: board, seen: seen, now: since.addingTimeInterval(after), advancing: false, budgetMinutes: 60,
                        firstSeen: { _ in nil }, told: { told.contains($0) })
        }

        // Before the wait: nothing declined, and nothing for the lead (who could only start the audit again).
        for after in [5.0, 60, 119] {
            let work = look(after)
            #expect(work.stuckPrompts.isEmpty, "\(after)s")
            #expect(work.messages.isEmpty, "\(after)s: \(work.messages.map { $0.text() })")
        }
        // Still asking (its state is written after its screen is drawn: waited for, not read once).
        try await h.waitFor { h.agent["mode"] as? String == "permission" }

        // Past it: declined, as the app does (each stuck prompt told once).
        var reports: [String] = []
        let work = look(LeadWitness.promptWait + 1)
        #expect(work.messages.isEmpty)
        #expect(work.stuckPrompts.count == 1)
        for stuck in work.stuckPrompts where told.insert(stuck.key).inserted {
            PromptDecline.handle(stuck, host: h.host) { text in reports.append(text()) }
        }
        // The verifier gets the reason as the prompt's No, and its turn goes on (one read of its state holds both).
        try await h.waitFor {
            let agent = h.agent
            return agent["declined"] as? String == LeadWitness.declineReason && agent["mode"] as? String == "working"
        }
        let transcript = try String(contentsOf: h.transcript, encoding: .utf8)
        #expect(transcript.contains("the user said:\\n" + LeadWitness.declineReason), "\(transcript.suffix(600))")
        // The lead: one report, naming the command.
        try await h.waitFor { !reports.isEmpty }
        #expect(reports.count == 1)
        #expect(reports.first?.contains("permission prompt no one answers: “Run: \(command)”") == true, "\(reports)")
        #expect(reports.first?.contains(LeadWitness.declineReason) == true)
        // And the next looks tell nothing more.
        for after in [300.0, 3_600] {
            let again = look(after)
            #expect(again.stuckPrompts.isEmpty && again.messages.isEmpty, "\(after)s")
        }
        #expect(reports.count == 1)
    }

    /// The incident of 2026-11-05: a verifier stopped on the prompt to Read one of the worker's evidence screenshots
    /// (outside its worktree), VibeSwitcher couldn't decline it (it knew only a command's prompt), and three audits
    /// hung, one for 155 minutes. The fake draws the Read prompt as Claude Code 2.1.318's bundle builds it (no capture
    /// of the real screen exists). After the wait it's declined with the reason, the verifier goes on without that
    /// file, and the lead is told once. The same prompt in a worker's session is the lead's to answer: never declined.
    @Test func aVerifiersReadPromptNoOneAnswersIsDeclinedAfterTheWaitAndAWorkersNever() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        let file = "/Users/x/dev/repo/.vibeswitcher/evidence/wallet-requests-marked/7C0E0F5B-1D2A/4-marked-no-peer-main-dark.png"
        h.tell(["op": "permission", "file": file])
        try await h.paneShows { $0.contains("Read file") && $0.contains("Do you want to proceed?") && $0.contains("allow reading from") }

        let session = h.session.id.uuidString
        let since = Date()
        let started = since.addingTimeInterval(-300).timeIntervalSince1970
        // What the witness has of it: the call as the transcript holds it, as it told the lead on 2026-11-05.
        let pending = PendingPrompt(text: PendingPrompt.text(toolName: "Read", input: ["file_path": file]), since: since.timeIntervalSince1970)
        #expect(pending.text == "Allow: Read 4-marked-no-peer-main-dark.png\n{\"file_path\":\"\(file)\"}", "\(pending.text)")
        let seen = [session: LeadWitness.Seen(live: true, status: .needsInput, since: since, detail: "Read: 4-marked-no-peer-main-dark.png",
                                              pending: pending, started: started, boundAt: started, toolsAt: started + 2)]
        var told: Set<String> = []
        func look(_ board: LeadBoard, _ after: TimeInterval) -> WitnessWork {
            WitnessWork(board: board, seen: seen, now: since.addingTimeInterval(after), advancing: false, budgetMinutes: 60,
                        firstSeen: { _ in nil }, told: { told.contains($0) })
        }
        var task = LeadTask(slug: "wallet-requests-marked", title: "t", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))

        // A worker waiting on it, however long: nothing to decline.
        task.status = .running
        task.worker = session
        var working = LeadBoard()
        working.tasks = [task]
        for after in [5.0, LeadWitness.promptWait + 1, 9_300] { #expect(look(working, after).stuckPrompts.isEmpty, "\(after)s") }

        // The verifier: nothing before the wait, declined past it.
        task.status = .review
        task.worker = nil
        task.verifier = session
        var board = LeadBoard()
        board.tasks = [task]
        for after in [5.0, 60, 119] {
            let work = look(board, after)
            #expect(work.stuckPrompts.isEmpty && work.messages.isEmpty, "\(after)s: \(work.messages.map { $0.text() })")
        }
        // Still asking (its state is written after its screen is drawn: waited for, not read once).
        try await h.waitFor { h.agent["mode"] as? String == "permission" }
        var reports: [String] = []
        let work = look(board, LeadWitness.promptWait + 1)
        #expect(work.stuckPrompts.count == 1 && work.messages.isEmpty)
        for stuck in work.stuckPrompts where told.insert(stuck.key).inserted {
            PromptDecline.handle(stuck, host: h.host) { text in reports.append(text()) }
        }
        try await h.waitFor {
            let agent = h.agent
            return agent["declined"] as? String == LeadWitness.declineReason && agent["mode"] as? String == "working"
        }
        let transcript = try String(contentsOf: h.transcript, encoding: .utf8)
        #expect(transcript.contains("the user said:\\n" + LeadWitness.declineReason), "\(transcript.suffix(600))")
        #expect(!transcript.contains("\"ran Read"), "a Yes went in: \(transcript.suffix(400))")
        // The lead: one report, saying it was declined and what was asked.
        try await h.waitFor { !reports.isEmpty }
        #expect(reports.count == 1)
        #expect(reports.first?.contains("VibeSwitcher declined it, telling it: “\(LeadWitness.declineReason)”") == true, "\(reports)")
        #expect(reports.first?.contains("Allow: Read 4-marked-no-peer-main-dark.png") == true && reports.first?.contains(file) == true, "\(reports)")
        for after in [300.0, 9_300] {
            let again = look(board, after)
            #expect(again.stuckPrompts.isEmpty && again.messages.isEmpty, "\(after)s")
        }
        #expect(reports.count == 1)
    }

    /// A No row that takes no text (the older "No, and tell Claude what to do differently (esc)" row), where the
    /// reason's letters are keys: the "k" in "check" moves the cursor up. Enter never goes on a Yes row; Esc declines
    /// it instead, and the lead is told so.
    @Test func aNoRowThatTakesNoReasonIsDeclinedWithEscNeverApproved() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        let command = "bash scripts/probe.sh --deep"
        h.tell(["op": "permission", "command": command])
        try await h.paneShows { $0.contains("Do you want to proceed?") && $0.contains("probe.sh") }
        let since = Date().addingTimeInterval(-LeadWitness.promptWait - 1)
        let stuck = LeadWitness.StuckPrompt(key: "\(h.session.id.uuidString)|input-1", session: h.session.id.uuidString, slug: "audit-me",
                                            prompt: PendingPrompt(text: "Run: " + command, since: since.timeIntervalSince1970))
        var reports: [String] = []
        PromptDecline.handle(stuck, host: h.host) { text in reports.append(text()) }
        try await h.waitFor { !reports.isEmpty }
        #expect(reports.count == 1 && reports.first?.contains("with Esc") == true && reports.first?.contains(command) == true, "\(reports)")
        // Declined without a reason: its turn over, in one read of its state (idle alone is its state before the prompt too).
        try await h.waitFor {
            let agent = h.agent
            return agent["mode"] as? String == "idle" && agent["reply"] as? String == "Denied."
        }
        let transcript = try String(contentsOf: h.transcript, encoding: .utf8)
        #expect(!transcript.contains("\"ran " + command), "a Yes went in: \(transcript.suffix(400))")
    }

    /// A plain "No" row that Tab doesn't open (a No row that takes no reason): the reason isn't typed (its letters would
    /// be the menu's keys); Esc declines it, never a Yes.
    @Test func aPlainNoRowTabDoesntOpenIsDeclinedWithEscWithoutTypingTheReason() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        let command = "bash scripts/probe.sh --wide"
        h.tell(["op": "permission", "command": command, "ui": "2.1.316", "plainNo": true])
        try await h.paneShows { $0.contains("Do you want to proceed?") && $0.contains("probe.sh") && $0.contains("Tab to amend") }
        let since = Date().addingTimeInterval(-LeadWitness.promptWait - 1)
        let stuck = LeadWitness.StuckPrompt(key: "\(h.session.id.uuidString)|input-1", session: h.session.id.uuidString, slug: "audit-me",
                                            prompt: PendingPrompt(text: "Run: " + command, since: since.timeIntervalSince1970))
        var reports: [String] = []
        PromptDecline.handle(stuck, host: h.host) { text in reports.append(text()) }
        try await h.waitFor { !reports.isEmpty }
        #expect(reports.count == 1 && reports.first?.contains("with Esc") == true, "\(reports)")
        try await h.waitFor {
            let agent = h.agent
            return agent["mode"] as? String == "idle" && agent["reply"] as? String == "Denied."
        }
        let transcript = try String(contentsOf: h.transcript, encoding: .utf8)
        #expect(!transcript.contains("\"ran " + command), "a Yes went in: \(transcript.suffix(400))")
    }
}

/// With several finders the verifier is only the first (`LeadTask.panel`): the witness read finders 2..N not at all, so
/// a finder waiting on a prompt was never declined (the blind check's, 2026-11-01). Each finder's transcript is read
/// (`TeamReading.read`, over `LeadTask.members`), and the one waiting on a prompt is stuck after the wait.
struct StuckFinderPromptTests {
    let temp = Scratch()

    @Test func aSecondFinderWaitingOnAPromptIsReadAndStuckAfterTheWait() throws {
        let home = temp.url("finders").path
        let states = (home as NSString).appendingPathComponent("state")
        let projects = (home as NSString).appendingPathComponent(".claude/projects/-r")
        try FileManager.default.createDirectory(atPath: states, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)
        let observer = LeadObserver(home: home, stateFile: { URL(fileURLWithPath: (states as NSString).appendingPathComponent("\($0).json")) })
        let started = ISO8601DateFormatter().date(from: "2026-11-01T00:20:00Z")!
        let command = "git ls-files -s x; ls"
        let asking = """
        {"isSidechain":false,"type":"user","timestamp":"2026-11-01T00:30:00Z","message":{"role":"user","content":"Audit it."}}
        {"isSidechain":false,"type":"assistant","timestamp":"2026-11-01T00:31:00Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"\(command)"}}]}}

        """
        var hosted: [String: HostSession] = [:]
        var sessions: [String: Session] = [:]
        var ids: [String] = []
        for (index, tty) in ["ttys951", "ttys952", "ttys953"].enumerated() {
            let id = UUID()
            ids.append(id.uuidString)
            hosted[id.uuidString] = HostSession(id: id, tty: tty, childPID: 1, cwd: "/r", command: "claude", label: "Verifier: audit-me",
                                                agent: "claude", title: "", startedAt: started, cols: 120, rows: 40, exit: nil)
            let transcript = (projects as NSString).appendingPathComponent("\(id.uuidString.lowercased()).jsonl")
            try (index == 1 ? asking : "").write(toFile: transcript, atomically: true, encoding: .utf8)
            var hook = HookState(agent: .claude, tty: tty, lastEvent: "PreToolUse", lastEventAt: started.timeIntervalSince1970)
            hook.agentPid = 7200 + Int32(index)
            hook.transcriptPath = transcript
            try hook.save(to: observer.stateFile(tty))
            var session = Session(tty: tty, agent: .claude, pid: 7200 + Int32(index), startedAt: started, cwd: "/r", project: "r", task: nil,
                                  status: index == 1 ? .needsInput : .working, statusSince: started, detail: nil, hasHooks: true,
                                  inTerminalApp: false)
            session.hostID = id
            sessions[id.uuidString] = session
        }
        var task = LeadTask(slug: "audit-me", title: "audit-me", contract: LeadContract(goal: "", acceptance: [], boundaries: [], context: ""),
                            status: .review)
        task.verifier = ids[0]
        task.panel = LeadAuditPanel(focuses: ["contract and acceptance", "bugs and regressions", "tests and edge cases"], sessions: ids, reported: [],
                                    commit: "c1", logs: [], run: "the test command passed")
        #expect(task.members == ids)
        var board = LeadBoard()
        board.tasks = [task]

        let team = TeamReading.read(root: home, board: board, hosted: hosted, sessions: sessions, observer: observer)
        let pending = try #require(team.watched[ids[1]]?.tail?.pending, "finder 2 wasn't read")
        #expect(pending.text == "Run: " + command)
        // As the witness builds its view of finder 2: waiting, with what it waits on.
        let since = Date(timeIntervalSince1970: pending.since ?? 0)
        let seen = [ids[1]: LeadWitness.Seen(live: true, status: .needsInput, since: since, pending: pending,
                                             started: started.timeIntervalSince1970, boundAt: started.timeIntervalSince1970,
                                             toolsAt: started.timeIntervalSince1970 + 2)]
        #expect(LeadWitness.stuckPrompts(board: board, seen: seen, now: since.addingTimeInterval(60)).isEmpty)
        let stuck = LeadWitness.stuckPrompts(board: board, seen: seen, now: since.addingTimeInterval(LeadWitness.promptWait + 1))
        #expect(stuck.map(\.session) == [ids[1]] && stuck.first?.prompt.text == "Run: " + command, "\(stuck)")
    }
}
