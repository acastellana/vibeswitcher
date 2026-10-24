import AppKit
import Combine
import Foundation
import VibeCore

/// Unsent text per session (row id), so switching sessions never sends a draft to the wrong one, and images
/// attached to each draft. Kept on disk (shortly after typing stops), so a restart or an update doesn't lose them.
final class ComposerDrafts: ObservableObject {
    @Published var drafts: [String: String] = UserDefaults.standard.dictionary(forKey: "chatDrafts") as? [String: String] ?? [:] {
        didSet { saveSoon() }
    }
    @Published var attachments: [String: [String]] = UserDefaults.standard.dictionary(forKey: "chatAttachments") as? [String: [String]] ?? [:] {
        didSet { saveSoon() }
    }
    private var pendingSave: DispatchWorkItem?

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.save()
        }
    }

    private func saveSoon() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        UserDefaults.standard.set(drafts.filter { !$0.value.isEmpty }, forKey: "chatDrafts")
        UserDefaults.standard.set(attachments.filter { !$0.value.isEmpty }, forKey: "chatAttachments")
    }
}

/// The conversation of the session the chat shows: read from its transcript off the main thread, the newest
/// part first, then followed as the file grows.
final class ChatModel: ObservableObject {
    enum State: Equatable {
        case none
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var log = ChatLog() {
        didSet { if log != oldValue { updateItems() } }
    }
    /// The conversation as the view shows it, worked out once per change (not on every redraw).
    @Published private(set) var items: [ChatItem] = []
    /// How many of the newest items are laid out (see `ChatWindow`); Show Earlier adds a page.
    @Published private(set) var shownLimit = ChatWindow.page
    /// The window's rows not laid out yet: an open or an earlier page arrives a few rows a turn (`ChatStaging`).
    @Published private(set) var staging: ChatStaging?
    /// The staging is an open's: the view keeps the conversation out of sight until all its rows are laid out, then
    /// shows it where it opens.
    private var stagingOpens = false
    private var stagingTimer: Timer?

    /// How many turns the last staging's rows took to lay out (the chat bench reports it).
    private(set) var stagingTurns = 0

    /// An opened conversation is being laid out, out of sight (`staging`).
    var assembling: Bool { staging != nil && stagingOpens }
    @Published private(set) var state = State.none
    /// Part of the file before what's loaded.
    @Published private(set) var hasEarlier = false
    @Published private(set) var loadingEarlier = false
    /// The last entry you had seen when this chat opened (the "new since you looked" marker goes after it).
    @Published private(set) var markerAfter: String? {
        didSet { if markerAfter != oldValue { updateItems() } }
    }
    /// Tool groups and tools you opened (by item / tool id), kept while scrolling.
    @Published var expanded: Set<String> = []
    @Published var searchActive = false
    @Published var searchQuery = ""
    @Published var searchIndex = 0
    /// Bumped to scroll to the bottom (e.g. after you send something).
    @Published private(set) var scrollToBottomRequests = 0
    /// Bumped to put the keyboard focus in the composer.
    @Published private(set) var focusComposerRequests = 0
    /// Unsent text and attachments per session. Its own object: typing changes it on every key, and that mustn't
    /// redraw the conversation.
    let composer = ComposerDrafts()
    /// What the composer sent that the conversation doesn't show yet, on disk (survives a crash or relaunch).
    let outbox: ComposerOutbox
    /// Where transcripts are looked for (the user's home; a scratch one in tests).
    let home: String

    /// Where steered messages wait for the agent's hook (`SteerInbox`; a scratch folder in tests).
    let steerRoot: URL
    /// The clock a sent message is late by (moved on in tests).
    var now: () -> Date = Date.init

    init(outbox: ComposerOutbox = ComposerOutbox(), home: String = VibePaths.home, steerRoot: URL = VibePaths.root) {
        self.outbox = outbox
        self.home = home
        self.steerRoot = steerRoot
        #if DEBUG
        Self.live += 1
        #endif
    }

    #if DEBUG
    /// For `--idle-bench`: the chat models alive now (made and freed on the main thread).
    static var live = 0
    deinit { Self.live -= 1 }
    #endif
    /// The composer (row draft key) whose conversation this is: its outbox is matched against this transcript.
    private(set) var outboxKey: String?
    /// Run, on code blocks.
    let runner = ChatRunner()

