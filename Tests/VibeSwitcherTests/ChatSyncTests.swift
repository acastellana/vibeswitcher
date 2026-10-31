import CryptoKit
import Foundation
import Testing
import VibeCore
@testable import VibeHost
@testable import VibeSwitcher

/// 2026-10-19: "The chat view and the terminal view are still not really fully in sync … especially when there are
/// decisions or options or different buttons on one side or the other, and sometimes I'm sending and it goes through
/// on one side and not on the other side." Here a fake Claude Code (`FakeClaude`: its question, permission and
/// picker screens and keys, its transcript lines) runs on a real pty through a scratch session host (its own socket,
/// lock and key; never the user's), shown by the app's own terminal pane; the real ChatModel follows its transcript,
/// ChatSync reads the pane's screen into the answer card and types clicks and the composer's messages in, the outbox
/// keeps what's sent. Each case checks both sides: what the terminal shows, and what the chat shows one heartbeat
/// (`tick`, the window's 1 s timer) after the terminal changed.
@MainActor
@Suite(.serialized)
struct ChatSyncTests {
    let temp = Scratch()

    static let fruit: [String: Any] = ["question": "Which fruit?", "header": "Fruit", "multiSelect": false,
                                       "options": [["label": "Apple", "description": "A crisp apple."],
                                                   ["label": "Pear", "description": "A sweet pear."],
                                                   ["label": "Plum", "description": "A juicy plum."]]]
    static let toppings: [String: Any] = ["question": "Which toppings?", "header": "Toppings", "multiSelect": true,
                                          "options": [["label": "Cream", "description": "Whipped."],
                                                      ["label": "Nuts", "description": "Roasted."]]]

    // MARK: Questions

