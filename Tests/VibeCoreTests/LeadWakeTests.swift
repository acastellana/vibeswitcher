import Foundation
import Testing
@testable import VibeCore

/// Reports wake an idle lead (see `LeadWake`): a fake screen and a fake terminal, a scratch inbox; no real session.
struct LeadWakeTests {
    let temp = Scratch()
    func scratch() -> URL { temp.url("wake") }

    let lead = LeadAgent(pid: 4242, tty: "ttys940", session: "lead-session")
    let idle = LeadActivity.idle(background: nil)

    let empty = """
    ✻ Cogitated for 10s · done 1:17 AM
    ──────────────────────────────────────────── lead-vibeswitcher ─
    ❯
    ────────────────────────────────────────────────────────────
      [Opus 5.5] ███░░░░░░░ 30% | vibeswitcher git:(project-lead)
    """

    func screen(_ box: String) -> LeadDelivery.Screen { LeadDelivery.Screen(text: empty.replacingOccurrences(of: "❯", with: "❯ \(box)")) }
    /// Claude's suggested next prompt, drawn faint in the box (row 2, from column 2).
    var suggestion: LeadDelivery.Screen {
        LeadDelivery.Screen(text: screen("merge the verified branch").text, runs: [ScreenRun(row: 2, column: 2, length: 25, faint: true)])
    }
    let dialog = LeadDelivery.Screen(text: "Do you want to proceed?\n❯ 1. Yes\n  2. No")

    /// A report as the lead's tools post it (`tellLead`), at `at`.
    func report(_ text: String, about: String, at: Double, root: URL) throws -> SteerMessage {
        let message = SteerMessage(text: text, from: .system(about), agentPid: lead.pid, at: at)
        try SteerInbox.post(message, tty: lead.tty, root: root)
        return message
    }

    func waiting(_ root: URL) -> [SteerMessage] { LeadWake.reports(SteerInbox.pending(tty: lead.tty, root: root), agentPid: lead.pid) }