    /// Messages sent from the composer that the transcript doesn't show yet.
    @Published private(set) var pending: [PendingMessage] = []
    /// Messages steered into the agent that it hasn't taken yet (and the terminal they went to).
    @Published private(set) var steering: [SteerMessage] = []
    private var steeringTTY: String?
    /// A numbered choice on the session's screen (permission prompt, question), and its permission mode.
    @Published var menu: ScreenMenu? {
        didSet { if menu != oldValue, oldValue != nil { answerNotice = nil } }
    }
    /// Shown on the answer card ("that question changed").
    @Published var answerNotice: String?
    /// Shown under the composer about its last send ("waits until you answer the question").
    @Published var sendNotice: String?
    /// An answer is being typed into the question on screen: the card waits for the screen to show it.
    @Published var answering = false
    @Published var mode: AgentMode?
    /// What `/` and `@` complete to, for the session's folder.
    @Published private(set) var commands: [SlashCommand] = []
    @Published private(set) var files: [String] = []

    static let pageBytes = 4 * 1024 * 1024
    private static let seenKey = "chatSeen"

    private(set) var path: String?
    private var url: URL?
    private var format = TranscriptReader.Format.claude
    /// Where the next read continues (just after the last complete line read).
    private var cursor = 0
    /// Where the loaded part of the file starts.
    private var earliest = 0
    /// Bumped on every switch, so reads finishing for an earlier session are dropped.
    private var generation = 0
    private(set) var reading = false
    private let queue = DispatchQueue(label: "vibeswitcher.chat-reads", qos: .userInitiated)

    /// The lead's all-done marks, when this is a project lead's conversation: each a card where its board cleared.
    private(set) var allDone: [LeadAllDone] = []

    /// Shows the lead's all-done cards (none: this isn't a lead's conversation).
    func showAllDone(_ marks: [LeadAllDone]) {
        guard marks != allDone else { return }
        allDone = marks
        updateItems()
    }

    private func updateItems() {
        let new = BatchSummary.place(allDone, in: ChatTimeline.items(log.entries, newAfter: markerAfter))
        guard new != items else { return }
        // Its indices are the old items': whatever was still to come is shown now.
        stopStaging()
        // Reading further up: what arrives grows the window, so nothing you're looking at moves out of it.
        if !atBottom, new.count > items.count, !items.isEmpty { shownLimit += new.count - items.count }
        items = new
    }

    /// What you left each conversation with (opened tool runs, search, where you were reading), restored when you
    /// come back to it; one conversation's state never shows in another.
    private struct Kept {
        var expanded: Set<String>
        var searchActive: Bool
        var searchQuery: String
        var searchIndex: Int
        /// The item at the top of the view when you left; nil when you were at the end.
        var anchor: String?
    }
    private var kept: [String: Kept] = [:]
    /// Where each shown item starts and where the view's top is (kept current by the view), to know where you
    /// were reading.
    var rowTops: [String: Double] = [:]
    var visibleTop: Double = 0
    var atBottom = true
    /// Where to scroll when the conversation opens (set from what was kept).
    private(set) var restoreAnchor: String?

