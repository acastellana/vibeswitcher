import Foundation
import VibeCore

/// A session's screen as text lines, and on each the stretches drawn highlighted (see `TerminalPaneController.screenText`).
struct ScreenRead: Equatable {
    var lines: [String] = []
    var highlights: [[String]] = []
}

/// The chat's side of the selected window session's terminal: the question, permission prompt or picker its screen
/// shows (the answer card), answers typed into it as keys, and the composer's messages typed in. The window owns
/// one; the chat sync harness drives the same one against a scratch host.
final class ChatSync {
    /// The window session the chat shows, when it's live and can be typed into.
    struct Target: Equatable {
        var id: UUID
        /// Its composer's (row draft) key.
        var key: String
        var agent: Agent?
        /// The hooks say it's waiting on you.
        var needsInput: Bool
        /// The hooks say it's in its turn (what's typed in now waits for the turn's end).
        var working = false
    }

    let chat: ChatModel
    let host: HostClient
    var target: () -> Target? = { nil }
    /// The session's screen (see `TerminalPaneController.screenText`).
    var screen: (UUID) -> ScreenRead = { _ in ScreenRead() }
    /// Whether the program in that session asked for bracketed paste.
    var bracketedPaste: (UUID) -> Bool = { _ in false }
    var now: () -> Date = Date.init

    /// An answer typed in whose keys the screen hasn't shown yet: while it shows the menu as it was, the card waits
    /// (a second click would land on whatever comes next with this one's keys).
    private var answering: (menu: ScreenMenu, until: Date)?
    /// Since when the screen has shown no menu (held messages go in once it's been a while).
    private var noMenuSince: Date?
    /// How long an answer's keys may take to show on screen before the card takes clicks again.
    static let answerWait: TimeInterval = 2.5
    /// How long the screen must show no menu before held messages are typed in (a redraw between two questions
    /// isn't the end of them).
    static let releaseAfter: TimeInterval = 1

    init(chat: ChatModel, host: HostClient) {
        self.chat = chat
        self.host = host
    }

    /// The menu and permission mode on the session's screen, for the answer card and the mode chip; once no menu has
    /// shown for a while, the messages held for it go in.
    func readScreen() {
        guard let target = target() else {
            if chat.menu != nil { chat.menu = nil }
            if chat.mode != nil { chat.mode = nil }
            setAnswering(nil)
            return
        }
        let read = screen(target.id)
        let menu = Self.menu(on: read, needsInput: target.needsInput)
        if let answering {
            // The keys haven't shown yet: the card stays as it was, waiting.
            if menu == answering.menu, now() < answering.until { return }
            setAnswering(nil)
        }
        if chat.menu != menu { chat.menu = menu }
        let mode = target.agent == .codex ? nil : AgentMode.parse(Array(read.lines.suffix(6)))
        if chat.mode != mode { chat.mode = mode }
        if menu == nil {
            let since = noMenuSince ?? now()
            noMenuSince = since
            if now().timeIntervalSince(since) >= Self.releaseAfter { releaseHeld(target) }
        } else {
            noMenuSince = nil
        }
    }

    /// The menu waiting on you on `read`: the hooks say so, or the screen says how to choose.
    static func menu(on read: ScreenRead, needsInput: Bool) -> ScreenMenu? {
        let count = min(40, read.lines.count)
        let bottom = Array(read.lines.suffix(count))
        let marks = Array(read.highlights.suffix(count))
        let asking = needsInput
            || bottom.suffix(6).contains { $0.contains("Enter to select") || $0.contains("Esc to cancel") || $0.contains("to navigate") }
        // The slash-command menu under the prompt box has no footer of its own.
        return (asking ? ScreenMenu.parse(bottom, highlights: marks) : nil) ?? ScreenMenu.parseCommands(bottom)
    }

    private func setAnswering(_ value: (menu: ScreenMenu, until: Date)?) {
        answering = value
        if chat.answering != (value != nil) { chat.answering = value != nil }
    }

