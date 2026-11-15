import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// Waking the lead and typing what waits for it (the engine plan's E5), on a scratch host in the test process with
/// `FakeClaude` as the lead (`DeliveryWorld`): the app's `ComposerDeliveryTests` delivery cases and
/// `ReplacedLeadRoutingTests`' wake and flush cases restated on the engine ("off the main thread" is off the engine's
/// queue). A wake-up is typed once, into an empty box, into the lead the vault binds and the board names at the moment
/// of typing, never into a shell the agent left.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(10)))
struct WakeTests {
    private let scratch = Scratch()

    @Test func aReportReachesAnIdleLeadAndTheWakePromptIsTypedOnceForAllThatWait() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.lead()
        let reports = ["The worker on parser says it's done.", "The worker on lexer is blocked: it needs the grammar.",
                       "The audit of docs passed."]
        let before = world.steps.value.count
        for report in reports { #expect(await world.deliver(report, from: .system("witness")) == true) }
        // One wake-up for the three, once they've been quiet a moment (`LeadWake.debounce`).
        let typed = await world.step(after: before) { DeliveryWorld.typed($0) != nil }
        #expect(typed.flatMap(DeliveryWorld.typed)?.contains("3 new reports") == true, "\(String(describing: typed))")
        try await lead.waitFor { world.prompts(lead).contains { $0.contains("3 new reports") } }
        // While they wait for its prompt's hook, a look types nothing more: the lead hasn't taken a turn.
        let again = world.steps.value.count
        world.look()
        let none = await world.step(after: again) { DeliveryWorld.typed($0) != nil || DeliveryWorld.refused($0) != nil }
        #expect(none.flatMap(DeliveryWorld.refused)?.contains("until the lead has taken a turn") == true, "\(String(describing: none))")
        // Its prompt's hook hands the three over with it, each once.
        #expect(lead.hookTakes(event: "UserPromptSubmit"))
        let handed = world.handed(lead)
        for report in reports { #expect(handed.components(separatedBy: report).count == 2, "\(handed)") }
        // No second wake-up: nothing waits now.
        world.look()
        await world.drained()
        #expect(world.steps.value.compactMap(DeliveryWorld.typed).count == 1, "\(world.steps.value)")
        #expect(world.prompts(lead).filter { $0.contains("new report") }.count == 1, "\(world.prompts(lead))")
        #expect(world.pending(lead).isEmpty)
    }

    /// ComposerDeliveryTests' `aMessageHeldForAQuestionStaysHeldWhenTheAgentExitsToAShell`'s first half, and the rule it
    /// keeps: nothing is typed into a draft or an open prompt; once the prompt is answered and the turn over, the
    /// wake-up goes.
    @Test func aWakeIsNotTypedIntoADraftOrAnOpenPrompt() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.lead()
        try world.post("The worker on parser says it's done.", from: .system("witness"), to: lead)
        // A draft in its box.
        world.keys("half a thought", into: lead)
        try await lead.screenShows { $0.contains("❯ half a thought") }
        var before = world.steps.value.count
        world.look()
        let draft = await world.step(after: before) { DeliveryWorld.refused($0) != nil }
        #expect(draft.flatMap(DeliveryWorld.refused)?.contains("a draft") == true, "\(String(describing: draft))")
        // Its draft sent, then a permission prompt open.
        world.keys("\r", into: lead)
        try await lead.waitFor { world.prompts(lead).contains("half a thought") }
        lead.tell(["op": "permission", "command": "touch notes.txt"])
        try await lead.screenShows { $0.contains("Do you want to proceed?") }
        before = world.steps.value.count
        world.look()
        let dialog = await world.step(after: before) { DeliveryWorld.refused($0) != nil }
        #expect(dialog.flatMap(DeliveryWorld.refused)?.contains("a dialog is open") == true, "\(String(describing: dialog))")
        #expect(lead.agent["mode"] as? String == "permission")
        #expect(world.pending(lead).first?.wokenAt == nil)
        // Answered, and its turn over: the wake-up goes.
        world.keys("1", into: lead)
        try await lead.waitFor { lead.agent["mode"] as? String == "working" }
        lead.tell(["op": "done"])
        try await lead.waitFor { lead.agent["mode"] as? String == "idle" }
        before = world.steps.value.count
        world.look()
        let typed = await world.step(after: before) { DeliveryWorld.typed($0) != nil }
        #expect(typed.flatMap(DeliveryWorld.typed)?.contains("1 new report") == true, "\(String(describing: typed))")
        try await lead.waitFor { world.prompts(lead).contains { $0.contains("1 new report") } }
        #expect(world.steps.value.compactMap(DeliveryWorld.typed).count == 1)
    }