    /// Shows the conversation in `path` (nil: none), the one `key`'s composer sends to. Same path: nothing changes.
    func show(path: String?, key: String? = nil) {
        if outboxKey != key {
            outboxKey = key
            if path == self.path { syncOutbox() }
        }
        guard path != self.path else { return }
        if let old = self.path {
            // Left before it was shown: where it was to open.
            let anchor = assembling ? restoreAnchor : atBottom ? nil : ChatWindow.anchor(tops: rowTops, visibleTop: visibleTop)
            kept[old] = Kept(expanded: expanded, searchActive: searchActive, searchQuery: searchQuery, searchIndex: searchIndex, anchor: anchor)
        }
        generation += 1
        self.path = path
        log = ChatLog()
        let restored = path.flatMap { kept[$0] }
        expanded = restored?.expanded ?? []
        searchActive = restored?.searchActive ?? false
        searchQuery = restored?.searchQuery ?? ""
        searchIndex = restored?.searchIndex ?? 0
        restoreAnchor = restored?.anchor
        rowTops = [:]
        visibleTop = 0
        atBottom = true
        shownLimit = ChatWindow.page
        stopStaging()
        hasEarlier = false
        loadingEarlier = false
        pending = []
        putBackTyped = []
        steering = []
        steeringTTY = nil
        menu = nil
        mode = nil
        cursor = 0
        earliest = 0
        reading = false
        guard let path, let (url, format) = TranscriptReader.checkedURL(path, home: home) else {
            url = nil
            markerAfter = nil
            state = path == nil ? .none : .failed("No conversation for this session yet.")
            syncOutbox()
            return
        }
        self.url = url
        self.format = format
        markerAfter = Self.seen[path]
        state = .loading
        let generation = self.generation
        reading = true
        queue.async {
            let read = Self.readTail(url: url, format: format)
            DispatchQueue.main.async {
                guard generation == self.generation else { return }
                self.reading = false
                guard let read else { return self.state = .failed("Couldn't read the conversation.") }
                var log = ChatLog()
                log.append(read.events)
                self.log = log
                self.cursor = read.cursor
                self.earliest = read.start
                Breadcrumbs.shared.note("chat: loaded \(log.entries.count) entries, \(self.items.count) items from \(url.lastPathComponent)")
                self.hasEarlier = read.start > 0
                // Nothing new since you looked: no marker.
                if self.markerAfter == log.entries.last?.id { self.markerAfter = nil }
                // Lay out enough to reach where you were reading, or what's new if it isn't far back.
                self.widen(toInclude: self.restoreAnchor)
                self.widen(toInclude: "new-marker", atMost: 3 * ChatWindow.page)
                self.stageOpen()
                self.state = .ready
                self.syncOutbox()
            }
        }
    }

    /// Reads what was added to the file since the last read (call about once a second while shown).
    func poll() {
        if !pending.isEmpty { updateLate() }
        // Not there yet (a new session writes its transcript with the first message): try again.
        if case .failed = state, let path, !reading {
            self.path = nil
            return show(path: path, key: outboxKey)
        }
        guard let url, state == .ready, !reading else { return }
        let generation = self.generation, cursor = self.cursor, format = self.format
        reading = true
        queue.async {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size < cursor {
                // Rewritten from the start: read it again.
                DispatchQueue.main.async {
                    guard generation == self.generation else { return }
                    self.reading = false
                    let path = self.path
                    self.path = nil
                    self.show(path: path, key: self.outboxKey)
                }
                return
            }
            let read = size > cursor ? Self.read(url: url, from: cursor, to: size, skipPartialFirstLine: false, format: format) : nil
            DispatchQueue.main.async {
                guard generation == self.generation else { return }
                self.reading = false
                guard let read, !read.events.isEmpty || read.consumed > 0 else { return }
                // Lines that show nothing (progress, metadata) move the cursor without redrawing the chat.
                if !read.events.isEmpty { self.log.append(read.events) }
                self.cursor = cursor + read.skipped + read.consumed
                if !read.events.isEmpty { self.syncOutbox() }
            }
        }
    }

    func loadEarlier() {
        guard let url, hasEarlier, !loadingEarlier else { return }
        let generation = self.generation, end = earliest, format = self.format
        loadingEarlier = true
        queue.async {
            // A single line (a big screenshot) can be longer than a page: widen until a line fits.
            var page = Self.pageBytes
            var start = max(0, end - page)
            var read = Self.read(url: url, from: start, to: end, skipPartialFirstLine: start > 0, format: format)
            while let partial = read, start > 0, partial.skipped >= end - start, page < 256 * 1024 * 1024 {
                page *= 2
                start = max(0, end - page)
                read = Self.read(url: url, from: start, to: end, skipPartialFirstLine: start > 0, format: format)
            }
            DispatchQueue.main.async {
                guard generation == self.generation else { return }
                self.loadingEarlier = false
                guard let read else { return }
                self.log.prepend(read.events)
                self.earliest = start + read.skipped
                self.hasEarlier = self.earliest > 0
            }
        }
    }

