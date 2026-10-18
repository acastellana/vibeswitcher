import Foundation

/// Whether a prompt in the transcript is a message sent from the composer. Attached images go as their quoted
/// paths, and Claude Code turns each one into an image block and writes `[Image #N]` in the text instead (at the
/// start, wherever the path was): so the texts are compared without paths and placeholders, and the images counted.
public enum SentMatch {
    /// A prompt as the transcript has it.
    public struct Prompt: Equatable, Sendable {
        public var text: String
        public var images: Int
        public var at: Date?

        public init(text: String, images: Int = 0, at: Date? = nil) {
            self.text = text
            self.images = images
            self.at = at
        }
    }

    /// A prompt written this long before a message was sent can still be it (the transcript's clock is the same,
    /// its timestamp a little coarser).
    public static let clockSlack: TimeInterval = 2

    public static func prompts(_ entries: [ChatEntry]) -> [Prompt] {
        entries.compactMap { entry in
            guard case .prompt(let text, let images) = entry.kind else { return nil }
            return Prompt(text: text, images: images.count, at: entry.at)
        }
    }

    /// `sent` is the message as typed (attachment paths included), `attachments` the image paths in it.
    public static func matches(_ sent: String, attachments: [String], prompt: Prompt) -> Bool {
        let mine = stripped(sent, paths: attachments)
        let theirs = stripped(prompt.text, paths: attachments)
        guard mine.text == theirs.text else { return false }
        guard !attachments.isEmpty else { return true }
        // Each image arrived as a block (or its placeholder), or stayed a path the agent didn't turn into one.
        return max(prompt.images, theirs.placeholders) + theirs.paths >= attachments.count
    }

    /// Whether `prompt` can be the reply to a message sent at `sentAt` (not one from before it).
    public static func isAfter(_ prompt: Prompt, _ sentAt: Date) -> Bool {
        prompt.at.map { $0 >= sentAt.addingTimeInterval(-clockSlack) } ?? true
    }

    /// The text without the paths (quoted or not) and `[Image #N]` placeholders, whitespace collapsed; and how
    /// many of each it had.
    static func stripped(_ text: String, paths: [String]) -> (text: String, paths: Int, placeholders: Int) {
        var text = text
        var found = 0
        for path in paths where !path.isEmpty {
            for form in [RecentProjects.shellQuote(path), path] {
                let parts = text.components(separatedBy: form)
                found += parts.count - 1
                text = parts.joined(separator: " ")
            }
        }
        let placeholder = try! NSRegularExpression(pattern: #"\[Image #\d+\]"#)
        let range = NSRange(text.startIndex..., in: text)
        let placeholders = placeholder.numberOfMatches(in: text, range: range)
        text = placeholder.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return (words.joined(separator: " "), found, placeholders)
    }
}

/// A message sent from the composer, kept on disk from before it goes out until the conversation shows it.
public struct OutboxEntry: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        /// Saved; the session host hasn't confirmed it wrote it into the terminal.
        case sending
        /// The host wrote it into the session's terminal; not in the conversation yet.
        case typed
        /// The host didn't take it (gone, or no answer): it may not have gone out.
        case failed
    }

    public var id: UUID
    /// The composer it was sent from (the row's draft key).
    public var key: String
    /// What was typed into the terminal: the text, then the attachments' quoted paths.
    public var message: String
    /// The text as it was in the box, and the images attached to it (to put them back).
    public var text: String
    public var attachments: [String]
    public var sentAt: Date
    /// Typed into an idle agent: it shows in the conversation within seconds (a queued one waits for the turn).
    public var expectsSoon: Bool
    public var state: State

    public init(id: UUID = UUID(), key: String, message: String, text: String, attachments: [String] = [],
                sentAt: Date = Date(), expectsSoon: Bool = false, state: State = .sending) {
        self.id = id
        self.key = key
        self.message = message
        self.text = text
        self.attachments = attachments
        self.sentAt = sentAt
        self.expectsSoon = expectsSoon
        self.state = state
    }

    /// A slash command runs in the agent and never shows as a prompt: the host taking it is all there is.
    var showsAsPrompt: Bool { !message.hasPrefix("/") }
}

/// What the composer sent that the conversation doesn't show yet. An entry is saved before its message goes out
/// and leaves only when the conversation has it, or when you discard it or put it back in the box: a hang, crash
/// or relaunch mid-send leaves it here, never lost. Nothing in it is sent again unless you say so.
public struct Outbox: Equatable, Sendable {
    public private(set) var entries: [OutboxEntry]
    /// Entries from an earlier launch: shown for you to send again or discard.
    public private(set) var restored: Set<UUID>