    @Test func theCardFollowsTheTerminalsTabEvenBackToAnAnsweredOne() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "ask", "questions": [Self.fruit, Self.toppings]])
        try await h.settle { $0.contains("Which fruit?") }
        var card = try h.requireCard()
        #expect(card.currentTab == 0 && card.question == "Which fruit?")
        #expect(card.options.map(\.label).prefix(3) == ["Apple", "Pear", "Plum"])
        #expect(card.position == "Question 1 of 2")

        // → in the terminal: the card is on Toppings, with Toppings' question and options.
        h.keys("\u{1b}[C")
        try await h.settle { $0.contains("Which toppings?") }
        card = try h.requireCard()
        #expect(card.currentTab == 1 && card.question == "Which toppings?", "\(card)")
        #expect(card.options.first?.label == "Cream", "\(card.options)")

        // Back with ←, answer Fruit with Enter (it moves on to Toppings), then back again to the answered Fruit.
        h.keys("\u{1b}[D")
        try await h.settle { $0.contains("Which fruit?") }
        h.keys("\r")
        try await h.settle { $0.contains("Which toppings?") && $0.contains("☒ Fruit") }
        #expect(h.card?.currentTab == 1 && h.card?.question == "Which toppings?")
        h.keys("\u{1b}[D")
        try await h.settle { $0.contains("Which fruit?") }
        card = try h.requireCard()
        #expect(card.currentTab == 0 && card.question == "Which fruit?", "\(card)")
        #expect(card.options.first?.label == "Apple")
        #expect(card.position == "Question 1 of 2")

        // On the Submit tab: the review's own question and buttons, not a question's.
        h.keys("\u{1b}[C\u{1b}[C")
        try await h.settle { $0.contains("Ready to submit your answers?") }
        card = try h.requireCard()
        #expect(card.currentTab == 2, "\(card)")
        // The review's own text, as the terminal shows it: the answers so far, then its question (the questions' own
        // text appears only as what was answered, never as the question being asked).
        #expect(card.question.hasSuffix("Ready to submit your answers?") && card.question.contains("● Which fruit?\n→ Apple"),
                "\(card.question)")
        #expect(card.options.map(\.label) == ["Submit answers", "Cancel"])
        #expect(card.position == nil)
    }

    /// A question's card is up within 1.2 s of the terminal drawing it, on the window's 1 s heartbeat: the read that
    /// first sees it isn't taken (two reads must agree), and the confirm read it asks for is (`ChatSync.confirmAfter`),
    /// not the next heartbeat's a second later. The heartbeat's first read comes 0.3 s after the terminal drew it.
    @Test func aQuestionsCardIsUpWithin1Point2SOfTheTerminalDrawingIt() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "ask", "questions": [Self.fruit]])
        try await h.paneShows { $0.contains("Which fruit?") }
        let drawn = Date()
        let heartbeat = Task { @MainActor in
            try await Task.sleep(nanoseconds: 300_000_000)
            while !Task.isCancelled {
                h.tickNow()
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        defer { heartbeat.cancel() }
        #expect(await until(timeout: 30) { h.chat.menu != nil })
        let took = Date().timeIntervalSince(drawn)
        #expect(took < 1.2, "the card took \(took) s")
        #expect(h.card?.question == "Which fruit?")
    }

    @Test func aClickInChatMovesTheTerminalAndTheCardKeepsUp() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "ask", "questions": [Self.fruit, Self.toppings]])
        try await h.settle { $0.contains("Which fruit?") }
        // Pear: Fruit is answered in the terminal, which goes on to Toppings.
        h.click(1)
        try await h.waitFor { h.agent["answers"].map { "\($0)" }?.contains("Pear") == true }
        try await h.settle { $0.contains("Which toppings?") }
        #expect(h.card?.currentTab == 1 && h.card?.question == "Which toppings?", "\(String(describing: h.card))")
        // A tab clicked in the card: the terminal goes there.
        h.clickTab(0)
        try await h.settle { $0.contains("Which fruit?") }
        #expect(h.card?.currentTab == 0)
        #expect(h.agent["tab"] as? Int == 0)
    }

    @Test func aMultiSelectShowsItsTicksAndSubmitsFromEitherSide() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "ask", "questions": [Self.toppings]])
        try await h.settle { $0.contains("Which toppings?") }
        var card = try h.requireCard()
        #expect(card.multiSelect)
        #expect(card.options.prefix(2).map(\.label) == ["Cream", "Nuts"], "\(card.options)")
        #expect(card.options.prefix(2).map(\.checked) == [false, false])
        #expect(card.submit == "Submit")
        #expect(card.options.contains { $0.kind == .other }, "\(card.options)")

        // Ticked in chat: ticked in the terminal, and the card shows the tick once the screen does.
        h.click(0)
        try await h.waitFor { (h.agent["checked"] as? [[Int]])?.first == [0] }
        try await h.settle { $0.contains("[✔] Cream") }
        card = try h.requireCard("the card is gone after a tick")
        #expect(card.options.prefix(2).map(\.checked) == [true, false])
        // Ticked in the terminal (2 toggles Nuts): the card shows it.
        h.keys("2")
        try await h.settle { $0.contains("[✔] Nuts") }
        #expect(h.card?.options.prefix(2).map(\.checked) == [true, true])
        // The terminal's cursor on its Submit row: the card stays.
        h.keys("\u{1b}[B\u{1b}[B\u{1b}[B")
        try await h.settle { $0.contains("❯    Submit") }
        card = try h.requireCard("the card vanished with the cursor on Submit")
        #expect(card.selected == card.options.count)
        // Submit from chat: on to the review; Submit answers from chat: answered, the card gone, the answer in chat.
        try h.clickSubmit()
        try await h.settle { $0.contains("Ready to submit your answers?") }
        #expect(h.card?.options.map(\.label) == ["Submit answers", "Cancel"])
        h.click(0)
        try await h.waitFor { h.agent["mode"] as? String == "working" }
        try await h.settle { !$0.contains("Submit answers") }
        #expect(h.card == nil)
        #expect(h.chat.log.pendingQuestions == nil)
        #expect(h.answers.contains("Cream, Nuts"), "answers: \(h.answers)")
    }

    @Test func submittedWithKeysInTheTerminalTheCardGoesAndTheAnswerShows() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "ask", "questions": [Self.fruit, Self.toppings]])
        try await h.settle { $0.contains("Which fruit?") }
        h.keys("\u{1b}[B\r")    // Pear
        try await h.settle { $0.contains("Which toppings?") }
        h.keys("1")             // Cream
        try await h.settle { $0.contains("[✔] Cream") }
        h.keys("\u{1b}[B\u{1b}[B\u{1b}[B\r")    // Submit
        try await h.settle { $0.contains("Ready to submit your answers?") }
        #expect(h.card?.currentTab == 2, "\(String(describing: h.chat.menu))")
        h.keys("\r")
        try await h.settle { !$0.contains("Ready to submit") }
        #expect(h.card == nil)
        #expect(h.answers.contains("Pear") && h.answers.contains("Cream"), "answers: \(h.answers)")
    }

    @Test func aSecondClickBeforeTheScreenMovedIsntSentToTheNextQuestion() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "ask", "questions": [Self.fruit, Self.toppings]])
        try await h.settle { $0.contains("Which fruit?") }
        // Two quick clicks on Fruit's Plum, a heartbeat between them that still sees Fruit (the keys aren't in yet):
        // the second must not land on Toppings (where 2 down + Enter ticks the free-text row) as if it were Fruit's.
        h.click(2)
        h.sync.readScreen()
        h.click(2)
        try await h.waitFor { h.agent["answers"].map { "\($0)" }?.contains("Plum") == true }
        try await h.settle { $0.contains("Which toppings?") }
        try await h.quiet()
        #expect((h.agent["checked"] as? [[Int]]) == [[], []], "\(h.agent)")
        #expect(h.agent["tab"] as? Int == 1)
    }

    @Test func aClickOnAQuestionThatChangedIsntSentButOneTheCursorMovedOnIs() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "ask", "questions": [Self.fruit, Self.toppings]])
        try await h.settle { $0.contains("Which fruit?") }
        // Only the cursor moved in the terminal (Pear), not yet read by the chat: a click on Plum still answers Plum.
        h.keys("\u{1b}[B")
        try await h.paneShows { $0.contains("❯ 2. Pear") }
        h.click(2)
        try await h.waitFor { h.agent["answers"].map { "\($0)" }?.contains("Plum") == true }
        #expect(h.chat.answerNotice == nil)
        try await h.settle { $0.contains("Which toppings?") }
        // The terminal moved on to another question the chat hasn't read: a click on the old one sends nothing.
        h.keys("\u{1b}[D")
        try await h.settle { $0.contains("Which fruit?") }
        let drawn = try h.requireMenu()
        h.keys("\u{1b}[C")
        try await h.paneShows { $0.contains("Which toppings?") }
        h.click(0, drawn: drawn)
        try await h.quiet()
        #expect((h.agent["checked"] as? [[Int]]) == [[], []], "\(h.agent)")
        #expect(h.chat.answerNotice == "That question changed; here it is now.")
    }

    // MARK: Permission prompts and pickers

    @Test func aPermissionPromptAnsweredInChatOrInTheTerminal() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "permission", "command": "touch /tmp/x"])
        try await h.settle { $0.contains("Do you want to proceed?") }
        var card = try h.requireCard()
        #expect(card.options.map(\.label) == ["Yes", "Yes, and don't ask again for this command", "No, and tell Claude what to do differently (esc)"])
        // The terminal's cursor moves: the card's selection follows.
        h.keys("\u{1b}[B")
        try await h.settle { $0.contains("❯ 2.") }
        #expect(h.card?.selected == 1)
        // Allow always, from chat.
        h.click(1)
        try await h.waitFor { h.agent["reply"] as? String == "Allowed always." }
        try await h.settle { !$0.contains("Do you want to proceed?") }
        #expect(h.card == nil)

        // Another, denied with a key in the terminal: the card goes.
        // Another: the terminal's cursor moves and, before the chat reads it, No is clicked in chat: it's still No.
        h.tell(["op": "permission", "command": "rm -rf build"])
        try await h.settle { $0.contains("rm -rf build") && $0.contains("Do you want to proceed?") }
        card = try h.requireCard()
        #expect(card.selected == 0)
        h.keys("\u{1b}[B")
        try await h.paneShows { $0.contains("❯ 2.") }
        h.click(2)
        try await h.waitFor { h.agent["reply"] as? String == "Denied." }
        #expect(h.chat.answerNotice == nil)
        try await h.settle { !$0.contains("Do you want to proceed?") }
        #expect(h.card == nil)

        // And one denied with a key in the terminal: the card goes.
        h.tell(["op": "permission", "command": "rm -rf dist"])
        try await h.settle { $0.contains("rm -rf dist") && $0.contains("Do you want to proceed?") }
        #expect(h.card != nil)
        h.keys("3")
        try await h.settle { !$0.contains("Do you want to proceed?") }
        #expect(h.card == nil)
        #expect(h.agent["reply"] as? String == "Denied.")
    }

    @Test func theSlashMenuFromEitherSideAndEscClosesBoth() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        // "/" typed in the terminal: its menu is the card.
        h.keys("/")
        try await h.settle { $0.contains("❯ /clear") }
        var card = try h.requireCard()
        #expect(card.commands)
        #expect(card.options.map(\.label) == ["/clear", "/compact", "/help", "/model"])
        #expect(card.options.first?.detail == "Clear conversation history")
        #expect(card.selected == 0)
        // Arrows in the terminal: the card follows.
        h.keys("\u{1b}[B")
        try await h.settle { $0.contains("❯ /compact") }
        #expect(h.card?.selected == 1)
        // Narrowed by typing: the card too.
        h.keys("c")
        try await h.settle { !$0.contains("/help") && $0.contains("❯ /clear") }
        card = try h.requireCard()
        #expect(card.options.map(\.label) == ["/clear", "/compact"])
        // /compact chosen in chat (after the terminal's cursor moved, unread): the terminal runs it, both close.
        h.keys("\u{1b}[B")
        try await h.paneShows { $0.contains("❯ /compact") }
        h.click(1)
        try await h.waitFor { h.agent["ran"] as? String == "/compact" }
        try await h.settle { !$0.contains("/clear") }
        #expect(h.card == nil)

        // Esc in the terminal closes it, and the card.
        h.keys("/")
        try await h.settle { $0.contains("❯ /clear") }
        #expect(h.card != nil)
        h.keys("\u{1b}")
        try await h.settle { !$0.contains("/clear") }
        #expect(h.card == nil)
        // Close (Esc) in chat does the same.
        h.keys("\u{7f}/")
        try await h.settle { $0.contains("❯ /clear") }
        #expect(h.card?.commands == true)
        h.sync.cancel()
        try await h.paneShows { !$0.contains("/clear") }
        await h.tick()
        #expect(h.card == nil)
        #expect(h.agent["dismissed"] as? Bool == true)
    }

    @Test func theModelPickerAnsweredFromEitherSide() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.send("/model")
        try await h.settle { $0.contains("Select model") }
        #expect(h.card?.options.map(\.label).prefix(2) == ["Default (recommended)  ✔", "Opus"])
        #expect(h.chat.outbox.outbox.entries.isEmpty)
        h.keys("\u{1b}[B")
        try await h.settle { $0.contains("❯ 2. Opus") }
        #expect(h.card?.selected == 1)
        // The cursor moves on in the terminal; Opus clicked in chat before it's read: Opus.
        h.keys("\u{1b}[B")
        try await h.paneShows { $0.contains("❯ 3. Haiku") }
        h.click(1)
        try await h.waitFor { h.agent["model"] as? String == "Opus" }
        try await h.settle { !$0.contains("Select model") }
        #expect(h.card == nil)
    }

    // MARK: Free text

    @Test func otherTypedInChatIsTheTerminalsFreeText() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "ask", "questions": [Self.fruit]])
        try await h.settle { $0.contains("Which fruit?") }
        let other = try h.requireOther()
        h.click(other.index, typing: "Mango")
        try await h.waitFor { h.agent["mode"] as? String == "working" }
        try await h.settle { !$0.contains("Which fruit?") }
        #expect(h.card == nil)
        #expect(h.answers.contains("\"Which fruit?\"=\"Mango\""), "answers: \(h.answers)")

        // A multi-select's free text: typed in, ticked, and left ticked (Enter there would untick it).
        h.tell(["op": "ask", "questions": [Self.toppings]])
        try await h.settle { $0.contains("Which toppings?") }
        let row = try h.requireOther()
        h.click(row.index, typing: "Sprinkles")
        try await h.waitFor { (h.agent["texts"] as? [String: String])?["0"] == "Sprinkles" }
        try await h.quiet()
        #expect((h.agent["checked"] as? [[Int]]) == [[row.index]], "\(h.agent)")
        try await h.settle { $0.contains("[✔] Sprinkles") }
        #expect(h.card?.otherText == "Sprinkles")
    }

    @Test func freeTextTypedInTheTerminalShowsInChat() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "ask", "questions": [Self.fruit]])
        try await h.settle { $0.contains("Which fruit?") }
        h.keys("\u{1b}[B\u{1b}[B\u{1b}[B")
        h.keys("Kiwi")
        try await h.settle { $0.contains("4. Kiwi") }
        let card = try h.requireCard()
        #expect(card.options.contains { $0.kind == .other }, "\(card.options)")
        #expect(card.otherText == "Kiwi")
    }

    // MARK: The composer while a question is open

    @Test func aSendWhileAPermissionPromptIsOpenWaitsForTheAnswer() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "permission", "command": "touch /tmp/x"])
        try await h.settle { $0.contains("Do you want to proceed?") }
        // "1 more thing" typed into the prompt would answer it (1 is Yes).
        let entry = h.send("1 more thing, then stop")
        try await h.quiet()
        #expect(h.agent["mode"] as? String == "permission", "\(h.agent)")
        #expect(h.card != nil)
        #expect(h.chat.pending.map(\.id) == [entry.id])
        #expect(h.chat.outbox.entry(entry.id)?.state == .held, "\(String(describing: h.chat.outbox.entry(entry.id)))")
        #expect(h.chat.sendNotice != nil)
        // However long it's held, it's waiting, never late ("It may not have reached the agent").
        h.chat.now = { Date().addingTimeInterval(60) }
        await h.tick()
        let held = try #require(h.chat.pending.first)
        #expect(h.chat.late.isEmpty)
        #expect(h.chat.note(for: held) == .held)
        #expect(h.chat.outbox.entry(entry.id)?.state == .held)
        h.chat.now = Date.init
        // Answered (in the terminal): the message goes in then (queued behind the turn the answer started, so not
        // expected at once), and shows once.
        h.keys("1")
        try await h.settle { !$0.contains("Do you want to proceed?") }
        // (The window's heartbeat reads the screen every second: it sees the question gone, and types the message in.)
        try await h.waitFor {
            h.tickNow()
            return h.agent["queued"].map { "\($0)" }?.contains("1 more thing") == true
        }
        let released = try #require(h.chat.pending.first)
        #expect(h.chat.note(for: released) == .queued)
        #expect(h.chat.outbox.entry(entry.id)?.state != .held)
        h.tell(["op": "take"])
        try await h.waitFor {
            h.tickNow()
            return h.prompts.contains("1 more thing, then stop")
        }
        #expect(h.prompts.filter { $0 == "1 more thing, then stop" }.count == 1)
        #expect(h.chat.pending.isEmpty)
        #expect(h.chat.outbox.outbox.entries.isEmpty)
    }

    @Test func aRunOrAChipWhileAPromptIsOpenIsRefusedNotLost() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "permission", "command": "touch /tmp/x"])
        try await h.settle { $0.contains("Do you want to proceed?") }
        // Not from the composer's outbox (a code block's Run, a /command chip): nothing would send it later.
        #expect(!h.sync.type("!ls"))
        #expect(!h.sync.type("/compact"))
        try await h.quiet()
        #expect(h.agent["mode"] as? String == "permission")
        #expect(h.chat.outbox.outbox.entries.isEmpty)
    }

    @Test func aSendWhileAQuestionOffersFreeTextIsItsAnswer() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "ask", "questions": [Self.fruit]])
        try await h.settle { $0.contains("Which fruit?") }
        h.send("A ripe mango")
        try await h.waitFor { h.agent["mode"] as? String == "working" }
        await h.tick()
        #expect(h.answers.contains("\"Which fruit?\"=\"A ripe mango\""), "answers: \(h.answers)")
        try await h.settle { !$0.contains("Which fruit?") }
        #expect(h.card == nil)
        #expect(h.chat.pending.isEmpty)
        #expect(h.chat.outbox.outbox.entries.isEmpty)
        #expect(!h.prompts.contains("A ripe mango"))
    }

    // MARK: Sends

    @Test func anIdleSendIsPendingThenThePromptOnce() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        let entry = h.send("hello there")
        #expect(h.chat.pending.map(\.id) == [entry.id])
        try await h.waitFor { h.agentPrompts.contains("hello there") }
        // Every heartbeat until it shows: never both the pending bubble and the prompt, never twice.
        try await h.waitFor {
            h.tickNow()
            let shown = h.prompts.filter { $0 == "hello there" }.count
            #expect(shown <= 1)
            #expect(!(shown == 1 && !h.chat.pending.isEmpty))
            return shown == 1
        }
        #expect(h.chat.pending.isEmpty)
        #expect(h.chat.outbox.outbox.entries.isEmpty)
        try await h.paneShows { $0.contains("Got: hello there") }
    }

    @Test func aSendTheHostDidntTypeShowsFailedAndSendNowWorks() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        // The session it went to is gone from the host.
        h.targetID = UUID()
        let entry = h.send("did you get this?")
        try await h.waitFor { h.chat.outbox.entry(entry.id)?.state == .failed }
        #expect(h.chat.pending.isEmpty)
        #expect(h.chat.outbox.outbox.needsYou(key: h.key).map(\.id) == [entry.id])
        h.targetID = nil
        guard let failed = h.chat.outbox.entry(entry.id) else { throw HarnessError.timedOut }
        h.chat.resend(failed, working: false, send: h.sync.type)
        try await h.waitFor { h.agentPrompts.contains("did you get this?") }
        try await h.waitFor {
            h.tickNow()
            return h.prompts.contains("did you get this?")
        }
        #expect(h.prompts.filter { $0 == "did you get this?" }.count == 1)
        #expect(h.agentPrompts.filter { $0 == "did you get this?" }.count == 1)
        #expect(h.chat.outbox.outbox.entries.isEmpty)
        #expect(h.chat.pending.isEmpty)
    }

    @Test func aSendDuringTheTurnIsQueuedOnBothSidesAndClearsOnBothWhenTaken() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "work"])
        try await h.settle { $0.contains("Working") }
        h.working = true
        let entry = h.send("also update the docs", queue: true)
        try await h.paneShows { $0.contains("⎿ also update the docs") }
        h.tickNow()
        #expect(h.chat.pending.map(\.id) == [entry.id])
        #expect(h.chat.pending.first?.expectsSoon == false)
        // The agent takes it at its next step.
        h.tell(["op": "take"])
        try await h.paneShows { !$0.contains("⎿ also update the docs") }
        try await h.waitFor {
            h.tickNow()
            return h.prompts.contains("also update the docs")
        }
        await h.tick()
        #expect(h.prompts.filter { $0 == "also update the docs" }.count == 1)
        #expect(h.chat.pending.isEmpty)
        #expect(h.chat.outbox.outbox.entries.isEmpty)
    }

    /// In the test's scratch folder, and in one spelled `/private/tmp/…` whatever TMPDIR is (a verifier's is there:
    /// 2026-10-19, the steer reached the agent as not the user's, see `SteerSeal.place`).
    @Test(arguments: [nil, "/private/tmp"] as [String?])
    func aSteerDuringTheTurnWaitsOnBothSidesAndClearsOnBothWhenTaken(in folder: String?) async throws {
        let h = try await Harness.start(temp, in: folder.map { URL(fileURLWithPath: $0, isDirectory: true) })
        defer { h.stop() }
        h.tell(["op": "work"])
        try await h.settle { $0.contains("Working") }
        h.working = true
        // ↩ while it works: steered (its hook hands it over at the next step), not typed.
        let entry = h.send("use the staging database")
        #expect(h.chat.pending.isEmpty)
        // Posted off the main thread: in the strip as sending, and in the outbox, until it's in the inbox.
        #expect(h.chat.steering.map(\.text) == ["use the staging database"])
        #expect(h.chat.outbox.entry(entry.id)?.state == .sending)
        try await h.waitFor { h.chat.steerSending.isEmpty }
        #expect(h.chat.outbox.entry(entry.id) == nil)
        #expect(h.chat.pending.isEmpty)
        await h.tick()
        // Waiting on both sides: the chat's steering strip, and the agent's inbox its hook reads.
        #expect(h.chat.steering.map(\.text) == ["use the staging database"])
        #expect(SteerInbox.pending(tty: h.session.tty, root: h.steerRoot).map(\.text) == ["use the staging database"])
        try await h.quiet()
        #expect(!h.screen.contains("use the staging database"))
        // The agent's next step: its hook takes it.
        h.hookTakes()
        #expect(SteerInbox.pending(tty: h.session.tty, root: h.steerRoot).isEmpty)
        try await h.waitFor {
            h.tickNow()
            return h.chat.log.entries.contains { $0.kind == .steered(text: "use the staging database", fromLead: false) }
        }
        await h.tick()
        #expect(h.chat.steering.isEmpty)
        #expect(h.chat.log.entries.filter { $0.kind == .steered(text: "use the staging database", fromLead: false) }.count == 1)
        #expect(h.chat.outbox.outbox.entries.isEmpty)
    }

    @Test func typedStraightIntoTheTerminalShowsAsAPromptAndLeavesNothingStale() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        // A send the host didn't confirm, then the same text typed in the terminal.
        h.targetID = UUID()
        let entry = h.send("run the tests")
        try await h.waitFor { h.chat.outbox.entry(entry.id)?.state == .failed }
        h.targetID = nil
        h.keys("run the tests")
        h.keys("\r")
        try await h.waitFor { h.agentPrompts.contains("run the tests") }
        try await h.waitFor {
            h.tickNow()
            return h.prompts.contains("run the tests")
        }
        #expect(h.chat.outbox.outbox.entries.isEmpty)
        #expect(h.chat.pending.isEmpty)
        // And one typed mid-turn: in chat as a prompt once the agent takes it.
        h.tell(["op": "work"])
        try await h.settle { $0.contains("Working") }
        h.keys("and the lint")
        h.keys("\r")
        try await h.paneShows { $0.contains("⎿ and the lint") }
        h.tell(["op": "take"])
        try await h.paneShows { !$0.contains("⎿ and the lint") }
        try await h.waitFor {
            h.tickNow()
            return h.prompts.contains("and the lint")
        }
        await h.tick()
        #expect(h.prompts.filter { $0 == "and the lint" }.count == 1)
        #expect(h.chat.pending.isEmpty)
        #expect(h.chat.outbox.outbox.entries.isEmpty)
    }

    @Test func anAnswerWithKeysInTheTerminalClearsTheCardAndShowsTheChoice() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "ask", "questions": [Self.fruit]])
        try await h.settle { $0.contains("Which fruit?") }
        #expect(h.card != nil)
        h.keys("\u{1b}[B\u{1b}[B\r")
        try await h.settle { !$0.contains("Which fruit?") }
        #expect(h.card == nil)
        #expect(h.chat.log.pendingQuestions == nil)
        #expect(h.answers.contains("\"Which fruit?\"=\"Plum\""), "answers: \(h.answers)")
    }

    // MARK: Keys (WC-1)

    @Test func twoPressedInTheWindowAnswersOptionTwoInTheTerminal() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "ask", "questions": [Self.fruit]])
        try await h.settle { $0.contains("Which fruit?") }
        #expect(h.press(.digit(2), composer: "") == "")
        try await h.waitFor { h.agent["mode"] as? String == "working" }
        try await h.settle { !$0.contains("Which fruit?") }
        #expect(h.answers.contains("\"Which fruit?\"=\"Pear\""), "answers: \(h.answers)")
        #expect(h.card == nil)
        // Answered, not sent: no "2" as a message, held or typed.
        #expect(h.chat.outbox.outbox.entries.isEmpty)
        #expect(!h.prompts.contains("2") && !h.agentPrompts.contains("2"))
    }

    @Test func twoPressedWithTextInTheComposerIsTheTextsAndTheQuestionStaysOpen() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "ask", "questions": [Self.fruit]])
        try await h.settle { $0.contains("Which fruit?") }
        #expect(h.press(.digit(2), composer: "Version ") == "Version 2")
        // ↑ / ↓ and ↩ with text are the box's too.
        #expect(h.press(.down, composer: "Version 2") == "Version 2")
        #expect(h.press(.enter, composer: "Version 2") == "Version 2")
        try await h.quiet()
        #expect(h.agent["mode"] as? String == "question", "\(h.agent)")
        #expect(h.card?.question == "Which fruit?")
        #expect(h.screen.contains("❯ 1. Apple"), "\(h.screen)")
        #expect(h.chat.outbox.outbox.entries.isEmpty)
    }

    @Test func theArrowsMoveTheHighlightAndReturnAnswersIt() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "ask", "questions": [Self.fruit]])
        try await h.settle { $0.contains("Which fruit?") }
        // From the terminal's cursor (Apple), down twice to Plum; down again stops at the last row, up comes back.
        #expect(h.press(.down, composer: "") == "")
        #expect(h.press(.down, composer: "") == "")
        #expect(h.cardKeys.highlight == 2)
        // Only the card's highlight moved: the terminal's cursor waits for ↩.
        try await h.quiet()
        #expect(h.screen.contains("❯ 1. Apple"), "\(h.screen)")
        #expect(h.press(.enter, composer: "") == "")
        try await h.waitFor { h.agent["mode"] as? String == "working" }
        await h.tick()
        #expect(h.answers.contains("\"Which fruit?\"=\"Plum\""), "answers: \(h.answers)")
        #expect(h.chat.outbox.outbox.entries.isEmpty)
    }
}