    /// Remembers the newest entry as seen (while the chat is on screen).
    func markSeen() {
        guard let path, let last = log.entries.last?.id, Self.seen[path] != last else { return }
        var stored = UserDefaults.standard.dictionary(forKey: Self.seenKey) as? [String: [String: Any]] ?? [:]
        stored[path] = ["id": last, "at": Date().timeIntervalSince1970]
        // Keep the store small: the 300 most recently seen conversations.
        if stored.count > 400 {
            let keep = stored.sorted { ($0.value["at"] as? Double ?? 0) > ($1.value["at"] as? Double ?? 0) }.prefix(300)
            stored = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        UserDefaults.standard.set(stored, forKey: Self.seenKey)
    }

    func focusComposer() { focusComposerRequests += 1 }

    func showEarlier() {
        let previous = max(0, items.count - shownLimit)
        stopStaging()
        shownLimit += ChatWindow.page
        stage(.page(start: max(0, items.count - shownLimit), previous: previous), opens: false)
        Breadcrumbs.shared.note("chat: show earlier (\(shownLimit) of \(items.count))")
    }

    /// An opened conversation's rows a few at a time, out of sight: the newest first (the order doesn't show).
    private func stageOpen() {
        stage(.open(start: max(0, items.count - shownLimit), end: items.count), opens: true)
    }

    /// The rows come one batch a turn, each once the view has laid out the last (`stagingShown`): queued sooner, SwiftUI
    /// could lay out two batches in one turn. With no view saying so (the chat not on screen), a batch a tenth of a second.
    private func stage(_ new: ChatStaging, opens: Bool) {
        guard !new.isDone else { return }
        staging = new
        stagingOpens = opens
        stagingTurns = 1
        nextStagingTurn(after: 0.1)
    }

    /// The view has laid out the rows staged so far: the next batch, next turn.
    func stagingShown() {
        guard staging != nil else { return }
        nextStagingTurn(after: 0.001)
    }

    /// A timer, not the main queue: a block queued now could run before this turn's layout.
    private func nextStagingTurn(after delay: TimeInterval) {
        stagingTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, var staging = self.staging else { return }
            staging.step()
            self.stagingTurns += 1
            if staging.isDone { self.stopStaging() } else { self.staging = staging; self.nextStagingTurn(after: 0.1) }
        }
        RunLoop.main.add(timer, forMode: .common)
        stagingTimer = timer
    }

    private func stopStaging() {
        stagingTimer?.invalidate()
        stagingTimer = nil
        if staging != nil { staging = nil }
    }

    private func widen(toInclude id: String?, atMost: Int = .max) {
        guard let id, let index = items.firstIndex(where: { $0.id == id }) else { return }
        let needed = items.count - index + 5
        if needed <= atMost { shownLimit = max(shownLimit, needed) }
    }

    /// Steps through search matches, wrapping around.
    func stepSearch(_ delta: Int) {
        let count = ChatSearch.matches(items, query: searchQuery).count
        guard count > 0 else { return }
        searchIndex = ((min(searchIndex, count - 1) + delta) % count + count) % count
    }

    /// Shows a steered message until the agent's hook takes it.
    func steered(_ message: SteerMessage, tty: String) {
        steeringTTY = tty
        steering.append(message)
    }

    /// Steered messages on their way into the inbox (`steer`): shown as sending until they're there.
    @Published private(set) var steerSending: Set<String> = []
    /// Those messages, the terminal each goes to (they show only with that terminal's), and the composer's outbox
    /// entry each came from: it stays in the outbox (on disk) until the message is in the inbox, so a crash while
    /// the post waits on the lock leaves it there to send again, never lost.
    private var inFlight: [(tty: String, message: SteerMessage, entry: UUID?)] = []
    /// Where the inbox is posted to and withdrawn from: off the main thread, since its lock can be held for seconds
    /// (a hook's delivery checks seals through the host), and in order (a withdraw waits for its post).
    var inbox: (@escaping () -> Void) -> Void = { ChatModel.inboxQueue.async(execute: $0) }
    var onMain: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    private static let inboxQueue = DispatchQueue(label: "vibeswitcher.steer-inbox", qos: .userInitiated)

