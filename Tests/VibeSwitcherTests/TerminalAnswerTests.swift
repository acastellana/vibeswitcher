import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// A session in a Terminal.app tab that needs you, answered from the window: its tab's text (as `TerminalBridge.screens`
/// returns it, faked here: nothing reads or types into Terminal) gives the same answer card as a window session's
/// screen, and a confirmed choice goes key by key through the `RemoteInput.send` seam, refused when the question
/// on the tab is no longer the one the card drew.
@MainActor
struct TerminalAnswerTests {
    static let permission = """
    ⏺ Bash(touch /tmp/x)
    ╭──────────────────────────────────────╮
    │ Bash command                         │
    │                                      │
    │   touch /tmp/x                       │
    │   Create the probe file              │
    │                                      │
    │ Do you want to proceed?              │
    │ ❯ 1. Yes                             │
    │   2. Yes, and don't ask again for touch commands in /tmp │
    │   3. No, and tell Claude what to do differently (esc) │
    ╰──────────────────────────────────────╯



    """

    static let color = """
     ☐ Color
    Which color do you prefer?
      1. Red
    ❯ 2. Green
      3. Blue
      4. Type something.

    Enter to select · ↑/↓ to navigate · Esc to cancel

    """

    static let other = """
    Which database?
    ❯ 1. SQLite
      2. Postgres

    Enter to select · ↑/↓ to navigate · Esc to cancel
    """

    let temp = Scratch()

    /// A chat sync for a Terminal session whose tab shows `screen` (changed by the test), with everything typed
    /// recorded; the work runs inline.
    final class Fake {
        var screen: String?
        var needsInput = true
        var reads = 0
        var sent: [ChatSync.TerminalStep] = []
        /// Before step N (0-based) is checked, the tab shows this instead.
        var screenBefore: [Int: String?] = [:]
        var failure: RemoteInput.Failure?
        var clock = Date(timeIntervalSince1970: 1_000)
    }

    func terminalSync(_ fake: Fake) -> ChatSync {
        let home = temp.url("terminal-answer")
        let chat = ChatModel(outbox: ComposerOutbox(url: home.appendingPathComponent("outbox.json")), home: home.path, steerRoot: home)
        let sync = ChatSync(chat: chat, host: HostClient(socketPath: "/tmp/vsh-ta-\(UUID().uuidString.prefix(8)).sock"))
        sync.terminalTarget = { ChatSync.TerminalTarget(tty: "ttys990", pid: 1, startedAt: Date(timeIntervalSince1970: 0), needsInput: fake.needsInput) }
        sync.terminalScreen = { tty in
            #expect(tty == "ttys990")
            fake.reads += 1
            return fake.screen
        }
        sync.terminalSend = { target, step, stillAllowed in
            #expect(target.tty == "ttys990")
            if let next = fake.screenBefore[fake.sent.count] { fake.screen = next }
            // As RemoteInput.send: asked right before anything is typed.
            guard stillAllowed() else { return .notAllowed }
            if let failure = fake.failure { return failure }
            fake.sent.append(step)
            return nil
        }
        sync.background = { $0() }
        sync.onMain = { $0() }
        sync.now = { fake.clock }
        return sync
    }

    /// The card a window session gets for the same screen.
    func windowCard(_ screen: String) -> AnswerCardContent? {
        let home = temp.url("terminal-answer-window")
        let chat = ChatModel(outbox: ComposerOutbox(url: home.appendingPathComponent("outbox.json")), home: home.path, steerRoot: home)
        let sync = ChatSync(chat: chat, host: HostClient(socketPath: "/tmp/vsh-ta-\(UUID().uuidString.prefix(8)).sock"))
        sync.target = { ChatSync.Target(id: UUID(), key: "window", agent: .claude, needsInput: true) }
        sync.screen = { _ in ScreenRead(lines: screen.components(separatedBy: "\n")) }
        sync.terminalTarget = {
            Issue.record("a window session never reads Terminal")
            return nil
        }
        sync.readScreen()
        return chat.menu.map { AnswerCardContent(menu: $0, pending: nil) }
    }