/// A scratch host running the fake Claude Code, the app's terminal pane showing it, and the chat following it.
@MainActor
final class Harness {
    let server: HostServer
    let socket: String
    /// The app's key its client proves itself with, in memory: never the Keychain's.
    let keyStore: AppProof.MemoryStore
    let host: HostClient
    let pane: TerminalPaneController
    let chat: ChatModel
    let sync: ChatSync
    let transcript: URL, control: URL, state: URL
    /// The steer inbox (`SteerInbox`'s root), scratch.
    let steerRoot: URL
    /// The folder the harness's files are in (the test's scratch folder unless a case names one).
    let scratch: URL
    let key = "host:harness"
    var session: HostSession!
    /// Where the chat sends (nil: the fake agent's session).
    var targetID: UUID?
    /// The agent is in its turn, as the composer sees it.
    var working = false
    /// The agent the window's row has (nil: its session is gone, the terminal a shell).
    var targetAgent: Agent? = .claude

    private init(_ temp: Scratch, in folder: URL?, keepShell: Bool) throws {
        let launcher = Bundle(for: HarnessAnchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("vibeswitcher-host").path
        socket = try temp.shortFolder("vsh-sync") + "/h.sock"
        let key = SymmetricKey(size: .bits256)
        scratch = folder ?? scratchRoot
        let home = (folder.map { temp.adopt($0.appendingPathComponent("sync-home-\(UUID().uuidString)")) } ?? temp.url("sync-home"))
            .resolvingSymlinksInPath()
        let folder = home.appendingPathComponent(".claude/projects/-tmp-fake")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        transcript = folder.appendingPathComponent("\(UUID().uuidString).jsonl")
        // The session's first turn (a transcript is written with the first message).
        let first = [#"{"type":"user","uuid":"u0","timestamp":"2026-10-19T08:00:00.000Z","message":{"role":"user","content":"start"}}"#,
                     #"{"type":"assistant","uuid":"a0","timestamp":"2026-10-19T08:00:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Ready."}]}}"#]
        FileManager.default.createFile(atPath: transcript.path, contents: Data((first.joined(separator: "\n") + "\n").utf8))
        control = home.appendingPathComponent("control.jsonl")
        FileManager.default.createFile(atPath: control.path, contents: nil)
        state = home.appendingPathComponent("state.json")
        let script = home.appendingPathComponent("fake_claude.py")
        try FakeClaude.script.write(to: script, atomically: true, encoding: .utf8)
        var config = HostServer.Config(socketPath: socket, lockPath: socket + ".lock", shell: "/bin/sh", launcher: launcher,
                                       baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": home.path],
                                       hostBuild: HostBuild.id(ofExecutableAt: HostClient.hostExecutable.path))
        config.idleExit = nil
        config.appKey = key
        config.appExecutable = HostServer.executable(of: getpid())
        server = HostServer(config: config)
        try server.start()
        keyStore = AppProof.MemoryStore(key: key)
        host = HostClient(socketPath: socket, appKey: { [keyStore] in keyStore.key() })
        pane = TerminalPaneController(host: host)
        steerRoot = home.appendingPathComponent("vibeswitcher")
        chat = ChatModel(outbox: ComposerOutbox(url: home.appendingPathComponent("outbox.json")), home: home.path, steerRoot: steerRoot)
        sync = ChatSync(chat: chat, host: host)
        // Kept a shell: the agent runs under it, and the shell is the terminal's once it exits.
        command = (keepShell ? "" : "exec ") + "/usr/bin/python3 -I -u '\(script.path)' '\(transcript.path)' '\(control.path)' '\(state.path)'"
        self.keepShell = keepShell
    }

    private let command: String
    private let keepShell: Bool

    /// `keepShell`: the session keeps a shell open once the agent exits (as the Shell preset, or a preset's "Keep a
    /// shell open after it exits").
    static func start(_ temp: Scratch, in folder: URL? = nil, keepShell: Bool = false) async throws -> Harness {
        let h = try Harness(temp, in: folder, keepShell: keepShell)
        #expect(h.placesAreScratch, "the harness reads and writes outside its scratch: \(h.places)")
        h.host.connectIfRunning()
        #expect(await until { h.host.state == .connected })
        var result: Result<HostSession, HostClientError>?
        h.host.spawn(SpawnRequest(cwd: "/tmp", command: h.command, env: [:], cols: 100, rows: 40, keepShell: h.keepShell,
                                  label: "Fake Claude", agent: "claude")) { result = $0 }
        #expect(await until { result != nil })
        h.session = try #require(result).get()
        h.pane.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 900)
        h.pane.show(hostID: h.session.id, focus: false)
        h.sync.target = { [weak h] in
            guard let h else { return nil }
            return ChatSync.Target(id: h.targetID ?? h.session.id, key: h.key, agent: h.targetAgent, needsInput: false,
                                   working: h.working || h.agent["mode"] as? String == "working")
        }
        h.sync.screen = { [weak h] id in h?.pane.screenText(id) ?? ScreenRead() }
        h.sync.bracketedPaste = { [weak h] id in h?.pane.bracketedPaste(id) ?? false }
        h.chat.show(path: h.transcript.path, key: h.key)
        #expect(await until(timeout: Harness.wait) { h.chat.state == .ready })
        try await h.paneShows { $0.contains("? for shortcuts") }
        // The agent draws before it writes its state: its first screen can be up while `agent` is still empty (its pid
        // read nil under load, 2026-10-23).
        try await h.waitFor { h.agent["pid"] != nil }
        return h
    }

    /// Where the harness reads and writes: its steer inbox, the chat's home (the fake agent's transcript), the fake
    /// agent's state and control files, and its host's socket.
    var places: [String] { files + [socket] }
    private var files: [String] { [steerRoot.path, chat.steerRoot.path, chat.home, transcript.path, state.path, control.path] }

    /// Each place is the test's own: the files in its scratch folder, the socket in a short scratch one (a socket's
    /// path can't be as long as a scratch folder's), and none in the real home's or this HOME's `.vibeswitcher` or `.claude`.
    var placesAreScratch: Bool {
        // `/tmp/x` and `/private/tmp/x` are one place (Foundation spells it either way).
        func spelled(_ path: String) -> String {
            let standard = (path as NSString).standardizingPath
            return standard.hasPrefix("/private/") ? String(standard.dropFirst("/private".count)) : standard
        }
        func inside(_ path: String, _ folder: String) -> Bool { spelled(path) == spelled(folder) || spelled(path).hasPrefix(spelled(folder) + "/") }
        let realHome = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        let theirs = [realHome, NSHomeDirectory()].flatMap { [$0 + "/.vibeswitcher", $0 + "/.claude"] }
        return files.allSatisfy { inside($0, scratch.path) } && spelled(socket).hasPrefix(spelled(shortScratchRoot) + "/vsh-sync-")
            && !places.contains { place in theirs.contains { inside(place, $0) } }
    }

    func stop() {
        pane.detachAll()
        server.stop(terminateSessions: true)
        unlink(socket + ".lock")
    }

    // MARK: The terminal

    /// The app's terminal pane's screen.
    var screen: String { pane.screenLines(session.id).joined(separator: "\n") }

    /// What the fake agent says it's at (see `FakeClaude`).
    var agent: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: state))) as? [String: Any] ?? [:]
    }

    /// Keys typed in the terminal (the pane sends what you type there the same way).
    func keys(_ text: String) {
        host.send(session.id, bytes: Data(text.utf8), reply: false)
    }

    func tell(_ command: [String: Any]) {
        let line = try! JSONSerialization.data(withJSONObject: command) + Data("\n".utf8)
        let handle = try! FileHandle(forWritingTo: control)
        handle.seekToEndOfFile()
        handle.write(line)
        try? handle.close()
    }

    func paneShows(sourceLocation: SourceLocation = #_sourceLocation, _ condition: (String) -> Bool) async throws {
        let shown = await VibeSwitcherTests.until(timeout: Self.wait) { condition(self.screen) }
        if !shown {
            Issue.record("the terminal never showed it:\n\(screen)", sourceLocation: sourceLocation)
            throw HarnessError.timedOut
        }
    }

    /// What the terminal or the agent must get to (a chat that never does fails here, after a minute, not 5).
    static let wait: TimeInterval = 90

    func waitFor(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        let met = await VibeSwitcherTests.until(timeout: Self.wait, condition)
        if !met {
            let tail = ((try? String(contentsOf: transcript, encoding: .utf8)) ?? "").split(separator: "\n").suffix(3).joined(separator: "\n")
            Issue.record("never happened; the terminal shows:\n\(screen)\nthe agent: \(agent)\nthe chat: \(chat.state) \(chat.log.entries.map(\.kind))\nthe transcript ends: \(tail)",
                         sourceLocation: sourceLocation)
            throw HarnessError.timedOut
        }
    }

    /// Once the terminal shows it: one heartbeat of the chat (the transcript read in, the screen read).
    func settle(sourceLocation: SourceLocation = #_sourceLocation, _ condition: (String) -> Bool) async throws {
        try await paneShows(sourceLocation: sourceLocation, condition)
        await tick()
    }

    /// Gives keys in flight and the agent's redraw time to land (nothing waits on them otherwise).
    func quiet() async throws {
        try await Task.sleep(nanoseconds: 1_200_000_000)
        await tick()
    }

    /// The window's 1 s heartbeat while the chat shows: the transcript followed, the screen read, and the confirm
    /// read that asks for when the screen changed (`ChatSync.confirmAfter`: a menu is taken once two reads agree).
    func tick() async {
        chat.poll()
        _ = await VibeSwitcherTests.until { !self.chat.reading }
        heartbeat()
        _ = await VibeSwitcherTests.until { !self.sync.confirming && !self.chat.steerReading }
    }

    /// `tick` without waiting for the read (inside an `until`).
    func tickNow() {
        if !chat.reading { chat.poll() }
        heartbeat()
    }

    /// The rest of the heartbeat: steered messages followed, the screen read.
    private func heartbeat() {
        chat.refreshSteering()
        chat.watchSteering(tty: session.tty, agentPid: session.childPID, idle: false)
        chat.agentWorking(working || agent["mode"] as? String == "working")
        sync.readScreen()
    }

    /// The agent's hook at its next step (`vibeswitcher-hook` on PostToolUse): it takes the steered messages from the
    /// inbox with `SteerReply.answer`, and Claude records the hook's added context in its transcript.
    func hookTakes() {
        SteerReply.answer(["hook_event_name": "PostToolUse"], tty: session.tty, agentPid: session.childPID, root: steerRoot) { data in
            guard let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let output = reply["hookSpecificOutput"] as? [String: Any], let context = output["additionalContext"] as? String
            else { return false }
            let line: [String: Any] = ["type": "attachment", "uuid": UUID().uuidString, "isSidechain": false,
                                       "timestamp": ISO8601DateFormatter().string(from: Date()),
                                       "attachment": ["type": "hook_additional_context", "content": [context], "hookEvent": "PostToolUse"]]
            guard let encoded = try? JSONSerialization.data(withJSONObject: line), let handle = try? FileHandle(forWritingTo: transcript)
            else { return false }
            handle.seekToEndOfFile()
            handle.write(encoded + Data("\n".utf8))
            try? handle.close()
            return true
        }
    }

    // MARK: The chat

    var card: AnswerCardContent? { chat.menu.map { AnswerCardContent(menu: $0, pending: chat.log.pendingQuestions) } }

    /// The card, or a failed test (Swift Testing's own `#require(h.card)` reflects the harness, cycles and all, until the
    /// stack runs out).
    func requireCard(_ comment: String = "no card", sourceLocation: SourceLocation = #_sourceLocation) throws -> AnswerCardContent {
        AnswerCardContent(menu: try requireMenu(comment, sourceLocation: sourceLocation), pending: chat.log.pendingQuestions)
    }

    func requireMenu(_ comment: String = "no card", sourceLocation: SourceLocation = #_sourceLocation) throws -> ScreenMenu {
        guard let menu = chat.menu else {
            Issue.record(Comment(rawValue: comment), sourceLocation: sourceLocation)
            throw HarnessError.timedOut
        }
        return menu
    }

    /// The card's free-text row.
    func requireOther(sourceLocation: SourceLocation = #_sourceLocation) throws -> AnswerCardContent.Option {
        let card = try requireCard(sourceLocation: sourceLocation)
        guard let row = card.options.first(where: { $0.kind == .other }) else {
            Issue.record("no free-text row in \(card.options)", sourceLocation: sourceLocation)
            throw HarnessError.timedOut
        }
        return row
    }

    /// A click on the card's option `index` (the card as drawn: `drawn`, else what the chat shows now).
    func click(_ index: Int, typing: String? = nil, drawn: ScreenMenu? = nil) {
        sync.choose(index, typing: typing, drawn: drawn ?? chat.menu)
    }

    /// The answer card's highlight and keys (the window shares one between the card and the composer).
    let cardKeys = AnswerCardKeys()

    /// A key pressed in the composer holding `composer`: the composer hands it to the card (`ComposerView.cardKey`),
    /// which answers as its click does (`AnswerCard.act`, a window session's: no asking first); a key the card
    /// doesn't take goes into the box. What the box holds afterwards.
    func press(_ key: AnswerKeys.Key, composer: String) -> String {
        cardKey(key, composer: composer) ? composer : composer + Self.typed(key)
    }

    /// What the composer asks the card for a key (`ComposerView.cardKey`): true when the card took it, and answered
    /// as its click does.
    func cardKey(_ key: AnswerKeys.Key, composer: String) -> Bool {
        guard let menu = chat.menu else { return false }
        let content = AnswerCardContent(menu: menu, pending: chat.log.pendingQuestions)
        let before = cardKeys.press
        guard cardKeys.take(key, composer: composer, content: content, busy: chat.answering) else { return false }
        if let press = cardKeys.press, press != before, case .answer(let index) = AnswerKeys.pick(press.index, in: content) {
            sync.choose(index, drawn: menu)
        }
        return true
    }

    /// What a key the card didn't take puts in the box (↩ and the arrows put nothing).
    private static func typed(_ key: AnswerKeys.Key) -> String {
        if case .digit(let n) = key { return "\(n)" }
        return ""
    }

    func clickTab(_ index: Int) {
        sync.moveTab(to: index)
    }

    func clickSubmit() throws {
        let card = try requireCard()
        #expect(card.submit != nil)
        sync.choose(card.options.count, drawn: chat.menu)
    }

    /// The composer's ↩ (⌥↩ with `queue`): in the outbox, then typed in.
    @discardableResult
    func send(_ text: String, queue: Bool = false) -> OutboxEntry {
        let entry = OutboxEntry(key: key, message: text, text: text, expectsSoon: !working)
        chat.outbox.add(entry)
        _ = chat.deliver(entry, steering: working && !queue, working: working, actions: actions)
        return entry
    }

    /// The composer's actions, as the window wires them to this session.
    var actions: ComposerActions {
        ComposerActions(send: { [unowned self] in self.sync.type($0) },
                        steer: { [unowned self] in self.sync.steer($0, key: self.key, tty: self.session.tty, agentPid: self.session.childPID) },
                        stop: {}, cycleMode: {})
    }

    /// The prompts the chat shows.
    var prompts: [String] {
        chat.log.entries.compactMap { if case .prompt(let text, _) = $0.kind { return text } else { return nil } }
    }

    /// The prompts the agent took (its transcript).
    var agentPrompts: [String] { agentInputs.map(\.text) }

    /// The prompts the agent took, each with the images that came with it (a prompt's image blocks).
    var agentInputs: [(text: String, images: Int)] {
        lines.compactMap { line in
            if line["type"] as? String == "user", let message = line["message"] as? [String: Any] {
                if let text = message["content"] as? String { return (text, 0) }
                // A prompt with pasted images: its text, then the images (a tool result's images are inside it).
                if let parts = message["content"] as? [[String: Any]], parts.contains(where: { $0["type"] as? String == "image" }) {
                    let text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
                    return (text, parts.filter { $0["type"] as? String == "image" }.count)
                }
            }
            if let attachment = line["attachment"] as? [String: Any], attachment["type"] as? String == "queued_command",
               let prompt = attachment["prompt"] as? String {
                return (prompt, 0)
            }
            return nil
        }
    }

    /// The text of each user line in the transcript, `isMeta` ones too (a `!` command's caveat is one).
    var transcriptContents: [String] {
        lines.compactMap { line in
            guard line["type"] as? String == "user", let message = line["message"] as? [String: Any] else { return nil }
            return message["content"] as? String
        }
    }

    /// The answers in the transcript's tool results, as the chat has them.
    var answers: String {
        chat.log.entries.compactMap { entry -> String? in
            guard case .tool(let tool) = entry.kind, let result = tool.result else { return nil }
            return result.output
        }.joined(separator: "\n")
    }

    private var lines: [[String: Any]] {
        ((try? String(contentsOf: transcript, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }
}

enum HarnessError: Error { case timedOut }

/// A failed expectation that names the harness describes it in one word (its object graph has cycles).
extension Harness: CustomStringConvertible {
    nonisolated var description: String { "harness" }
}

private final class HarnessAnchor {}