    /// Steers `message` from `key`'s composer into `tty`'s inbox: shown at once as sending, posted off the main
    /// thread. Its outbox entry leaves once it's in the inbox; one that didn't get there leaves the strip and goes
    /// back into the box (its images with it), said under it.
    func steer(_ message: SteerMessage, tty: String, key: String) {
        let taken = Set(inFlight.compactMap(\.entry))
        let entry = outbox.outbox.entries.first {
            $0.key == key && $0.message == message.text && $0.state == .sending && !outbox.outbox.restored.contains($0.id) && !taken.contains($0.id)
        }
        steered(message, tty: tty)
        steerSending.insert(message.id)
        inFlight.append((tty, message, entry?.id))
        let root = steerRoot
        inbox { [weak self, onMain] in
            let posted = (try? SteerInbox.post(message, tty: tty, root: root)) != nil
            onMain {
                guard let self else { return }
                self.steerSending.remove(message.id)
                self.inFlight.removeAll { $0.message.id == message.id }
                if posted {
                    if let entry { self.outbox.remove(entry.id) }
                    return
                }
                Breadcrumbs.shared.note("composer: steer to \(tty) didn't reach its inbox, back in the box")
                self.steering.removeAll { $0.id == message.id }
                if self.steering.isEmpty { self.steeringStranded = false }
                if let entry = entry.flatMap({ self.outbox.entry($0.id) }) {
                    self.putBack(entry, rowID: key)
                } else {
                    self.putBack(PendingMessage(text: message.text, afterPrompts: 0), rowID: key)
                }
                self.sendNotice = "Not steered: its inbox stayed busy. It's back in the box to send again."
            }
        }
    }

    /// Whether the outbox entry `id` is a steer on its way into the inbox (the steer strip shows it, not the list
    /// of messages typed in).
    private func steeringEntry(_ id: UUID) -> Bool { inFlight.contains { $0.entry == id } }

    /// The agent the steered messages wait for is idle: they won't arrive by themselves.
    @Published private(set) var steeringStranded = false

    /// Follows the selected session's waiting steered messages (from the inbox, so they show after a relaunch too).
    func watchSteering(tty: String?, agentPid: Int32?, idle: Bool) {
        guard let tty, let agentPid else {
            if !steering.isEmpty { steering = [] }
            steeringTTY = nil
            if steeringStranded { steeringStranded = false }
            return
        }
        steeringTTY = tty
        var waiting = SteerInbox.pending(tty: tty, root: steerRoot).filter { $0.agentPid == agentPid && $0.from == .user }
        let landed = Set(waiting.map(\.id))
        waiting += inFlight.filter { $0.tty == tty && $0.message.agentPid == agentPid && !landed.contains($0.message.id) }.map(\.message)
        if waiting != steering { steering = waiting }
        let stranded = idle && !waiting.isEmpty
        if stranded != steeringStranded { steeringStranded = stranded }
    }

    /// A waiting steered message, taken back from the inbox (to send it now, or to put it back in the box): off the
    /// main thread like a post (`inbox`), then `taken` on it. Not called when the agent took it first.
    func withdrawSteered(_ message: SteerMessage, taken: @escaping (SteerMessage) -> Void) {
        guard let tty = steeringTTY else { return }
        let root = steerRoot
        inbox { [weak self, onMain] in
            let withdrawn = SteerInbox.withdraw(id: message.id, tty: tty, root: root)
            onMain {
                guard let self, let withdrawn else { return }
                self.steering.removeAll { $0.id == message.id }
                if self.steering.isEmpty { self.steeringStranded = false }
                taken(withdrawn)
            }
        }
    }

    /// Drops steered messages the agent has taken (they show from the transcript then).
    func refreshSteering() {
        guard let tty = steeringTTY, !steering.isEmpty else { return }
        let delivered = SteerInbox.delivered(tty: tty, root: steerRoot)
        let pending = Set(SteerInbox.pending(tty: tty, root: steerRoot).map(\.id))
        // Taken, or gone from the inbox (a new agent on that terminal dropped it); one still on its way stays.
        let left = steering.filter { !delivered.contains($0.id) && (pending.contains($0.id) || steerSending.contains($0.id)) }
        if left != steering { steering = left }
    }