    /// Answers the menu the card drew (`drawn`; else the one it shows): arrows from where the screen's cursor is now,
    /// then Enter. Not when the screen has moved on to another question, or is still taking the last answer.
    func choose(_ index: Int, typing: String? = nil, drawn: ScreenMenu? = nil) {
        guard let target = target(), let drawn = drawn ?? chat.menu else { return }
        guard answering == nil else { return }
        // Read again right before: the question may have changed or gone, and an answer must not land on another one.
        readScreen()
        guard let menu = chat.menu, menu.sameQuestion(as: drawn) else {
            chat.answerNotice = chat.menu == nil ? "That question is gone." : "That question changed; here it is now."
            return
        }
        let writes: [HostInput.Write]
        if let typing {
            // What's in the field already (typed in the terminal) is replaced.
            let field = menu.options.indices.contains(index) ? menu.options[index] : ""
            let placeholder = field.lowercased().hasPrefix("type something")
            writes = menu.keys(toChoose: index, typing: typing, replacing: placeholder ? 0 : field.count)
        } else {
            writes = menu.keys(toChoose: index)
        }
        write(writes, to: target.id)
        chat.answerNotice = nil
        setAnswering((menu, now().addingTimeInterval(ScreenMenu.duration(writes) + Self.answerWait)))
        readSoon(after: ScreenMenu.duration(writes))
        chat.scrollToBottom()
    }

    /// The answer card's tab `index`: ← / → from the tab the screen has open now.
    func moveTab(to index: Int) {
        readScreen()
        guard answering == nil, let current = chat.menu?.currentTab, index != current else { return }
        sendKeys(Array(repeating: index > current ? [27, 91, 67] : [27, 91, 68], count: abs(index - current)).flatMap { $0 })
    }

    /// Esc in the terminal: closes the slash-command menu (the card goes with it).
    func cancel() {
        guard answering == nil else { return }
        sendKeys([27])
    }

    /// Hands `text` to the agent at its next step through its hook (Claude): into the steer inbox of its terminal,
    /// shown in chat as steering until the hook takes it. `key`: the composer it came from (it leaves its outbox).
    func steer(_ text: String, key: String, tty: String, agentPid: Int32) -> Bool {
        let message = SteerMessage(text: text, from: .user, agentPid: agentPid)
        do {
            try SteerInbox.post(message, tty: tty, root: chat.steerRoot)
        } catch {
            return false
        }
        chat.handedOff(key: key, message: text)
        chat.steered(message, tty: tty)
        chat.scrollToBottom()
        return true
    }

    /// Keys for the session (Esc to stop, shift+tab for the mode); the screen is read again once they're in.
    @discardableResult
    func sendKeys(_ bytes: [UInt8]) -> Bool {
        guard let target = target() else { return false }
        write([HostInput.Write(bytes: bytes, delay: 0)], to: target.id)
        readSoon(after: 0)
        return true
    }

    /// Reads the screen a few times once keys that take `delay` are in: the card catches up with the terminal's
    /// redraw without waiting for the next heartbeat.
    private func readSoon(after delay: TimeInterval) {
        for extra in [0.15, 0.4, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + extra) { [weak self] in self?.readScreen() }
        }
    }

    /// The composer's message, typed into the session (as a paste when its program asked for that). The composer's
    /// outbox keeps it until the host confirms it (and the conversation shows it). With a question, permission
    /// prompt or picker open, it would go into that as keys: it's the question's free-text answer when the question
    /// takes one, else it waits until the question is answered.
    func type(_ text: String) -> Bool {
        guard let target = target(), host.isUsable else { return false }
        readScreen()
        if let menu = chat.menu {
            if let field = freeTextRow(menu), !text.hasPrefix("/") {
                Breadcrumbs.shared.note("composer: sent as the question's free-text answer")
                choose(field, typing: text, drawn: menu)
                if chat.answering {
                    chat.handedOff(key: target.key, message: text)
                    chat.sendNotice = "Sent as your answer to the question."
                    return true
                }
            }
            chat.sendNotice = "Waiting for your answer to the question above: typed in now, it would go into the question as keys."
            // Not the composer's (a Run, a chip): refused, so whoever sent it knows it didn't go.
            guard chat.held(key: target.key, message: text) else { return false }
            Breadcrumbs.shared.note("composer: held while a question is open")
            return true
        }
        typeIn(text, to: target)
        return true
    }

    private func typeIn(_ text: String, to target: Target) {
        let key = target.key
        host.send(target.id, writes: ComposerText.writes(text, bracketed: bracketedPaste(target.id))) { [weak self] ok in
            if !ok { Breadcrumbs.shared.note("composer: the host didn't confirm \(text.count) chars") }
            self?.chat.confirmed(key: key, message: text, ok: ok)
        }
    }

    /// The question's "Type something." row, when the open tab is a question that takes free text (not the review,
    /// not a permission prompt).
    private func freeTextRow(_ menu: ScreenMenu) -> Int? {
        let content = AnswerCardContent(menu: menu, pending: chat.log.pendingQuestions)
        return content.options.first { $0.kind == .other }?.index
    }

    /// The messages held while a question was open, typed in now that it's answered (oldest first).
    private func releaseHeld(_ target: Target) {
        let held = chat.outbox.outbox.entries.filter { $0.key == target.key && $0.state == .held }.sorted { $0.sentAt < $1.sentAt }
        guard !held.isEmpty else { return }
        for entry in held {
            guard chat.release(entry.id, expectsSoon: !target.working) != nil else { continue }
            Breadcrumbs.shared.note("composer: a held message typed in")
            typeIn(entry.message, to: target)
        }
        chat.sendNotice = nil
    }

    func write(_ writes: [HostInput.Write], to id: UUID) {
        var at: TimeInterval = 0
        for write in writes {
            at += write.delay
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                self?.host.send(id, bytes: Data(write.bytes), reply: false)
            }
        }
    }
}