    public init(entries: [OutboxEntry] = [], restored: Set<UUID> = []) {
        self.entries = entries
        self.restored = restored
    }

    /// What a launch starts with: everything an earlier one left, restored.
    public init(restoring entries: [OutboxEntry]) {
        self.init(entries: entries, restored: Set(entries.map(\.id)))
    }

    public func entry(_ id: UUID) -> OutboxEntry? { entries.first { $0.id == id } }

    /// Sent this launch and on its way (the chat shows these as sending / queued).
    public func onTheirWay(key: String) -> [OutboxEntry] {
        entries.filter { $0.key == key && $0.state != .failed && !restored.contains($0.id) }
    }

    /// Waiting for you to send again or discard: left by an earlier launch, or not taken by the host.
    public func needsYou(key: String) -> [OutboxEntry] {
        entries.filter { $0.key == key && ($0.state == .failed || restored.contains($0.id)) }
    }

    public mutating func add(_ entry: OutboxEntry) {
        entries.append(entry)
    }

    @discardableResult
    public mutating func remove(_ id: UUID) -> OutboxEntry? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        restored.remove(id)
        return entries.remove(at: index)
    }

    /// This launch's entry still sending `message` from `key` (the oldest).
    private func sending(key: String, message: String) -> Int? {
        entries.firstIndex { $0.key == key && $0.message == message && $0.state == .sending && !restored.contains($0.id) }
    }

    /// The host's answer for `message` sent from `key`: it goes to the oldest entry still sending it. A slash
    /// command it took is done. Returns the entry's id.
    @discardableResult
    public mutating func confirm(key: String, message: String, ok: Bool) -> UUID? {
        guard let index = sending(key: key, message: message) else { return nil }
        let id = entries[index].id
        if ok, !entries[index].showsAsPrompt {
            entries.remove(at: index)
        } else {
            entries[index].state = ok ? .typed : .failed
        }
        return id
    }

    /// Handed to the agent's steer inbox instead of typed (which keeps it from there): no longer the outbox's.
    @discardableResult
    public mutating func handedOff(key: String, message: String) -> UUID? {
        guard let index = sending(key: key, message: message) else { return nil }
        return remove(entries[index].id)?.id
    }

    /// Send now: sending again, from now, as one of this launch's.
    @discardableResult
    public mutating func resend(_ id: UUID, at now: Date = Date()) -> OutboxEntry? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        restored.remove(id)
        entries[index].state = .sending
        entries[index].sentAt = now
        return entries[index]
    }

    /// Drops the entries sent to window sessions the session host no longer has (`known`: every session it lists,
    /// live or ended): a session lost with a replaced host can't take them, and they'd be restored on every launch.
    /// Returns what it dropped.
    @discardableResult
    public mutating func dropGone(known: Set<UUID>) -> [OutboxEntry] {
        let gone = entries.filter { entry in
            guard entry.key.hasPrefix("host:"), let id = UUID(uuidString: String(entry.key.dropFirst(5))) else { return false }
            return !known.contains(id)
        }
        gone.forEach { remove($0.id) }
        return gone
    }

    /// Drops `key`'s entries the conversation has (`prompts`, oldest first), whatever their state: a message
    /// that arrived is never offered again. One prompt answers one entry. Returns the ids dropped.
    @discardableResult
    public mutating func delivered(key: String, prompts: [SentMatch.Prompt]) -> [UUID] {
        var used = Set<Int>()
        var dropped: [UUID] = []
        for entry in entries.filter({ $0.key == key }).sorted(by: { $0.sentAt < $1.sentAt }) {
            for index in prompts.indices where !used.contains(index) && SentMatch.isAfter(prompts[index], entry.sentAt) {
                if SentMatch.matches(entry.message, attachments: entry.attachments, prompt: prompts[index]) {
                    used.insert(index)
                    dropped.append(entry.id)
                    break
                }
            }
        }
        entries.removeAll { dropped.contains($0.id) }
        dropped.forEach { restored.remove($0) }
        return dropped
    }
}

/// The outbox on disk (`~/.vibeswitcher/outbox.json`), written whole on every change.
public enum OutboxStore {
    public static var defaultURL: URL { VibePaths.root.appendingPathComponent("outbox.json") }

    public static func load(_ url: URL = defaultURL) -> [OutboxEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([OutboxEntry].self, from: data)) ?? []
    }

    public static func save(_ entries: [OutboxEntry], to url: URL = defaultURL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(entries).write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