    /// Records a sent message until the transcript shows it: queued for after the turn, or typed into an idle
    /// agent (`expectsSoon`: flagged if it doesn't show up in seconds). From the composer, `id` is its outbox entry's.
    func sent(_ text: String, expectsSoon: Bool = false, id: UUID = UUID(), attachments: [String] = [], sentAt: Date = Date()) {
        var message = PendingMessage(text: text, afterPrompts: log.prompts.count, expectsSoon: expectsSoon, sentAt: sentAt,
                                     attachments: attachments)
        message.id = id
        pending.append(message)
    }

    /// The composer's message (already in the outbox, as `entry`) handed over: steered into the working agent, or typed
    /// in. False when that was refused (it leaves the outbox; the composer keeps it in the box).
    func deliver(_ entry: OutboxEntry, steering: Bool, working: Bool, actions: ComposerActions) -> Bool {
        sendNotice = nil
        let accepted = steering ? actions.steer(entry.message) : actions.send(entry.message)
        guard accepted else {
            outbox.remove(entry.id)
            return false
        }
        // Typed in (a steer, in the outbox until it's in the agent's inbox, shows in the steer strip): shown until
        // the conversation has it (flagged if it doesn't arrive).
        if let kept = outbox.entry(entry.id), !steeringEntry(entry.id) {
            // Held (a question is open): not typed in yet, so not expected yet.
            sent(entry.message, expectsSoon: !working && kept.state != .held, id: entry.id, attachments: entry.attachments, sentAt: entry.sentAt)
        }
        return true
    }

    /// Send now, from the outbox strip: typed in again (queued if the agent works), never steered.
    func resend(_ entry: OutboxEntry, working: Bool, send: (String) -> Bool) {
        guard let again = outbox.resend(entry.id) else { return }
        guard send(again.message) else {
            outbox.confirm(key: again.key, message: again.message, ok: false)
            return
        }
        sent(again.message, expectsSoon: !working, id: again.id, attachments: again.attachments, sentAt: again.sentAt)
        scrollToBottom()
    }

    /// The session host's answer for a message typed from `key`'s composer. Not taken: off the list of messages on
    /// their way, and into the composer's outbox strip (to send again or discard).
    func confirmed(key: String, message: String, ok: Bool) {
        guard let id = outbox.confirm(key: key, message: message, ok: ok), !ok else { return }
        pending.removeAll { $0.id == id }
        updateLate()
    }

    /// A message from `key`'s composer waits for the question on screen to be answered: never late meanwhile (it
    /// hasn't been typed in). False when it isn't the outbox's (a code block's Run, a command chip): nothing would
    /// send it later.
    func held(key: String, message: String) -> Bool {
        guard let id = outbox.hold(key: key, message: message) else { return false }
        if let index = pending.firstIndex(where: { $0.id == id }) { pending[index].expectsSoon = false }
        updateLate()
        return true
    }

    /// A held message going in now: from now on it's like one just typed (`expectsSoon`: into an idle agent).
    func release(_ id: UUID, expectsSoon: Bool) -> OutboxEntry? {
        guard let entry = outbox.release(id, expectsSoon: expectsSoon) else { return nil }
        if let index = pending.firstIndex(where: { $0.id == id }) {
            pending[index].expectsSoon = expectsSoon
            pending[index].sentAt = entry.sentAt
        }
        updateLate()
        return entry
    }

    /// What a message on its way says under it.
    enum PendingNote: Equatable {
        /// Should be in the conversation by now: it may not have reached the agent.
        case late
        /// Waits for the question on screen to be answered.
        case held
        case sending
        /// Typed in during the agent's turn: it takes it after.
        case queued
    }

    func note(for message: PendingMessage) -> PendingNote {
        if late.contains(message.id) { return .late }
        if outbox.entry(message.id)?.state == .held { return .held }
        return message.expectsSoon ? .sending : .queued
    }

    /// A message from `key`'s composer went to the agent's steer inbox, which shows and keeps it from there.
    func handedOff(key: String, message: String) {
        outbox.handedOff(key: key, message: message)
    }