    @Test func aMirroredScreenGivesTheSameCardAsAWindowSession() throws {
        for screen in [Self.permission, Self.color] {
            let fake = Fake()
            fake.screen = screen
            let sync = terminalSync(fake)
            sync.readScreen()
            let menu = try #require(sync.chat.menu)
            let window = try #require(windowCard(screen))
            #expect(AnswerCardContent(menu: menu, pending: nil) == window)
            #expect(window.options.count >= 3)
        }
        let fake = Fake()
        fake.screen = Self.permission
        let sync = terminalSync(fake)
        sync.readScreen()
        let card = AnswerCardContent(menu: try #require(sync.chat.menu), pending: nil)
        #expect(card.question.hasSuffix("Do you want to proceed?"))
        #expect(card.options.map(\.label) == ["Yes", "Yes, and don't ask again for touch commands in /tmp",
                                              "No, and tell Claude what to do differently (esc)"])
    }

    @Test func theTabIsReadOnlyWhileItNeedsYouAndNotOnEveryTick() {
        let fake = Fake()
        fake.screen = Self.permission
        fake.needsInput = false
        let sync = terminalSync(fake)
        sync.readScreen()
        #expect(fake.reads == 0 && sync.chat.menu == nil)
        fake.needsInput = true
        sync.readScreen()
        #expect(fake.reads == 1 && sync.chat.menu != nil)
        // The heartbeat's next tick, a second later: not read again yet.
        fake.clock += 1
        sync.readScreen()
        #expect(fake.reads == 1)
        fake.clock += ChatSync.terminalReadEvery
        fake.screen = "$ "
        sync.readScreen()
        #expect(fake.reads == 2 && sync.chat.menu == nil)
        // Its slash-command menu isn't a question for the card.
        fake.clock += ChatSync.terminalReadEvery
        fake.screen = "> /mo\n────────\n❯ /model   Set the AI model\n  /mcp   Manage MCP servers"
        sync.readScreen()
        #expect(sync.chat.menu == nil)
    }

    @Test func aChoiceIsTypedKeyByKeyThroughRemoteInput() throws {
        let fake = Fake()
        fake.screen = Self.color
        let sync = terminalSync(fake)
        sync.readScreen()
        let drawn = try #require(sync.chat.menu)
        sync.choose(0, drawn: drawn)
        #expect(fake.sent == [.init(key: .up), .init(key: .enter)])
        #expect(sync.chat.answerNotice == nil)
        // The card waits until the tab shows the answer went in.
        #expect(sync.chat.answering)
        sync.choose(2, drawn: drawn)
        #expect(fake.sent.count == 2)

        let typed = Fake()
        typed.screen = Self.color
        let other = terminalSync(typed)
        other.readScreen()
        other.choose(3, typing: "Teal", drawn: try #require(other.chat.menu))
        #expect(typed.sent == [.init(key: .down), .init(key: .down), .init(text: "Teal"), .init(key: .enter)])
    }

    @Test func noReadOrSecondAnswerWhileItsKeysGoIn() throws {
        let fake = Fake()
        fake.screen = Self.color
        let sync = terminalSync(fake)
        var later: [() -> Void] = []
        // Typing runs off the main thread: held here until the test lets it finish.
        sync.background = { later.append($0) }
        sync.readScreen()
        later.removeFirst()()
        let drawn = try #require(sync.chat.menu)
        sync.choose(0, drawn: drawn)
        #expect(later.count == 1 && sync.chat.answering)
        // The heartbeat reads meanwhile (the cursor moved under the keys), and a second click comes.
        fake.clock += ChatSync.terminalReadEvery
        sync.readScreen()
        sync.choose(2, drawn: drawn)
        #expect(later.count == 1 && sync.chat.answering)
        later.removeFirst()()
        #expect(fake.sent == [.init(key: .up), .init(key: .enter)])
    }

    @Test func itsKeysAreTheWindowsKeys() throws {
        let menu = try #require(ChatSync.terminalMenu(Self.color))
        for index in 0..<menu.options.count {
            let window = menu.keys(toChoose: index).map(\.bytes)
            let terminal = ChatSync.terminalSteps(menu, choose: index, typing: nil).map { step -> [UInt8] in
                switch step.key {
                case .up: return [27, 91, 65]
                case .down: return [27, 91, 66]
                case .enter: return [13]
                default: return []
                }
            }
            #expect(window == terminal)
        }
    }

    @Test func refusedWhenTheScreenChanged() throws {
        let fake = Fake()
        fake.screen = Self.permission
        let sync = terminalSync(fake)
        sync.readScreen()
        let drawn = try #require(sync.chat.menu)
        // Another question came up before the confirmed answer went in.
        fake.screen = Self.other
        sync.choose(0, drawn: drawn)
        #expect(fake.sent.isEmpty)
        #expect(sync.chat.answerNotice == "That question changed; here it is now.")
        #expect(sync.chat.menu?.question == "Which database?")
        #expect(!sync.chat.answering)

        // Answered in Terminal meanwhile: gone.
        let gone = Fake()
        gone.screen = Self.permission
        let second = terminalSync(gone)
        second.readScreen()
        let card = try #require(second.chat.menu)
        gone.screen = "⏺ Done.\n> "
        second.choose(1, drawn: card)
        #expect(gone.sent.isEmpty)
        #expect(second.chat.answerNotice == "That question is gone.")
        #expect(second.chat.menu == nil)
    }

    @Test func stopsWhenTheQuestionChangesBetweenKeys() throws {
        let fake = Fake()
        fake.screen = Self.color
        let sync = terminalSync(fake)
        sync.readScreen()
        // After the first arrow, another question took its place.
        fake.screenBefore[1] = Self.other
        sync.choose(3, typing: "Teal", drawn: try #require(sync.chat.menu))
        #expect(fake.sent == [.init(key: .down)])
        #expect(sync.chat.answerNotice == "That question changed; here it is now.")
        #expect(sync.chat.menu?.question == "Which database?")
    }

    @Test func whatStoppedItIsSaid() throws {
        let fake = Fake()
        fake.screen = Self.permission
        fake.failure = .noAccessibility
        let sync = terminalSync(fake)
        sync.readScreen()
        sync.choose(0, drawn: try #require(sync.chat.menu))
        #expect(fake.sent.isEmpty)
        #expect(sync.chat.answerNotice == RemoteInput.Failure.noAccessibility.description)
        #expect(!sync.chat.answering)
    }

    @Test func theConfirmationIsOneLineNamingTheAnswer() throws {
        let menu = try #require(ChatSync.terminalMenu(Self.permission))
        #expect(ChatSync.confirmation(menu, index: 0, typing: nil) == "Answer “Yes”? Terminal comes to the front to take the keys.")
        let color = try #require(ChatSync.terminalMenu(Self.color))
        #expect(ChatSync.confirmation(color, index: 3, typing: "Teal") == "Answer “Teal”? Terminal comes to the front to take the keys.")
        for text in [ChatSync.confirmation(menu, index: 2, typing: nil), ChatSync.confirmation(color, index: 3, typing: "Teal")] {
            #expect(!text.contains("\n"))
        }
    }

    @Test func theFooterNoLongerSaysReplyThere() {
        for asking in [false, true] {
            let text = TerminalReplyHint.text(canMove: false, asking: asking)
            #expect(!text.contains("Reply there"))
            #expect(text.contains("⌘O"))
        }
        #expect(TerminalReplyHint.text(canMove: false, asking: true) == "Runs in Terminal. Answer its question above, or open it to type (⌘O).")
        #expect(TerminalReplyHint.text(canMove: false, asking: false) == "Runs in Terminal. Open it to type (⌘O); Move to Window is offered between turns.")
        #expect(TerminalReplyHint.text(canMove: true, asking: false) == "Runs in Terminal. Move it here to reply from this window.")
    }
}
