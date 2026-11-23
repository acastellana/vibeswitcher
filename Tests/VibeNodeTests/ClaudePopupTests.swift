import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// Claude Code's popups over an agent's input (`ClaudePopups.swift`; the acceptance run, 2026-11-20: 2.1.329's "Teach
/// auto mode about your environment?" sat over a scratch lead's box, and its worker's report and the user's `tell`
/// waited behind it). Declined with Esc on a team session, never Continue; the user's own session's `prompt`; a dialog
/// nothing reads on a team session said in `status`. Only fake sessions are typed into (AGENTS.md).
struct ClaudePopupScreenTests {
    /// As the acceptance run's scratch lead showed it (Claude Code 2.1.329).
    static let autoMode = """
     Teach auto mode about your environment?

     Claude Code reads this project, your recent Claude sessions, and optionally your shell history and other
     repositories. Claude analyzes this data and customizes auto mode to make better decisions.

       How you use Claude here     Mixed
     ❯ Also scan shell history     on
       Also scan your other repos  off
       Continue

     ↑/↓ to navigate · Space to toggle · Esc to cancel

    """

    @Test func theAutoModePopupIsKnownAndReadAsAQuestion() throws {
        #expect(ClaudePopup.on(Self.autoMode) == .autoModeSetup)
        #expect(LeadDelivery.box(in: Self.autoMode) != .empty)
        let menu = try #require(SessionPrompt.menu(on: Self.autoMode))
        #expect(menu.question.hasPrefix("Teach auto mode about your environment?\nClaude Code reads this project"), "\(menu.question)")
        #expect(menu.options == ["How you use Claude here", "Also scan shell history", "Also scan your other repos", "Continue"])
        #expect(menu.descriptions == ["Mixed", "on", "off", nil] && menu.selected == 1)
        // Its settings toggle with Space: `reply` leaves them to the terminal; Continue it may choose.
        #expect((0...2).allSatisfy { SessionPrompt.toggles(menu, $0) } && !SessionPrompt.toggles(menu, 3))
    }

    @Test func otherScreensAreNoPopup() {
        #expect(ClaudePopup.on(SessionPromptTests.trust) == nil)
        #expect(ClaudePopup.on("⏺ Done.\n" + String(repeating: "─", count: 40) + "\n❯ \n" + String(repeating: "─", count: 40) + "\n  ? for shortcuts") == nil)
        // Its title in the conversation, not the popup open.
        #expect(ClaudePopup.on("⏺ Teach auto mode about your environment?\n" + String(repeating: "─", count: 40) + "\n❯ \n"
                               + String(repeating: "─", count: 40) + "\n  ? for shortcuts") == nil)
    }
}

