import Combine
import Foundation
import VibeCore

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
    /// Unsent text per session (row id), so switching sessions never sends a draft to the wrong one. Kept on
    /// disk, so a restart (or an update) doesn't lose what you were typing.
    @Published var drafts: [String: String] = UserDefaults.standard.dictionary(forKey: "chatDrafts") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(drafts.filter { !$0.value.isEmpty }, forKey: "chatDrafts") }
    }
    /// Images attached to each session's draft (paths), shown as thumbnails and sent with the message.
    @Published var attachments: [String: [String]] = UserDefaults.standard.dictionary(forKey: "chatAttachments") as? [String: [String]] ?? [:] {
        didSet { UserDefaults.standard.set(attachments.filter { !$0.value.isEmpty }, forKey: "chatAttachments") }
    }

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
    private var reading = false
    private let queue = DispatchQueue(label: "vibeswitcher.chat-reads", qos: .userInitiated)

    private func updateItems() {
        let new = ChatTimeline.items(log.entries, newAfter: markerAfter)
        guard new != items else { return }
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
    /// Items on screen right now (kept current by the view), to know where you were reading.
    var visibleItems: [String: Int] = [:]
    var atBottom = true
    /// Where to scroll when the conversation opens (set from what was kept).
    private(set) var restoreAnchor: String?

    /// Shows the conversation in `path` (nil: none). Same path: nothing changes.
    func show(path: String?) {
        guard path != self.path else { return }
        if let old = self.path {
            let anchor = atBottom ? nil : visibleItems.min { $0.value < $1.value }?.key
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
        visibleItems = [:]
        atBottom = true
        shownLimit = ChatWindow.page
        hasEarlier = false
        loadingEarlier = false
        pending = []
        steering = []
        steeringTTY = nil
        menu = nil
        mode = nil
        cursor = 0
        earliest = 0
        reading = false
        guard let path, let (url, format) = TranscriptReader.checkedURL(path, home: NSHomeDirectory()) else {
            url = nil
            markerAfter = nil
            state = path == nil ? .none : .failed("No conversation for this session yet.")
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
                self.hasEarlier = read.start > 0
                // Nothing new since you looked: no marker.
                if self.markerAfter == log.entries.last?.id { self.markerAfter = nil }
                // Lay out enough to reach where you were reading, or what's new if it isn't far back.
                self.widen(toInclude: self.restoreAnchor)
                self.widen(toInclude: "new-marker", atMost: 3 * ChatWindow.page)
                self.state = .ready
            }
        }
    }

    /// Reads what was added to the file since the last read (call about once a second while shown).
    func poll() {
        // Not there yet (a new session writes its transcript with the first message): try again.
        if case .failed = state, let path, !reading {
            self.path = nil
            return show(path: path)
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
                    self.show(path: path)
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
                if !self.pending.isEmpty { self.pending = PendingMessage.remaining(self.pending, prompts: self.log.prompts) }
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

    func showEarlier() { shownLimit += ChatWindow.page }

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

    /// Drops steered messages the agent has taken (they show from the transcript then).
    func refreshSteering() {
        guard let tty = steeringTTY, !steering.isEmpty else { return }
        let delivered = SteerInbox.delivered(tty: tty)
        let pending = Set(SteerInbox.pending(tty: tty).map(\.id))
        // Taken, or gone from the inbox (a new agent on that terminal dropped it).
        let left = steering.filter { !delivered.contains($0.id) && pending.contains($0.id) }
        if left != steering { steering = left }
    }

    /// Records a message sent while the agent works, until the transcript shows it.
    func sent(_ text: String) {
        pending.append(PendingMessage(text: text, afterPrompts: log.prompts.count))
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
