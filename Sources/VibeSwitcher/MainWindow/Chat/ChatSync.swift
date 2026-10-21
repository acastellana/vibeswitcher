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

    /// A session in a Terminal.app tab the chat shows (not one in the window). While the hooks say it needs you, its
    /// tab is read (plain text, no highlights) for the answer card; an answer you confirm is typed in through
    /// `RemoteInput`, the phone's guarded path.
    struct TerminalTarget: Equatable {
        var tty: String
        var pid: Int32
        var startedAt: Date
        var needsInput: Bool
    }

    /// One `RemoteInput.send` into a Terminal tab: text (never submitted) or a key.
    struct TerminalStep: Equatable {
        var text: String?
        var key: RemoteInput.Key?
    }

    let chat: ChatModel
    let host: HostClient
    var target: () -> Target? = { nil }
    /// Asked when there's no window session (`target`).
    var terminalTarget: () -> TerminalTarget? = { nil }
    /// Its tab's text; nil when it couldn't be read. Called off the main thread.
    var terminalScreen: (String) -> String? = { tty in TerminalBridge.screens(for: [tty])[tty] }
    /// One step typed into its tab (`RemoteInput.send`), off the main thread; `stillAllowed` as there.
    var terminalSend: (TerminalTarget, TerminalStep, _ stillAllowed: () -> Bool) -> RemoteInput.Failure? = { target, step, stillAllowed in
        RemoteInput.send(tty: target.tty, agent: (target.pid, target.startedAt), text: step.text, submit: false, key: step.key,
                         stillAllowed: stillAllowed)
    }
    /// Where Terminal is read and typed into, and how what came of it gets back to the main thread.
    var background: (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) }
    var onMain: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    /// The session's screen (see `TerminalPaneController.screenText`).
    var screen: (UUID) -> ScreenRead = { _ in ScreenRead() }
    /// The session's screen as the host's parser has it (`HostClient.styledScreen`), each line keeping its indentation:
    /// a local command's picker is read off it (`ScreenMenu.parsePicker` tells rows from headings by where they start,
    /// and the pane's read trims that). Nil when it couldn't be read; answered on the main thread.
    var hostScreen: (UUID, @escaping ([String]?) -> Void) -> Void
    /// Whether the program in that session asked for bracketed paste.
    var bracketedPaste: (UUID) -> Bool = { _ in false }
    /// Whether the chat is in sight (the window shown and not covered, the chat over the terminal: the rule
    /// `MainWindowController.followChat` reads by). The watch reads nothing otherwise, and goes on when it's back.
    var inSight: () -> Bool = { true }
    var now: () -> Date = Date.init

    /// An answer typed in whose keys the screen hasn't shown yet: while it shows the menu as it was, the card waits
    /// (a second click would land on whatever comes next with this one's keys).
    private var answering: (menu: ScreenMenu, until: Date)?
    /// Since when the selected session's own screen has shown nothing open (no menu, no dialog's footer): its held
    /// messages go in once it's been a while. Its session's: another session selected meanwhile starts it again, so a
    /// picker still open on the one you come back to never gets them.
    private var clearSince: (id: UUID, since: Date)?
    /// How long an answer's keys may take to show on screen before the card takes clicks again.
    static let answerWait: TimeInterval = 2.5
    /// How long the screen must show no menu before held messages are typed in (a redraw between two questions
    /// isn't the end of them).
    static let releaseAfter: TimeInterval = 1
    /// How often a Terminal tab is read while it needs you (each read is an AppleScript call to Terminal).
    static let terminalReadEvery: TimeInterval = 2
    private var terminalReading = false
    /// An answer's keys are going into the Terminal tab: no reads (the cursor moves under them) and no other answer.
    private var terminalTyping = false
    private var terminalReadAt: Date?

    /// A local command's picker or dialog (/mcp, /model, a confirmation) on the host's screen, as last read while
    /// `watch` runs: such a picker writes nothing to the transcript, and the pane's read can't make out its rows.
    private var picker: ScreenMenu?
    /// The screen is read fast (`watchEvery`, the host's screen too) since a slash command was typed in (`since`),
    /// or a dialog's footer showed: until a picker or question has shown (`seen`) and been gone a moment, or
    /// `watchFor` passes with none.
    private var watch: (id: UUID, since: Date, seen: Bool, goneSince: Date?)?
    private var watchTimer: DispatchSourceTimer?
    private var hostReading = false
    /// The footer on screen when the last watch ended with nothing to show (a dialog it can't read): the heartbeat
    /// doesn't start another for it.
    private var unreadFooter: String?
    /// How often the screen is read while watched: the card is up within this of the terminal drawing the picker.
    static let watchEvery: TimeInterval = 0.25
    /// How long after a slash command a picker may take to show.
    static let watchFor: TimeInterval = 10
    /// How long a picker must be gone before the watch ends (one closing as the next one opens isn't the end).
    static let watchGrace: TimeInterval = 0.75

    init(chat: ChatModel, host: HostClient) {
        self.chat = chat
        self.host = host
        hostScreen = { [weak host] id, done in
            guard let host else { return done(nil) }
            host.styledScreen(id) { done($0?.text.components(separatedBy: "\n")) }
        }
    }

    /// Whether the screen is being watched (`watchScreen`).
    var watching: Bool { watch != nil }

    /// Reads the screen every `watchEvery`, the host's screen with it, for a while: a slash command was just typed in
    /// (its picker comes within a moment, and nothing reaches the transcript to redraw the chat for it), or a dialog's
    /// footer is on screen.
    func watchScreen() {
        guard let target = target() else { return }
        watch = (target.id, now(), false, nil)
        resumeWatch()
    }

    /// The watch's reads, while the chat is in sight.
    private func resumeWatch() {
        guard watch != nil, watchTimer == nil, inSight() else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: Self.watchEvery, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.watchTick() }
        timer.resume()
        watchTimer = timer
    }

    /// No reads while the chat is out of sight; the watch itself goes on (`resumeWatch`).
    private func pauseWatch() {
        watchTimer?.cancel()
        watchTimer = nil
    }

    func stopWatching() {
        pauseWatch()
        watch = nil
        picker = nil
    }

    /// One read while watched: the pane's screen now, the host's once it answers (one request at a time).
    private func watchTick() {
        guard let watch, let target = target(), target.id == watch.id else { return stopWatching() }
        guard inSight() else { return pauseWatch() }
        readScreen()
        guard !hostReading else { return }
        hostReading = true
        hostScreen(target.id) { [weak self] lines in
            guard let self else { return }
            self.hostReading = false
            // Another session was selected, or the watch ended meanwhile.
            guard self.watch?.id == target.id, self.target()?.id == target.id else { return }
            self.picker = lines.flatMap(ScreenMenu.parsePicker)
            self.readScreen()
            self.followWatch()
        }
    }

    /// Ends the watch once what it waited for has come and gone, or never came.
    private func followWatch() {
        guard var watch else { return }
        let now = now()
        if chat.menu != nil {
            watch.seen = true
            watch.goneSince = nil
        } else if watch.seen {
            let gone = watch.goneSince ?? now
            watch.goneSince = gone
            if now.timeIntervalSince(gone) >= Self.watchGrace { return stopWatching() }
        } else if now.timeIntervalSince(watch.since) >= Self.watchFor {
            unreadFooter = target().flatMap { Self.dialogFooter(screen($0.id).lines) }
            return stopWatching()
        }
        self.watch = watch
    }

    /// The footer of a dialog on `lines` ("… · Esc to cancel"), its last line: a picker may be open.
    static func dialogFooter(_ lines: [String]) -> String? {
        guard let last = lines.last(where: { !$0.allSatisfy(\.isWhitespace) }),
              last.range(of: #"\bEsc to (cancel|close|back|go back|clear|exit)\b"#, options: .regularExpression) != nil else { return nil }
        return last.trimmingCharacters(in: .whitespaces)
    }

    /// The menu and permission mode on the session's screen, for the answer card and the mode chip; once no menu has
    /// shown for a while, the messages held for it go in.
    func readScreen() {
        guard let target = target() else {
            clearSince = nil
            if watch != nil { stopWatching() }
            if chat.mode != nil { chat.mode = nil }
            if let terminal = terminalTarget() { return readTerminal(terminal) }
            if chat.menu != nil { chat.menu = nil }
            setAnswering(nil)
            return
        }
        let read = screen(target.id)
        // A local command's picker the pane's read can't make out, from the host's screen.
        let menu = Self.menu(on: read, needsInput: target.needsInput) ?? (watch?.id == target.id ? picker : nil)
        // A dialog's footer with nothing read off it: watch the host's screen for its picker (once per dialog).
        let footer = menu == nil ? Self.dialogFooter(read.lines) : nil
        if footer == nil { unreadFooter = nil } else if watch == nil, footer != unreadFooter { watchScreen() }
        // Back in sight with a watch paused.
        if watch != nil, watchTimer == nil { resumeWatch() }
        guard show(menu) else { return }
        let mode = target.agent == .codex ? nil : AgentMode.parse(Array(read.lines.suffix(6)))
        if chat.mode != mode { chat.mode = mode }
        // Held messages go in once this session's own screen has shown nothing open for a while: no menu, and no
        // dialog's footer (a picker read off the host's screen only once the watch has caught up with it).
        if menu == nil, footer == nil {
            if clearSince?.id != target.id { clearSince = (target.id, now()) }
            if let clearSince, now().timeIntervalSince(clearSince.since) >= Self.releaseAfter { releaseHeld(target) }
        } else {
            clearSince = nil
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

    /// `menu` on the card, unless an answer's keys haven't shown yet (false: the card stays as it was, waiting).
    private func show(_ menu: ScreenMenu?) -> Bool {
        if let answering {
            if menu == answering.menu, now() < answering.until { return false }
            setAnswering(nil)
        }
        if chat.menu != menu { chat.menu = menu }
        return true
    }

    /// The menu on a Terminal tab's text (`TerminalBridge.screens`): read as a window session's screen is, without
    /// highlights. Not the slash-command menu: nothing typed from here could be in its box.
    static func terminalMenu(_ text: String?) -> ScreenMenu? {
        guard let text else { return nil }
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        guard let menu = menu(on: ScreenRead(lines: lines), needsInput: true), !menu.commands else { return nil }
        return menu
    }

    /// The Terminal tab's menu on the card, read off the main thread every few seconds while the hooks say it needs
    /// you (one read at a time).
    private func readTerminal(_ target: TerminalTarget) {
        guard target.needsInput else {
            if chat.menu != nil { chat.menu = nil }
            // Answered (or gone) in Terminal: what went wrong with the last answer from here is over.
            if chat.answerNotice != nil { chat.answerNotice = nil }
            setAnswering(nil)
            return
        }
        guard !terminalReading, !terminalTyping, terminalReadAt.map({ now().timeIntervalSince($0) >= Self.terminalReadEvery }) ?? true else { return }
        terminalReading = true
        terminalReadAt = now()
        let read = terminalScreen, main = onMain
        background {
            let menu = Self.terminalMenu(read(target.tty))
            main { [weak self] in
                guard let self else { return }
                self.terminalReading = false
                // Another session was selected meanwhile: its own read follows.
                guard self.target() == nil, self.terminalTarget()?.tty == target.tty else { return }
                _ = self.show(menu)
            }
        }
    }

    /// Why an answer wasn't typed: the question on screen now (`now`) isn't the one the card drew.
    static func refusal(_ now: ScreenMenu?) -> String {
        now == nil ? "That question is gone." : "That question changed; here it is now."
    }

    /// The one line asking before an answer is typed into a Terminal tab (which comes to the front for it).
    static func confirmation(_ menu: ScreenMenu, index: Int, typing: String?) -> String {
        let what: String
        if let typing {
            what = "Answer “\(typing)”"
        } else if index == menu.options.count, let submit = menu.submit {
            what = "Press \(submit)"
        } else if let ticked = menu.checked, ticked.indices.contains(index) {
            what = "\(ticked[index] ? "Untick" : "Tick") “\(menu.options[index])”"
        } else {
            what = "Answer “\(menu.options.indices.contains(index) ? menu.options[index] : "?")”"
        }
        return "\(what)? Terminal comes to the front to take the keys."
    }

    /// What's typed into a Terminal tab to answer `menu`, as the window's keys do (`ScreenMenu.keys`): arrows from
    /// the cursor to `index`, then Enter; for free text, erase what the field holds, the text, then Enter (not in a
    /// multi-select, where Enter would untick it).
    static func terminalSteps(_ menu: ScreenMenu, choose index: Int, typing: String?) -> [TerminalStep] {
        let moves = index - menu.selected
        var steps = Array(repeating: TerminalStep(key: moves > 0 ? .down : .up), count: abs(moves))
        if let typing {
            steps += Array(repeating: TerminalStep(key: .backspace), count: typedIn(menu, index))
            steps.append(TerminalStep(text: typing))
            if !menu.multiSelect { steps.append(TerminalStep(key: .enter)) }
        } else {
            steps.append(TerminalStep(key: .enter))
        }
        return steps
    }

    /// How many characters are in option `index`'s free-text field (typed in the terminal): none while it shows
    /// its placeholder.
    private static func typedIn(_ menu: ScreenMenu, _ index: Int) -> Int {
        let field = menu.options.indices.contains(index) ? menu.options[index] : ""
        return field.lowercased().hasPrefix("type something") ? 0 : field.count
    }

    /// Types the answer (confirmed on the card) into the Terminal tab: read again first, and refused when the
    /// question there isn't the one the card drew; every key through `RemoteInput.send`, each only while the tab
    /// still shows that question.
    private func chooseInTerminal(_ target: TerminalTarget, index: Int, typing: String?, drawn: ScreenMenu) {
        guard answering == nil, !terminalTyping else { return }
        // The card waits while the keys go in.
        terminalTyping = true
        setAnswering((drawn, .distantFuture))
        let read = terminalScreen, send = terminalSend, main = onMain
        background {
            let menu = Self.terminalMenu(read(target.tty))
            var failure: RemoteInput.Failure?
            var moved: ScreenMenu??
            if let menu, menu.sameQuestion(as: drawn) {
                for step in Self.terminalSteps(menu, choose: index, typing: typing) {
                    failure = send(target, step) {
                        let now = Self.terminalMenu(read(target.tty))
                        if now?.sameQuestion(as: drawn) == true { return true }
                        moved = .some(now)
                        return false
                    }
                    if failure != nil { break }
                }
            } else {
                moved = .some(menu)
            }
            let refused = moved, stopped = failure
            main { [weak self] in
                guard let self else { return }
                self.terminalTyping = false
                self.setAnswering(nil)
                self.terminalReadAt = nil
                if let refused {
                    Breadcrumbs.shared.note("chat: a Terminal answer refused, the question changed")
                    self.chat.menu = refused
                    self.chat.answerNotice = Self.refusal(refused)
                } else if let stopped {
                    Breadcrumbs.shared.note("chat: a Terminal answer stopped: \(stopped)")
                    self.chat.answerNotice = stopped.description
                } else if let menu {
                    Breadcrumbs.shared.note("chat: answered a Terminal session's question")
                    self.chat.answerNotice = nil
                    self.setAnswering((menu, self.now().addingTimeInterval(Self.answerWait)))
                    self.chat.scrollToBottom()
                }
            }
        }
    }

    private func setAnswering(_ value: (menu: ScreenMenu, until: Date)?) {
        answering = value
        if chat.answering != (value != nil) { chat.answering = value != nil }
    }

    /// Answers the menu the card drew (`drawn`; else the one it shows): arrows from where the screen's cursor is now,
    /// then Enter. Not when the screen has moved on to another question, or is still taking the last answer.
    /// A Terminal tab's (`terminalTarget`) is answered through `RemoteInput`, off the main thread.
    func choose(_ index: Int, typing: String? = nil, drawn: ScreenMenu? = nil) {
        guard let drawn = drawn ?? chat.menu else { return }
        guard let target = target() else {
            if let terminal = terminalTarget() { chooseInTerminal(terminal, index: index, typing: typing, drawn: drawn) }
            return
        }
        guard answering == nil else { return }
        // Read again right before: the question may have changed or gone, and an answer must not land on another one.
        readScreen()
        guard let menu = chat.menu, menu.sameQuestion(as: drawn) else {
            chat.answerNotice = Self.refusal(chat.menu)
            return
        }
        let writes: [HostInput.Write]
        if let typing {
            // What's in the field already (typed in the terminal) is replaced.
            writes = menu.keys(toChoose: index, typing: typing, replacing: Self.typedIn(menu, index))
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
    /// shown in chat as steering until the hook takes it. `key`: the composer it came from (it leaves its outbox once
    /// it's in the inbox). The inbox is written off the main thread (its lock can be held for seconds): the chat
    /// shows it as sending meanwhile, and one that doesn't get there goes back into the box (`ChatModel.steer`).
    func steer(_ text: String, key: String, tty: String, agentPid: Int32) -> Bool {
        chat.steer(SteerMessage(text: text, from: .user, agentPid: agentPid), tty: tty, key: key)
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
            if menu.picker || menu.commands {
                // Typed in now it would go into the picker as keys (text and ↩ choose whatever is highlighted).
                chat.sendNotice = "A picker is open in the terminal: choose above, or close it (Esc). Your message waits until it's closed."
                chat.answerNotice = "Your message waits until this closes. Close it (Esc) to send it now."
            } else {
                chat.sendNotice = "Waiting for your answer to the question above: typed in now, it would go into the question as keys."
            }
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
        // A slash command may open a picker: read the screen fast until it shows (or doesn't).
        if text.hasPrefix("/") { watchScreen() }
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
    /// A local command's picker or dialog (/mcp, /model), not the agent's question: Esc closes it.
    var picker: Bool
    /// How the terminal says to answer it ("↑/↓ to navigate · Enter to confirm · Esc to cancel").
    var hint: String?

    init(menu: ScreenMenu, pending: [ChatQuestion]?) {
        let questionTabs = menu.tabs.filter { $0.title != "Submit" }
        // The question on the open tab (none on the review tab), when the screen shows its options.
        var question: ChatQuestion?
        // A local command's picker isn't the agent's question.
        if let pending, !menu.picker {
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
        picker = menu.picker
        hint = menu.hint
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