    /// ComposerDeliveryTests' `afterTheAgentExitsToAShellNothingIsTypedIntoIt`, with its question case: the lead's agent
    /// exits with a prompt open, to the shell its session keeps; what waited for it (the user's words, a report) and
    /// what's sent after are never typed into that shell.
    @Test func afterTheAgentExitsToAShellNothingIsTypedIntoIt() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.lead(keepShell: true)
        let pid = try #require(lead.agentPid)
        lead.tell(["op": "permission", "command": "touch notes.txt"])
        try await lead.screenShows { $0.contains("Do you want to proceed?") }
        try world.post("echo LEAKED_$((6*7))", from: .user, to: lead)
        try world.post("echo LEAKED_$((6*8))", from: .system("witness"), to: lead)
        // It quits with the prompt open: the screen shows nothing open now, only its shell.
        lead.tell(["op": "exit"])
        try await lead.waitFor { kill(pid, 0) != 0 }
        world.keys("echo SHELL_$((2*3))\r", into: lead)
        try await lead.screenShows { $0.contains("SHELL_6") }
        let before = world.steps.value.count
        world.look()
        let refused = await world.step(after: before) { DeliveryWorld.refused($0) != nil }
        #expect(refused.flatMap(DeliveryWorld.refused)?.contains("doesn't run on its terminal") == true, "\(String(describing: refused))")
        // A message sent now is held, not typed.
        #expect(await world.deliver("echo LEAKED_$((6*9))", from: .user) == false)
        #expect(world.held().map(\.text) == ["echo LEAKED_$((6*9))"])
        world.look()
        await world.drained()
        #expect(!lead.screen.contains("LEAKED"), "\(lead.screen)")
        #expect(world.steps.value.compactMap(DeliveryWorld.typed).isEmpty, "\(world.steps.value)")
        #expect(world.typed.value.isEmpty)
        #expect(world.pending(lead).count == 2)
    }

    /// ComposerDeliveryTests' `aMessageStartingWithADigitIsTextAndCommandDigitAnswers`, the delivery half: with a
    /// prompt open nothing is typed, so the digit picks no option; once it's closed the words go in as one bracketed
    /// paste and its Enter, a prompt that starts with a digit.
    @Test func aWakeStartingWithADigitIsTextNotAnOptionKey() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.lead()
        lead.tell(["op": "permission", "command": "touch notes.txt"])
        try await lead.screenShows { $0.contains("Do you want to proceed?") }
        try world.post("1 more thing: keep the old parser", from: .user, to: lead)
        var before = world.steps.value.count
        world.look()
        let dialog = await world.step(after: before) { DeliveryWorld.refused($0) != nil }
        #expect(dialog.flatMap(DeliveryWorld.refused)?.contains("a dialog is open") == true, "\(String(describing: dialog))")
        #expect(lead.agent["mode"] as? String == "permission")
        // Declined (its third option, No): the box is back, empty.
        world.keys("3", into: lead)
        try await lead.waitFor { lead.agent["mode"] as? String == "idle" }
        before = world.steps.value.count
        world.look()
        let typed = await world.step(after: before) { DeliveryWorld.typed($0) != nil }
        #expect(typed.flatMap(DeliveryWorld.typed) == "1 more thing: keep the old parser")
        let writes = try #require(world.typed.value.last?.writes)
        #expect(writes.first?.bytes.starts(with: Array("\u{1B}[200~".utf8)) == true, "\(writes)")
        try await lead.waitFor { world.prompts(lead).contains("1 more thing: keep the old parser") }
        #expect(lead.agent["mode"] as? String == "idle")
    }

    /// The user's words that wait are typed as they are (never marked as VibeSwitcher's), and the reports that wait go
    /// along with them, through the prompt's hook.
    @Test func theUsersWordsAreTypedAsTheyAreAndTheReportsGoAlong() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.lead(idle: false)
        #expect(await world.deliver("please also add tests", from: .user, action: "action-1") == true)
        #expect(await world.deliver("The worker on parser says it's done.", from: .system("witness")) == true)
        // Its turn ends.
        try world.hook(lead, "Stop")
        let before = world.steps.value.count
        world.look()
        let typed = await world.step(after: before) { DeliveryWorld.typed($0) != nil }
        #expect(typed.flatMap(DeliveryWorld.typed) == "please also add tests")
        try await lead.waitFor { world.prompts(lead).contains("please also add tests") }
        #expect(lead.hookTakes(event: "UserPromptSubmit"))
        #expect(world.handed(lead).contains("The worker on parser says it's done."), "\(world.handed(lead))")
        #expect(world.pending(lead).isEmpty)
    }

    /// Between the look that decides to wake the lead and the moment of typing, the board names another lead: the one
    /// read first gets nothing, and its reports aren't marked as woken for.
    @Test func aLeadReplacedBeforeTheTypeGetsNothing() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.lead()
        try world.post("The worker on parser says it's done.", from: .system("witness"), to: lead)
        let repo = world.repo
        world.onStep.value = { step in
            guard case .screenRead = step else { return }
            try? BoardStore(root: repo).update { board in
                board.leadSession = UUID().uuidString
                board.leadPid = 999_999
                board.leadTTY = "ttypts999"
            }
        }
        let before = world.steps.value.count
        world.look()
        let refused = await world.step(after: before) { DeliveryWorld.refused($0) != nil }
        #expect(refused.flatMap(DeliveryWorld.refused)?.contains("the board names another lead") == true, "\(String(describing: refused))")
        await world.drained()
        #expect(world.typed.value.isEmpty)
        #expect(world.pending(lead).map(\.wokenAt) == [nil])
        #expect(!world.prompts(lead).contains { $0.contains("new report") })
    }

    /// ReplacedLeadRoutingTests' `aWakeUpReadsTheBoardOffTheMainThread`: waking an idle lead for its reports reads the
    /// board off the engine's queue, the lead it names before the wait and again once its screen is read.
    @Test func aWakeReadsTheBoardOffTheEngineQueue() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.lead()
        let looks = Locked<[(root: String, onEngine: Bool)]>([])
        world.queue.sync { world.engine.boardLooked = { root in looks.mutate { $0.append((root, world.onEngine)) } } }
        try world.post("worker x blocked", from: .system("witness"), to: lead)
        let before = world.steps.value.count
        world.look()
        let typed = await world.step(after: before) { DeliveryWorld.typed($0) != nil }
        #expect(typed.flatMap(DeliveryWorld.typed)?.contains("1 new report") == true, "\(String(describing: typed))")
        // In, its Enter too (the unit over before the host stops).
        try await lead.waitFor { world.prompts(lead).contains { $0.contains("1 new report") } }
        #expect(looks.value.filter { $0.root == world.repo && !$0.onEngine }.count >= 2, "\(looks.value)")
        #expect(!looks.value.contains { $0.onEngine })
    }

    /// ReplacedLeadRoutingTests' `aFlushReadsTheBoardOffTheMainThread`: the user's words waiting for an idle lead are
    /// typed once its box is empty, after the board is read off the engine's queue: it still names that lead.
    @Test func aFlushReadsTheBoardOffTheEngineQueue() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.lead()
        let looks = Locked<[(root: String, onEngine: Bool)]>([])
        world.queue.sync { world.engine.boardLooked = { root in looks.mutate { $0.append((root, world.onEngine)) } } }
        try world.post("make the films page", from: .user, to: lead)
        let before = world.steps.value.count
        world.look()
        let typed = await world.step(after: before) { DeliveryWorld.typed($0) != nil }
        #expect(typed.flatMap(DeliveryWorld.typed) == "make the films page")
        try await lead.waitFor { world.prompts(lead).contains("make the films page") }
        #expect(looks.value.contains { $0.root == world.repo && !$0.onEngine })
        #expect(!looks.value.contains { $0.onEngine })
    }

    /// The app's `ReportsWaiting`: reports that have waited too long to be woken for (the lead mid-turn, a draft, a
    /// dialog) are counted for the lead in `status`; once taken, none.
    @Test func reportsWaitingTooLongAreCountedInStatus() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.lead(idle: false)
        try world.post("The worker on parser says it's done.", from: .system("witness"), to: lead, age: LeadWake.shownAfter + 30)
        try world.post("The worker on lexer says it's done.", from: .system("witness"), to: lead, age: 1)
        world.look()
        #expect(await eventually(timeout: 60) { world.stored?.reportsWaiting == 2 }, "\(String(describing: world.stored))")
        #expect(world.stored?.value["reportsWaiting"]?.int == 2)
        // Taken at its next step: none waits.
        #expect(lead.hookTakes())
        world.look()
        #expect(await eventually(timeout: 60) { world.stored?.reportsWaiting == 0 }, "\(String(describing: world.stored))")
        #expect(world.steps.value.compactMap(DeliveryWorld.typed).isEmpty)
    }
}