/// What the answer card shows for a menu on screen: the screen decides the options; the AskUserQuestion's own
/// input (when that's what's asking) adds the question's text, headers and descriptions.
struct AnswerCardContent: Equatable {
    enum Kind: Equatable {
        case plain
        /// "Type something.": answered with your own text.
        case other
        /// "Chat about this": talk it over instead of answering.
        case chat
    }

    struct Option: Equatable {
        var index: Int
        var label: String
        var detail: String?
        var kind: Kind
        /// A multi-select's box: ticked or not (nil: not a multi-select).
        var checked: Bool?
    }

    var header: String?
    var question: String
    /// "Question 1 of 2", when several are asked at once.
    var position: String?
    var tabs: [ScreenMenu.Tab]
    var currentTab: Int?
    var options: [Option]
    var selected: Int
    var multiSelect: Bool
    /// A multi-select's button under its options ("Submit", or "Next" when more questions follow).
    var submit: String?
    /// What's typed in the terminal's free-text field ("Type something.").
    var otherText: String?
    /// The slash-command menu, not a question.
    var commands: Bool

    init(menu: ScreenMenu, pending: [ChatQuestion]?) {
        let questionTabs = menu.tabs.filter { $0.title != "Submit" }
        // The question on the open tab (none on the review tab), when the screen shows its options.
        var question: ChatQuestion?
        if let pending {
            let index = menu.tabs.isEmpty ? 0 : menu.currentTab ?? 0
            if index < max(questionTabs.count, 1), pending.indices.contains(index) { question = pending[index] }
        }
        if let asked = question, Array(menu.options.prefix(asked.options.count)) != asked.options { question = nil }
        header = menu.tabs.isEmpty ? question?.header : nil
        self.question = question?.question ?? menu.question
        if questionTabs.count > 1, let current = menu.currentTab, current < questionTabs.count {
            position = "Question \(current + 1) of \(questionTabs.count)"
        }
        tabs = menu.tabs
        currentTab = menu.currentTab
        selected = menu.selected
        multiSelect = menu.multiSelect || question?.multiSelect == true
        submit = menu.submit
        commands = menu.commands
        var otherText: String?
        options = menu.options.enumerated().map { index, label in
            let lower = label.lowercased()
            // The free-text row comes right after the question's options; once typed into, it shows what was typed.
            let free = lower.hasPrefix("type something") || question.map { index == $0.options.count } == true
            let kind: Kind = free ? .other : lower.hasPrefix("chat about this") ? .chat : .plain
            if free, !lower.hasPrefix("type something") { otherText = label }
            let description = menu.descriptions.indices.contains(index) ? menu.descriptions[index] : nil
            let fromInput = question.flatMap { q in q.options.firstIndex(of: label).flatMap { q.descriptions.indices.contains($0) ? q.descriptions[$0] : nil } }
            let detail = description ?? fromInput
            return Option(index: index, label: label, detail: detail == label ? nil : detail, kind: kind,
                          checked: menu.checked.map { $0.indices.contains(index) && $0[index] })
        }
        self.otherText = otherText
    }
}
