import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// How the composer's messages reach the session, on the chat sync harness (a fake Claude Code on a scratch pty
/// through a scratch session host; never a real session). Messaging audit 2026-10-22 #1, #2 and #5, UI audit #3:
/// - messages typed in at once were one prompt ("first messagesecond messagethird"): a message's text and its Enter
///   went in on their own timers, so two messages went text, text, Enter, Enter;
/// - after the agent exited to a shell, the composer typed into the shell, which ran the message as a command;
/// - "1 more thing…" typed into an empty composer with a prompt open answered it with option 1;
/// - a second message sent a second after the first was flagged "may not have reached Claude", and putting it back
///   and sending it again made it twice.
@MainActor
@Suite(.serialized)
struct ComposerDeliveryTests {
    let temp = Scratch()

    // MARK: Order

    @Test func threeMessagesReleasedTogetherAreThreePromptsInOrder() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "permission", "command": "touch notes.txt"])
        try await h.settle { $0.contains("Do you want to proceed?") }
        let sent = ["first message", "second message", "third"]
        let entries = sent.map { h.send($0) }
        try await h.quiet()
        #expect(entries.allSatisfy { h.chat.outbox.entry($0.id)?.state == .held })
        // Answered in the terminal: the three go in together once the screen has shown nothing open for a moment.
        h.keys("1")
        try await h.settle { !$0.contains("Do you want to proceed?") }
        try await h.waitFor {
            h.tickNow()
            return (h.agent["queued"] as? [String])?.count == 3
        }
        #expect(h.agent["queued"] as? [String] == sent, "\(h.agent)")
        h.tell(["op": "take"])
        try await h.waitFor {
            h.tickNow()
            return h.chat.outbox.outbox.entries.isEmpty
        }
        #expect(h.agentPrompts == ["start"] + sent)
        #expect(h.chat.pending.isEmpty)
    }

    @Test func aComposerSendAndAPhoneReplyAndALeadWakeUpDontInterleave() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        // In the same instant, to one session: the composer's message, a phone reply (`PhoneAccess`: HostInput's
        // text and Enter) and a lead's wake-up (`LeadController.type`: a bracketed paste and Enter).
        h.send("from the composer")
        h.host.send(h.session.id, writes: HostInput.writes(text: "from the phone", submit: true, key: nil))
        h.host.send(h.session.id, writes: ComposerText.writes("from the lead", bracketed: true))
        try await h.waitFor { h.agentPrompts.count >= 4 }
        try await h.quiet()
        #expect(h.agentPrompts == ["start", "from the composer", "from the phone", "from the lead"], "\(h.agentPrompts)")
    }

    @Test func aUnitStoppedByItsCheckSendsNoEnterAndTheNextOneStillGoes() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        var stopped: Bool?
        // A phone reply whose phone was unpaired between its text and its Enter: the Enter isn't sent.
        h.host.send(h.session.id, writes: HostInput.writes(text: "half", submit: true, key: nil), check: { $0 == 0 }) { stopped = !$0 }
        h.send("whole")
        try await h.waitFor { h.agentPrompts.contains { $0.hasSuffix("whole") } }
        #expect(stopped == true)
        // "half" was left in the box (as a person's typing would be), and the next message's Enter took it along:
        // what matters here is that the composer's message still went in after it, not before or in its middle.
        #expect(h.agentPrompts == ["start", "halfwhole"], "\(h.agentPrompts)")
    }

    @Test func aGateAnsweredLaterHoldsTheNextUnitAndARefusedOneSendsNoEnter() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        // A phone's menu answer: Enter only once the screen, read again, still shows the question tapped. The
        // composer's message waits for that read; it doesn't go in between the keys and the Enter.
        var asked: [Int] = []
        var answer: ((Bool) -> Void)?
        var answered: Bool?
        h.host.send(h.session.id, writes: HostInput.writes(text: "tapped", submit: true, key: nil), gate: { index, go in
            asked.append(index)
            if index == 0 { go(true) } else { answer = go }
        }) { answered = $0 }
        h.send("after")
        try await h.waitFor { answer != nil }
        try await h.quiet()
        #expect(h.agentPrompts == ["start"], "\(h.agentPrompts)")
        // The menu moved: no Enter, and the message goes in after it.
        answer?(false)
        try await h.waitFor { h.agentPrompts.contains { $0.hasSuffix("after") } }
        #expect(asked == [0, 1])
        #expect(answered == false)
        #expect(h.agentPrompts == ["start", "tappedafter"], "\(h.agentPrompts)")
    }

    // MARK: A shell

    @Test func afterTheAgentExitsToAShellNothingIsTypedIntoIt() async throws {
        let h = try await Harness.start(temp, keepShell: true)
        defer { h.stop() }
        let pid = try #require(h.agent["pid"] as? Int)
        // As the window has it: the row's session lags the exit, its process is what's asked.
        h.sync.agentRunning = { [session = h.session!] target in
            target.agent != nil && ChatSync.alive(pid: Int32(pid), on: session.tty)
        }
        #expect(ChatSync.alive(pid: Int32(pid), on: h.session.tty))
        h.tell(["op": "exit"])
        try await h.waitFor { !ChatSync.alive(pid: Int32(pid), on: h.session.tty) }
        try await h.quiet()
        let before = h.screen
        let entry = h.send("echo LEAKED_$((6*7))")
        try await h.quiet()
        #expect(h.chat.outbox.entry(entry.id) == nil)
        #expect(h.chat.pending.isEmpty)
        #expect(h.chat.sendNotice == ChatSync.noAgent)
        #expect(!h.screen.contains("LEAKED"), "\(h.screen)")
        #expect(h.screen == before)
        // Once the row knows (no agent): refused the same way.
        h.targetAgent = nil
        #expect(!h.sync.type("ls"))
        try await h.quiet()
        #expect(h.screen == before)
    }

    @Test func aMessageHeldForAQuestionStaysHeldWhenTheAgentExitsToAShell() async throws {
        let h = try await Harness.start(temp, keepShell: true)
        defer { h.stop() }
        let pid = try #require(h.agent["pid"] as? Int)
        h.sync.agentRunning = { [session = h.session!] _ in ChatSync.alive(pid: Int32(pid), on: session.tty) }
        h.tell(["op": "permission", "command": "touch notes.txt"])
        try await h.settle { $0.contains("Do you want to proceed?") }
        let entry = h.send("echo LEAKED_$((6*7))")
        try await h.quiet()
        #expect(h.chat.outbox.entry(entry.id)?.state == .held)
        // The agent quits with the question open: the screen shows nothing open, which used to release it.
        h.tell(["op": "exit"])
        try await h.waitFor { !ChatSync.alive(pid: Int32(pid), on: h.session.tty) }
        for _ in 0..<3 { try await h.quiet() }
        #expect(h.chat.outbox.entry(entry.id)?.state == .held)
        #expect(!h.screen.contains("LEAKED"), "\(h.screen)")
        #expect(h.chat.sendNotice == ChatSync.noAgent)
    }

    // MARK: Digits

    @Test func aMessageStartingWithADigitIsTextAndCommandDigitAnswers() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "permission", "command": "touch notes.txt"])
        try await h.settle { $0.contains("Do you want to proceed?") }
        // The composer's own text view, in a window, its keys as the composer wires them to the card.
        let box = ComposerNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        box.isEditable = true
        box.cardKey = { [unowned box] key in h.cardKey(key, composer: box.string) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 40), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = box
        #expect(window.makeFirstResponder(box))
        for character in "1 more thing" { type(character, into: box) }
        #expect(box.string == "1 more thing")
        try await h.quiet()
        #expect(h.agent["mode"] as? String == "permission", "\(h.agent)")
        #expect(h.card != nil)
        #expect(!h.chat.answering)
        // The card says which keys answer it.
        #expect(AnswerCard.keysHint(options: 3, composer: true, commands: false) == "⌘1–⌘3 answers · ↑ ↓ and ↩ with the message box empty")
        // With text in the box ⌘1 is nothing (the box's); emptied, ⌘1 answers Yes.
        #expect(!commandDigit(1, into: box))
        box.string = ""
        #expect(commandDigit(1, into: box))
        try await h.waitFor { h.agent["mode"] as? String == "working" }
        #expect(box.string == "")
    }

    @Test func onlyCommandAndADigitKeyIsTheCards() throws {
        func event(_ characters: String, _ code: Int, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code))!
        }
        #expect(ComposerNSTextView.digit(event("1", kVK_ANSI_1, [])) == nil)
        #expect(ComposerNSTextView.digit(event("2", kVK_ANSI_2, [.shift])) == nil)
        #expect(ComposerNSTextView.digit(event("1", kVK_ANSI_1, [.command])) == .digit(1))
        #expect(ComposerNSTextView.digit(event("9", kVK_ANSI_9, [.command])) == .digit(9))
        #expect(ComposerNSTextView.digit(event("3", kVK_ANSI_Keypad3, [.command, .numericPad])) == .digit(3))
        // AZERTY's top row: ⌘ and the "&1" key.
        #expect(ComposerNSTextView.digit(event("&", kVK_ANSI_1, [.command])) == .digit(1))
        #expect(ComposerNSTextView.digit(event("0", kVK_ANSI_0, [.command])) == nil)
        #expect(ComposerNSTextView.digit(event("1", kVK_ANSI_1, [.command, .option])) == nil)
        #expect(ComposerNSTextView.digit(event("1", kVK_ANSI_1, [.control])) == nil)
        // A Terminal session's card has the keys itself: digits alone.
        #expect(AnswerCard.keysHint(options: 3, composer: false, commands: false) == "1–3 answers · ↑ ↓ and ↩")
        #expect(AnswerCard.keysHint(options: 12, composer: true, commands: false)?.hasPrefix("⌘1–⌘9 ") == true)
        #expect(AnswerCard.keysHint(options: 4, composer: true, commands: true) == nil)
    }

    // MARK: The user's case: a second message within a second of the first

    @Test func twoSendsASecondApartBothArriveOnceAndNeitherIsLate() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "turns"])
        try await h.quiet()
        h.send("fix the login bug")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        // The composer still sees the agent idle (the hook's state lags): typed in, expected within seconds.
        let second = h.send("and add a test")
        try await h.waitFor { (h.agent["queued"] as? [String]) == ["and add a test"] }
        await h.tick()
        // Claude thinks for 20 s before its first step: the second waits in its queue, and says so.
        h.chat.now = { Date().addingTimeInterval(20) }
        await h.tick()
        let waiting = try #require(h.chat.pending.first { $0.id == second.id })
        #expect(h.chat.late.isEmpty)
        #expect(h.chat.note(for: waiting) == .queued)
        h.chat.now = Date.init
        // It takes it at its next step, and finishes.
        h.tell(["op": "take"])
        h.tell(["op": "done"])
        try await h.waitFor {
            h.tickNow()
            return h.chat.outbox.outbox.entries.isEmpty && h.chat.pending.isEmpty
        }
        #expect(h.agentPrompts == ["start", "fix the login bug", "and add a test"])
        #expect(h.prompts.filter { $0 == "and add a test" }.count == 1)
        #expect(h.prompts.filter { $0 == "fix the login bug" }.count == 1)
    }

    @Test func aMessageHeldUpByATurnIsExpectedAgainOnceTheTurnEnds() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "work"])
        try await h.waitFor { h.agent["mode"] as? String == "working" }
        // Typed in as if idle (the composer's view lagged), held up by the turn.
        h.chat.sent("still there?", expectsSoon: true)
        await h.tick()
        let held = try #require(h.chat.pending.first)
        #expect(h.chat.note(for: held) == .queued)
        // The turn ends and it's still not in the conversation: expected within 15 s from then, not from its send.
        h.tell(["op": "done"])
        try await h.waitFor { h.agent["mode"] as? String == "idle" }
        h.chat.now = { Date().addingTimeInterval(10) }
        await h.tick()
        #expect(h.chat.late.isEmpty)
        h.chat.now = { Date().addingTimeInterval(30) }
        await h.tick()
        #expect(h.chat.late == [held.id])
        h.chat.now = Date.init
    }

    @Test func putBackAfterMayNotHaveReachedNeverMakesItTwice() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        // The agent doesn't read its input for a while (busy in a way the hooks don't show): the message is typed in
        // and confirmed, but not in the conversation after 15 s.
        h.tell(["op": "freeze"])
        try await Task.sleep(nanoseconds: 300_000_000)
        let entry = h.send("is this thing on")
        try await h.waitFor { h.chat.outbox.entry(entry.id)?.state == .typed }
        h.chat.now = { Date().addingTimeInterval(20) }
        await h.tick()
        let late = try #require(h.chat.pending.first { $0.id == entry.id })
        #expect(h.chat.note(for: late) == .late)
        // Put back in the box, with a draft of yours after it.
        h.chat.composer.drafts[h.key] = "and another thing"
        h.chat.putBack(late, rowID: h.key)
        #expect(h.chat.composer.drafts[h.key] == "is this thing on\n\nand another thing")
        h.chat.now = Date.init
        // The agent takes it after all: it comes back out of the box, so it can't be sent twice.
        h.tell(["op": "thaw"])
        try await h.waitFor {
            h.tickNow()
            return h.prompts.contains("is this thing on")
        }
        await h.tick()
        #expect(h.chat.composer.drafts[h.key] == "and another thing")
        #expect(h.chat.sendNotice?.contains("after all") == true)
        #expect(h.agentPrompts.filter { $0 == "is this thing on" }.count == 1)
        #expect(h.chat.outbox.outbox.entries.isEmpty)
    }

    // MARK: `!` commands (2026-10-24: one Claude Code ran and moved to the background stayed "Not in the conversation
    // yet": it's recorded as a <bash-input> entry, `!` gone, and only once it has run)

    /// The composer's `!` command, once Claude Code has recorded it: the caveat, the command and its output, and the
    /// chat showing it as the prompt typed, delivered and off the outbox.
    private func expectDelivered(_ h: Harness, _ command: String, stdout: String) async throws {
        try await h.waitFor {
            h.tickNow()
            return h.chat.outbox.outbox.entries.isEmpty && h.chat.pending.isEmpty
        }
        let contents = h.transcriptContents
        let input = try #require(contents.firstIndex(of: "<bash-input>\(command.dropFirst())</bash-input>"), "\(contents)")
        #expect(input > 0 && contents[input - 1].hasPrefix("<local-command-caveat>"))
        #expect(contents.dropFirst(input + 1).first?.hasPrefix("<bash-stdout>" + stdout) == true, "\(contents)")
        #expect(h.prompts == ["start", command], "\(h.prompts)")
        #expect(h.chat.log.entries.count == 3, "\(h.chat.log.entries.map(\.kind))")
        #expect(h.chat.late.isEmpty)
    }

    @Test func aMultiLineShellCommandMovedToTheBackgroundIsDelivered() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "slowShell"])
        let command = "!cd /Users/x/dev/p\nscripts/build-app.sh --install"
        let entry = h.send(command)
        try await h.waitFor { (h.agent["shell"] as? [String: Any])?["command"] as? String == String(command.dropFirst()) }
        await h.tick()
        let waiting = try #require(h.chat.pending.first { $0.id == entry.id })
        #expect(h.chat.note(for: waiting) == .sending)
        h.tell(["op": "background"])
        try await expectDelivered(h, command, stdout: "Command did not complete within its 120s timeout and was moved to the background")
    }

    @Test func aOneLineShellCommandIsDelivered() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.send("!ls")
        try await expectDelivered(h, "!ls", stdout: "ran ls")
    }

    @Test func aShellCommandIsNotLateWhileClaudeCodeStillRunsIt() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "slowShell"])
        let entry = h.send("!sleep 300")
        try await h.waitFor { h.agent["shell"] != nil }
        // Two minutes on, nothing in the transcript yet: Claude Code writes it once the 120 s Bash timeout moves it on.
        h.chat.now = { Date().addingTimeInterval(125) }
        await h.tick()
        let waiting = try #require(h.chat.pending.first { $0.id == entry.id })
        #expect(h.chat.late.isEmpty)
        #expect(h.chat.note(for: waiting) == .sending)
        h.tell(["op": "background"])
        try await expectDelivered(h, "!sleep 300", stdout: "Command did not complete")
        h.chat.now = Date.init
    }

    // MARK: Keys

    /// One key typed into the box, as AppKit hands it over.
    private func type(_ character: Character, into box: NSTextView) {
        let text = String(character)
        let codes: [Character: Int] = ["1": kVK_ANSI_1, " ": kVK_Space]
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: box.window?.windowNumber ?? 0,
                                     context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false,
                                     keyCode: UInt16(codes[character] ?? kVK_ANSI_A))!
        if !box.performKeyEquivalent(with: event) { box.keyDown(with: event) }
    }

    /// ⌘ and a digit key, as the window offers it to the box first: true when it was taken.
    private func commandDigit(_ n: Int, into box: NSTextView) -> Bool {
        let codes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3]
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                     windowNumber: box.window?.windowNumber ?? 0, context: nil, characters: "\(n)",
                                     charactersIgnoringModifiers: "\(n)", isARepeat: false, keyCode: UInt16(codes[n - 1]))!
        return box.performKeyEquivalent(with: event)
    }
}