    /// Lines up the outbox with the conversation: what it shows is delivered (off the outbox and the list); what's
    /// still on its way from this launch shows as pending again after switching back to this session.
    private func syncOutbox() {
        let prompts = SentMatch.prompts(log.entries)
        if let key = outboxKey, state == .ready { outbox.delivered(key: key, prompts: prompts) }
        if !pending.isEmpty { pending = PendingMessage.remaining(pending, prompts: prompts) }
        if !putBackTyped.isEmpty { takeOutArrived(prompts: prompts) }
        guard let key = outboxKey else { return }
        let shown = Set(pending.map(\.id))
        let missing = outbox.outbox.onTheirWay(key: key).filter { !shown.contains($0.id) && !steeringEntry($0.id) }
        guard !missing.isEmpty else { return }
        for entry in missing {
            var message = PendingMessage(text: entry.message, afterPrompts: 0, expectsSoon: entry.expectsSoon, sentAt: entry.sentAt,
                                         attachments: entry.attachments)
            message.id = entry.id
            pending.append(message)
        }
        pending.sort { $0.sentAt < $1.sentAt }
        updateLate()
    }

    /// Typed messages that should be in the conversation by now and aren't.
    @Published private(set) var late: Set<UUID> = []
    /// Messages typed into an idle agent that a turn then held up (see `agentWorking`).
    private var heldUpByTurn: Set<UUID> = []

    /// The agent's turn, as the window sees it each heartbeat. A message typed into an idle agent whose turn then
    /// started (one you sent a moment before started it, or a wake-up did) waits in the agent's queue for that turn:
    /// queued, not "may not have reached the agent" (and putting it back, then sending it again, made it twice).
    /// Once the agent is between turns again, the agent takes it then: expected within seconds from that moment.
    func agentWorking(_ working: Bool) {
        let at = now()
        var changed = false
        for index in pending.indices where outbox.entry(pending[index].id)?.state != .held {
            let id = pending[index].id
            if working, pending[index].expectsSoon {
                pending[index].expectsSoon = false
                heldUpByTurn.insert(id)
                changed = true
            } else if !working, heldUpByTurn.remove(id) != nil {
                pending[index].expectsSoon = true
                pending[index].expectedFrom = at
                changed = true
            }
        }
        heldUpByTurn.formIntersection(pending.map(\.id))
        if changed { updateLate() }
    }

    private func updateLate() {
        let at = now()
        let overdue = Set(pending.filter { $0.late(at: at) }.map(\.id))
        if overdue != late { late = overdue }
    }

    /// A late message, back in the composer (before what's there), and off the list.
    func putBack(_ message: PendingMessage, rowID: String) {
        if let entry = outbox.entry(message.id) {
            putBack(entry, rowID: rowID)
        } else {
            let draft = composer.drafts[rowID] ?? ""
            composer.drafts[rowID] = draft.isEmpty ? message.text : message.text + "\n\n" + draft
            putBackTyped.append((message, rowID, message.text, []))
            focusComposer()
        }
        dismiss(message)
    }

    /// Messages put back in the box that went into the terminal (typed, then flagged late or left from before a
    /// relaunch): the agent may still take them. One the conversation then shows comes back out of the box.
    private var putBackTyped: [(message: PendingMessage, rowID: String, text: String, attachments: [String])] = []

    /// Put back, then shown in the conversation after all: out of the box again while the box still starts with
    /// it (sent again, it would be in the conversation twice), and you're told.
    private func takeOutArrived(prompts: [SentMatch.Prompt]) {
        let arrived = putBackTyped.filter { PendingMessage.remaining([$0.message], prompts: prompts).isEmpty }
        guard !arrived.isEmpty else { return }
        putBackTyped.removeAll { watch in arrived.contains { $0.message.id == watch.message.id } }
        for watch in arrived {
            let draft = composer.drafts[watch.rowID] ?? ""
            let rest: String?
            if draft == watch.text {
                rest = ""
            } else if draft.hasPrefix(watch.text + "\n\n") {
                rest = String(draft.dropFirst(watch.text.count + 2))
            } else {
                rest = nil
            }
            if let rest {
                composer.drafts[watch.rowID] = rest
                composer.attachments[watch.rowID]?.removeAll { watch.attachments.contains($0) }
                composer.save()
                sendNotice = "It reached the agent after all, so it's out of the box again."
            } else {
                sendNotice = "A message you put back reached the agent after all: if you sent it again, it's there twice."
            }
        }
    }