@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct ClaudePopupTests {
    private let scratch = Scratch()

    /// The supervisor's case: an idle lead behind the popup, a report waiting for it. Its delivery reads the popup where
    /// the box should be, Esc declines it (never Continue: nothing is scanned), and the wake-up goes in.
    @Test func aLeadsPopupIsDeclinedAndTheReportWaitingBehindItGetsThrough() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.lead()
        lead.tell(["op": "autoMode"])
        try await lead.screenShows { $0.contains("Teach auto mode about your environment?") }
        try world.post("The worker on parser says it's done.", from: .system("witness"), to: lead)
        let before = world.steps.value.count
        world.look()
        try await lead.waitFor { lead.agent["autoMode"] as? String == "declined" }
        let typed = await world.step(after: before) { DeliveryWorld.typed($0) != nil }
        #expect(typed.flatMap(DeliveryWorld.typed)?.contains("new report") == true, "\(String(describing: typed))")
        try await lead.waitFor { world.prompts(lead).contains { $0.contains("new report") } }
        #expect(world.queue.sync { world.engine.popupsDeclined.map(\.popup) } == [.autoModeSetup])
    }

    /// A worker's: the lead's message for it waits behind the popup, and goes in once it's declined.
    @Test func aWorkersPopupIsDeclinedAndTheMessageGoesIn() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        let worker = try await NodeHarness.start(on: world.host, fake: world.fake, cwd: world.repo, label: "Worker: parser")
        try await worker.screenShows { $0.contains("? for shortcuts") }
        try world.hook(worker, "Stop")
        worker.tell(["op": "autoMode"])
        try await worker.screenShows { $0.contains("Teach auto mode about your environment?") }
        #expect(await world.tell("Rebase on main, then run the tests.", session: worker.session.id) == .delivered)
        try await worker.waitFor { worker.agent["autoMode"] as? String == "declined" }
        try await worker.waitFor { world.prompts(worker).contains { $0.contains("Rebase on main, then run the tests.") } }
    }

    /// The scan reads a team session that needs you (no delivery waiting): its popup is declined all the same. The
    /// user's own session's popup is left alone, its `prompt`.
    @Test func theScanDeclinesATeamSessionsPopupAndLeavesTheUsersOwn() async throws {
        let world = try await DeliveryWorld.make(scratch, scan: true)
        defer { world.stop() }
        let sessions = try #require(world.sessions)
        let lead = try await world.lead()
        let mine = try await NodeHarness.start(on: world.host, fake: world.fake, cwd: world.repo, label: "Claude")
        try await mine.screenShows { $0.contains("? for shortcuts") }
        try world.hook(lead, "Notification")
        mine.tell(["op": "autoMode"])
        lead.tell(["op": "autoMode"])
        try await lead.waitFor { sessions.refresh(); return lead.agent["autoMode"] as? String == "declined" }
        let id = NodeIds.session(host: mine.session.id)
        try #require(await eventually(timeout: 60) { sessions.refresh(); return world.queue.sync { sessions.prompts.values[id] } != nil })
        #expect(world.queue.sync { sessions.prompts.values[id]?.menu.options.last } == "Continue")
        #expect(mine.agent["autoMode"] as? String == "open")
        #expect(world.queue.sync { world.engine.popupsDeclined.map(\.session) } == [lead.session.id])
    }

    /// A dialog nothing reads over a lead's box: nothing is typed, nothing pressed, and `status` says so once it has
    /// stayed; closed, the notice goes.
    @Test func aDialogNothingReadsOnALeadIsSaidInStatus() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.lead()
        let later = Locked<TimeInterval>(0)
        world.queue.sync { world.engine.popups.now = { Date().addingTimeInterval(later.value) } }
        lead.tell(["op": "dialog", "lines": [" Something new from Claude Code", "", " Press any key to go on"]])
        try await lead.screenShows { $0.contains("Something new from Claude Code") }
        try world.post("The worker on parser says it's done.", from: .system("witness"), to: lead)
        var before = world.steps.value.count
        world.look()
        let refused = await world.step(after: before) { DeliveryWorld.refused($0) != nil }
        #expect(refused.flatMap(DeliveryWorld.refused)?.contains("a dialog is open") == true, "\(String(describing: refused))")
        #expect(world.queue.sync { world.engine.unknownDialogNotices }.isEmpty, "not yet: a read mid-redraw isn't one")
        later.value = LeadEngine.unknownDialogAfter + 1
        before = world.steps.value.count
        world.look()
        _ = await world.step(after: before) { DeliveryWorld.refused($0) != nil }
        let notices = world.queue.sync { world.engine.unknownDialogNotices }
        #expect(notices.count == 1 && notices[0].contains("Something new from Claude Code") && notices[0].contains("can't read"), "\(notices)")
        #expect(lead.agent["mode"] as? String == "dialog" && world.queue.sync { world.engine.popupsDeclined.isEmpty })
        // Answered in its terminal: the wake-up goes, the notice with it.
        world.keys("\u{1B}", into: lead)
        try await lead.waitFor { lead.agent["mode"] as? String == "idle" }
        before = world.steps.value.count
        world.look()
        _ = await world.step(after: before) { DeliveryWorld.typed($0) != nil }
        #expect(world.queue.sync { world.engine.unknownDialogNotices }.isEmpty)
    }
}