    @Test func anIdleLeadWithAnEmptyBoxGetsOneShortWakeUp() throws {
        let root = scratch()
        // The worker's report reaches the idle lead's inbox; its tools don't type it in as it is.
        var typedByTools: [String] = []
        let delivered = try LeadDelivery.deliver("The worker on add-b says it's done: added B, tests pass\nRun audit(add-b); only the verifier's report counts.",
                                                 from: .system("worker add-b"), to: lead, activity: idle,
                                                 styledScreen: { self.screen("") }, typeInto: { typedByTools.append($0); return true }, root: root)
        #expect(delivered == .queued && typedByTools.isEmpty)
        let at = try #require(waiting(root).first?.at)

        var wake = LeadWake()
        var typed: [String] = []
        let type: (String) -> Bool = { typed.append($0); return true }
        // Each tick of the app until 10 s on: one wake-up, after the debounce.
        for second in stride(from: 0.0, through: 10, by: 1) {
            wake.tick(reports: waiting(root), activity: idle, screen: { self.suggestion }, typeInto: type, now: at + second)
            #expect(typed.isEmpty == (second < LeadWake.debounce))
        }
        #expect(typed == ["[VibeSwitcher · reports, not the user] 1 new report (worker add-b done). Call status."])
        // It's marked as VibeSwitcher's, not the user's words.
        #expect(ChatReader.humanText(typed[0]) == nil)
        // The report itself still waits for the prompt's hook, which hands over its full text.
        #expect(waiting(root).count == 1)
        var written: Data?
        SteerReply.answer(["hook_event_name": "UserPromptSubmit"], tty: lead.tty, agentPid: lead.pid, root: root) { written = $0; return true }
        let context = String(decoding: try #require(written), as: UTF8.self)
        #expect(context.contains("added B, tests pass"))
        #expect(waiting(root).isEmpty)
    }

    @Test func reportsCloseTogetherAreOneWakeUp() throws {
        let root = scratch()
        let t = Date().timeIntervalSince1970
        _ = try report("The audit of phone-and-remote passed (complete, clean): works\nmerge(phone-and-remote) when you're ready.",
                       about: "verifier phone-and-remote", at: t, root: root)
        var wake = LeadWake()
        var typed: [String] = []
        let type: (String) -> Bool = { typed.append($0); return true }
        #expect(wake.tick(reports: waiting(root), activity: idle, screen: { self.screen("") }, typeInto: type, now: t + 3) == .later(t + 5))
        _ = try report("The worker on x is blocked: needs the API key", about: "worker x", at: t + 3, root: root)
        // Quiet for 5 s after the last one, but no longer than 8 s after the first.
        #expect(wake.tick(reports: waiting(root), activity: idle, screen: { self.screen("") }, typeInto: type, now: t + 6) == .later(t + 8))
        _ = try report("The worker on y is waiting for input: a permission", about: "witness", at: t + 6, root: root)
        #expect(wake.tick(reports: waiting(root), activity: idle, screen: { self.screen("") }, typeInto: type, now: t + 7.5) == .later(t + 8))
        #expect(typed.isEmpty)
        #expect(wake.tick(reports: waiting(root), activity: idle, screen: { self.screen("") }, typeInto: type, now: t + 8) == .ready)
        #expect(typed == ["[VibeSwitcher · reports, not the user] 3 new reports (verifier phone-and-remote passed; worker x blocked; worker y waits for input). Call status."])
    }

    @Test func midTurnOrOnAPromptItWaits() throws {
        let root = scratch()
        let t = Date().timeIntervalSince1970
        _ = try report("The worker on x is blocked: needs the API key", about: "worker x", at: t, root: root)
        var wake = LeadWake()
        var typed: [String] = []
        let type: (String) -> Bool = { typed.append($0); return true }
        // Mid-turn its hooks hand the report over at its next step; on a prompt, once that's answered.
        for activity in [LeadActivity.working("Bash"), .needsInput("Run: swift test"), .unknown] {
            #expect(wake.tick(reports: waiting(root), activity: activity, screen: { self.screen("") }, typeInto: type, now: t + 30) == .none)
        }
        #expect(typed.isEmpty)
        // Its turn ended without taking it (the report came right after): it's woken now.
        wake.tick(reports: waiting(root), activity: idle, screen: { self.screen("") }, typeInto: type, now: t + 31)
        #expect(typed.count == 1)
    }

    @Test func neverIntoYourDraftItTriesAgainOnceTheBoxIsEmpty() throws {
        let root = scratch()
        let t = Date().timeIntervalSince1970
        _ = try report("The worker on x says it's done: ok", about: "worker x", at: t, root: root)
        var wake = LeadWake()
        var typed: [String] = []
        let type: (String) -> Bool = { typed.append($0); return true }
        var shown = screen("half a thought about the")
        for second in [10.0, 13, 16] {
            #expect(wake.tick(reports: waiting(root), activity: idle, screen: { shown }, typeInto: type, now: t + second) == .ready)
        }
        #expect(typed.isEmpty)
        // You cleared it (or the box only shows Claude's dim suggestion): it goes in.
        shown = suggestion
        wake.tick(reports: waiting(root), activity: idle, screen: { shown }, typeInto: type, now: t + 19)
        #expect(typed.count == 1)
    }

    @Test func notWhileADialogIsOnScreenOrTheScreenCantBeRead() throws {
        let root = scratch()
        let t = Date().timeIntervalSince1970
        _ = try report("The worker on x says it's done: ok", about: "worker x", at: t, root: root)
        var wake = LeadWake()
        var typed: [String] = []
        let type: (String) -> Bool = { typed.append($0); return true }
        wake.tick(reports: waiting(root), activity: idle, screen: { self.dialog }, typeInto: type, now: t + 10)
        wake.tick(reports: waiting(root), activity: idle, screen: { nil }, typeInto: type, now: t + 13)
        #expect(typed.isEmpty)
        // Keys that didn't go out aren't a wake-up in flight: the next try types it.
        wake.tick(reports: waiting(root), activity: idle, screen: { self.screen("") }, typeInto: { _ in false }, now: t + 16)
        #expect(wake.typedFor.isEmpty)
        wake.tick(reports: waiting(root), activity: idle, screen: { self.screen("") }, typeInto: type, now: t + 19)
        #expect(typed.count == 1)
    }

    @Test func noSecondWakeUpUntilTheLeadTookATurn() throws {
        let root = scratch()
        let t = Date().timeIntervalSince1970
        _ = try report("The worker on x says it's done: ok", about: "worker x", at: t, root: root)
        var wake = LeadWake()
        var typed: [String] = []
        let type: (String) -> Bool = { typed.append($0); return true }
        wake.tick(reports: waiting(root), activity: idle, screen: { self.screen("") }, typeInto: type, now: t + 6)
        #expect(typed.count == 1)
        // The prompt didn't go (its Enter was lost, the box was cleared): still idle, another report comes in.
        _ = try report("The worker on y is blocked: stuck", about: "worker y", at: t + 20, root: root)
        for second in [26.0, 40, 200] {
            #expect(wake.tick(reports: waiting(root), activity: idle, screen: { self.screen("") }, typeInto: type, now: t + second) == .none)
        }
        #expect(typed.count == 1)
        // The lead takes a turn (its hook takes what waits); a later report wakes it again.
        _ = SteerInbox.take(tty: lead.tty, agentPid: lead.pid, root: root)
        #expect(wake.tick(reports: waiting(root), activity: idle, screen: { self.screen("") }, typeInto: type, now: t + 210) == .none)
        #expect(wake.typedFor.isEmpty)
        _ = try report("The audit of y did not pass (incomplete, clean): no tests", about: "verifier y", at: t + 220, root: root)
        wake.tick(reports: waiting(root), activity: idle, screen: { self.screen("") }, typeInto: type, now: t + 226)
        #expect(typed.count == 2 && typed[1].contains("1 new report (verifier y failed)"))
    }

    @Test func reportsThatWaitTwoMinutesShowOnTheStrip() throws {
        let root = scratch()
        let t = Date().timeIntervalSince1970
        _ = try report("The worker on x says it's done: ok", about: "worker x", at: t, root: root)
        _ = try report("The worker on y is blocked: stuck", about: "worker y", at: t + 30, root: root)
        // The user's own answer isn't a report.
        try SteerInbox.post(SteerMessage(text: "SQLite", from: .user, agentPid: lead.pid, at: t), tty: lead.tty, root: root)
        var wake = LeadWake()
        // Your draft stays in the box for two minutes: the strip says so.
        for second in stride(from: 0.0, to: 120, by: 3) {
            wake.tick(reports: waiting(root), activity: idle, screen: { self.screen("a draft") }, typeInto: { _ in true }, now: t + second)
            #expect(LeadWake.waiting(waiting(root), now: t + second) == 0)
        }
        #expect(LeadWake.waiting(waiting(root), now: t + 120) == 2)
        // Once the lead has them, none.
        _ = SteerInbox.take(tty: lead.tty, agentPid: lead.pid, root: root)
        #expect(LeadWake.waiting(waiting(root), now: t + 130) == 0)
    }

    /// What each hook event hands the lead now (`SteerReply.answer`, the disk taken as fine): the reports' texts.
    func hook(_ event: String, root: URL, now: Double = Date().timeIntervalSince1970) -> [String] {
        var written: Data?
        SteerReply.answer(["hook_event_name": event], tty: lead.tty, agentPid: lead.pid, root: root, check: { _, _ in true }, now: now) {
            written = $0
            return true
        }
        guard let written, let object = try? JSONSerialization.jsonObject(with: written) as? [String: Any],
              let output = object["hookSpecificOutput"] as? [String: Any], let context = output["additionalContext"] as? String else { return [] }
        return SteerReply.messages(inContext: context).map(\.text)
    }

    /// The wake-up as the app types it: the reports marked in the inbox, under its lock, as it's typed.
    func typeWake(_ root: URL, now: Double = Date().timeIntervalSince1970, into typed: inout [String]) -> [SteerMessage]? {
        var prompt: String?
        let woken = SteerInbox.wake(tty: lead.tty, agentPid: lead.pid, root: root, now: now) { reports in
            prompt = LeadDelivery.typed(LeadWake.prompt(reports), from: .system("reports"))
            return true
        }
        if let prompt { typed.append(prompt) }
        return woken
    }

    /// 2026-10-28, 10:18:54–10:19:07: the lead ran a `!` command (its hooks and transcript said its turn was over), the
    /// wake-up typed for a worker's done report was queued behind that turn, the turn's Stop hook handed the report
    /// over, and then the queued wake-up went in naming it again. One report, through both paths, arrives once.
    @Test func aReportArrivesOnceWhenItsWakeUpWaitsBehindATurn() throws {
        let root = scratch()
        let t = Date().timeIntervalSince1970
        let done = "The worker on sidebardifftests-leave says it's done: the scratch folders are cleaned up"
        _ = try report(done, about: "worker sidebardifftests-leave", at: t, root: root)
        var typed: [String] = []
        #expect(typeWake(root, now: t + 6, into: &typed)?.count == 1)
        #expect(typed == ["[VibeSwitcher · reports, not the user] 1 new report (worker sidebardifftests-leave done). Call status."])
        // The busy turn goes on and ends: its steps and its Stop leave the report to the prompt typed for it.
        var arrived = [hook("PostToolUse", root: root, now: t + 7), hook("Stop", root: root, now: t + 10)].flatMap { $0 }
        #expect(arrived.isEmpty)
        // The queued wake-up goes in: its hook hands the report over, once.
        arrived += hook("UserPromptSubmit", root: root, now: t + 13)
        arrived += hook("Stop", root: root, now: t + 30)
        #expect(arrived == [done])
        #expect(waiting(root).isEmpty)
    }

    /// The other order: the turn's Stop hook takes the report first, so there's nothing left to wake the lead for.
    @Test func aReportTheStopHookTookIsntWokenForAgain() throws {
        let root = scratch()
        let t = Date().timeIntervalSince1970
        let done = "The worker on x says it's done: ok"
        _ = try report(done, about: "worker x", at: t, root: root)
        #expect(hook("Stop", root: root, now: t + 6) == [done])
        var typed: [String] = []
        #expect(typeWake(root, now: t + 6, into: &typed) == nil)
        #expect(typed.isEmpty)
        #expect(hook("UserPromptSubmit", root: root, now: t + 9).isEmpty)
    }

    /// Held for the prompt keeps the order (nothing steered after a held report goes ahead of it at a Stop), and only
    /// for `heldFor`: a wake-up that never went in as a prompt doesn't keep them from any hook after that.
    @Test func heldReportsKeepTheirOrderAndAreHeldOnlySoLong() throws {
        let root = scratch()
        let t = Date().timeIntervalSince1970
        let blocked = "The worker on y is blocked: stuck"
        _ = try report(blocked, about: "worker y", at: t, root: root)
        var typed: [String] = []
        #expect(typeWake(root, now: t + 6, into: &typed) != nil)
        try SteerInbox.post(SteerMessage(text: "use SQLite", from: .user, agentPid: lead.pid, at: t + 7), tty: lead.tty, root: root)
        #expect(hook("Stop", root: root, now: t + 8).isEmpty)
        #expect(hook("PostToolUse", root: root, now: t + 6 + LeadWake.heldFor - 1).isEmpty)
        #expect(hook("PostToolUse", root: root, now: t + 6 + LeadWake.heldFor + 1) == [blocked, "use SQLite"])
    }

    /// A verifier's report too long for one delivery: the wake-up's prompt takes its part 1, and the rest come at the
    /// lead's next steps (not held for a prompt that already went in), before anything posted after it.
    @Test func aLongReportsPartsFollowTheWakeUpInOrder() throws {
        let root = scratch()
        let t = Date().timeIntervalSince1970
        let long = "The audit of x passed (complete, clean): " + (1...400).map { "line \($0): checked, and it holds as the contract says." }.joined(separator: "\n")
        _ = try report(long, about: "verifier x", at: t, root: root)
        var typed: [String] = []
        #expect(typeWake(root, now: t + 6, into: &typed) != nil)
        _ = try report("The worker on y is blocked: stuck", about: "worker y", at: t + 7, root: root)
        let first = hook("UserPromptSubmit", root: root, now: t + 9)
        #expect(first.count == 1 && first[0].hasPrefix("[Part 1 of 3"), "\(first.map { $0.prefix(60) })")
        for (index, step) in [2, 3].enumerated() {
            let part = hook("PostToolUse", root: root, now: t + 12 + Double(index))
            #expect(part.count == 1 && part[0].hasPrefix("[Part \(step) of 3"), "\(part.map { $0.prefix(60) })")
        }
        #expect(hook("PostToolUse", root: root, now: t + 15) == ["The worker on y is blocked: stuck"])
    }

    /// The wake-up's prompt went in, but its hook couldn't hand anything over (here the disk check fails; the seals
    /// unchecked or the lock busy do the same): the report isn't held for a prompt any more, and the lead's next step
    /// takes it, once. And a hold that ran out with nothing taken lets another wake-up go.
    @Test func aWakeUpWhosePromptsHookHandedNothingOverDoesntHoldTheReports() throws {
        let root = scratch()
        let t = Date().timeIntervalSince1970
        let done = "The worker on x says it's done: ok"
        _ = try report(done, about: "worker x", at: t, root: root)
        var wake = LeadWake()
        var typed: [String] = []
        wake.tick(reports: waiting(root), activity: idle, screen: { self.screen("") }, typeInto: { _ in true }, now: t + 6)
        #expect(typeWake(root, now: t + 6, into: &typed) != nil)
        var none: Data?
        SteerReply.answer(["hook_event_name": "UserPromptSubmit"], tty: lead.tty, agentPid: lead.pid, root: root, check: { _, _ in false }, now: t + 8) {
            none = $0
            return true
        }
        #expect(waiting(root).map(\.text) == [done] && waiting(root).allSatisfy { $0.wokenAt == nil })
        _ = none
        #expect(hook("PostToolUse", root: root, now: t + 10) == [done])
        #expect(hook("Stop", root: root, now: t + 20).isEmpty)

        // Held, and never taken: past `heldFor` the app may wake the lead again.
        _ = try report("The worker on y is blocked: stuck", about: "worker y", at: t + 30, root: root)
        var again = LeadWake()
        #expect(again.tick(reports: waiting(root), activity: idle, screen: { self.screen("") }, typeInto: { _ in true }, now: t + 36) == .ready)
        #expect(typeWake(root, now: t + 36, into: &typed) != nil)
        #expect(again.tick(reports: waiting(root), activity: idle, screen: { self.screen("") }, typeInto: { _ in true }, now: t + 60) == .none)
        #expect(again.tick(reports: waiting(root), activity: idle, screen: { self.screen("") }, typeInto: { _ in true }, now: t + 36 + LeadWake.heldFor) == .ready)
    }

    @Test func thePromptSaysWhatCameInInAFewWords() {
        func message(_ text: String, _ about: String = "witness") -> SteerMessage { SteerMessage(text: text, from: .system(about), agentPid: 1) }
        #expect(LeadWake.short(message("The worker on a says it's done: x")) == "worker a done")
        #expect(LeadWake.short(message("The worker on a asks: which db?\nAnswer with message(a, …).")) == "worker a asks")
        #expect(LeadWake.short(message("The worker on a is stalled: idle for 10 min without reporting, last activity 12 min ago. Message it.")) == "worker a stalled")
        #expect(LeadWake.short(message("The worker on a ended (exit 1) without reporting. Its commits…")) == "worker a ended")
        #expect(LeadWake.short(message("The worker on a stopped without calling report. read_session…")) == "worker a stopped")
        #expect(LeadWake.short(message("The worker on a stopped mid-task: its turn ended on an API error (x).")) == "worker a stopped on an API error")
        #expect(LeadWake.short(message("The verifier on a ended without a verdict. read_session…")) == "verifier a ended")
        #expect(LeadWake.short(message("The audit of a passed (complete, clean): ok")) == "verifier a passed")
        #expect(LeadWake.short(message("Something else entirely", "worker z")) == "worker z: Something else entirely")
        let many = (1...5).map { message("The worker on t\($0) is blocked: x") }
        #expect(LeadWake.prompt(many) == "5 new reports (worker t1 blocked; worker t2 blocked; worker t3 blocked; 2 more). Call status.")
    }
}