    /// An outbox message, back in the composer as it was (its text before what's there, its images attached),
    /// and out of the outbox.
    func putBack(_ entry: OutboxEntry, rowID: String) {
        // Typed in: it may still arrive (see `takeOutArrived`).
        if entry.state == .typed {
            var message = PendingMessage(text: entry.message, afterPrompts: 0, sentAt: entry.sentAt, attachments: entry.attachments)
            message.id = entry.id
            putBackTyped.append((message, rowID, entry.text, entry.attachments))
        }
        let draft = composer.drafts[rowID] ?? ""
        composer.drafts[rowID] = entry.text.isEmpty ? draft : draft.isEmpty ? entry.text : entry.text + "\n\n" + draft
        var images = entry.attachments
        images += (composer.attachments[rowID] ?? []).filter { !images.contains($0) }
        composer.attachments[rowID] = images
        composer.save()
        outbox.remove(entry.id)
        pending.removeAll { $0.id == entry.id }
        updateLate()
        focusComposer()
    }

    func dismiss(_ message: PendingMessage) {
        outbox.remove(message.id)
        pending.removeAll { $0.id == message.id }
        updateLate()
    }

    /// Loads what `/` and `@` offer for this folder (off the main thread; files are re-listed when asked again).
    func loadCompletions(agent: Agent, folder: String?) {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        DispatchQueue.global(qos: .utility).async {
            var commandDirs: [URL] = [], skillDirs: [URL] = []
            switch agent {
            case .claude:
                commandDirs = [home.appendingPathComponent(".claude/commands")]
                skillDirs = [home.appendingPathComponent(".claude/skills")]
                if let folder {
                    commandDirs.append(URL(fileURLWithPath: folder).appendingPathComponent(".claude/commands"))
                    skillDirs.append(URL(fileURLWithPath: folder).appendingPathComponent(".claude/skills"))
                }
            case .codex:
                commandDirs = []
            }
            var commands = SlashCatalog.builtins(agent) + SlashCatalog.scan(commandDirs: commandDirs, skillDirs: skillDirs)
            if agent == .codex {
                commands += SlashCatalog.scan(commandDirs: [home.appendingPathComponent(".codex/prompts")], skillDirs: [])
                    .map { SlashCommand(name: "prompts:\($0.name)", description: $0.description) }
            }
            let files = folder.map { FileIndex.files(in: $0) } ?? []
            DispatchQueue.main.async {
                self.commands = commands
                self.files = files
            }
        }
    }

    func scrollToBottom() { scrollToBottomRequests += 1 }

    func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private static var seen: [String: String] {
        let stored = UserDefaults.standard.dictionary(forKey: seenKey) ?? [:]
        return stored.compactMapValues { ($0 as? [String: Any])?["id"] as? String }
    }

    // MARK: Reading (off the main thread)

    private struct Read {
        var events: [ChatEvent]
        /// Bytes of a partial first line skipped.
        var skipped: Int
        var consumed: Int
    }

    private static func readTail(url: URL, format: TranscriptReader.Format) -> (events: [ChatEvent], start: Int, cursor: Int)? {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int else { return nil }
        let start = max(0, size - pageBytes)
        guard let read = read(url: url, from: start, to: size, skipPartialFirstLine: start > 0, format: format) else { return nil }
        return (read.events, start + read.skipped, start + read.skipped + read.consumed)
    }

    private static func read(url: URL, from start: Int, to end: Int, skipPartialFirstLine: Bool,
                             format: TranscriptReader.Format) -> Read? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(start))) != nil,
              var data = try? handle.read(upToCount: end - start) else { return nil }
        var skipped = 0
        if skipPartialFirstLine {
            skipped = data.firstIndex(of: 0x0A).map { $0 - data.startIndex + 1 } ?? data.count
            data = data.subdata(in: (data.startIndex + skipped)..<data.endIndex)
        }
        let result = ChatReader.read(data, format: format)
        return Read(events: result.events, skipped: skipped, consumed: result.consumed)
    }
}
