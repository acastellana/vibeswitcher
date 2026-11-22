import Foundation

/// A project lead's chat as one conversation across handovers: the earlier lead sessions' turns with the user above
/// the live one's, a divider where each fresh session began (`LeadRotation.notice`). Display only: nothing read here
/// is ever sent to a session.
///
/// The record is the project's own (`<root>/.vibeswitcher/lead-handovers.json`), one entry written by each handover
/// that put a new lead in an old one's place, naming the old lead's transcript. A lead's earlier sessions are the chain
/// of handovers into it: the one into this session, the one into the session that one replaced, and so on.
public enum LeadChatHistory {
    public struct Handover: Codable, Equatable, Sendable {
        /// The replaced lead's window session, and the one that took its place.
        public var from: String
        public var to: String
        /// The replaced lead's transcript (nil: none was known).
        public var transcript: String?
        public var at: Double
        public var reason: String
        /// The project the lead led, and its role ("lead"): an entry naming anything else is never stitched.
        public var root: String
        public var role: String

        public init(from: String, to: String, transcript: String?, at: Double, reason: String, root: String, role: String = "lead") {
            self.from = from; self.to = to; self.transcript = transcript; self.at = at; self.reason = reason
            self.root = root; self.role = role
        }

        /// The divider's words.
        public var notice: String { LeadRotation.notice(reason: reason, at: Date(timeIntervalSince1970: at)) }
    }

    /// Whose earlier sessions a chat shows: a project lead's window session, in its project.
    public struct Source: Equatable, Sendable {
        public var root: String
        public var session: String
        public init(root: String, session: String) { self.root = root; self.session = session }
    }

    /// The source for a window session's chat: only a project lead's (by its label) has earlier sessions, never a
    /// worker's, a verifier's or a shell's.
    public static func source(label: String?, session: UUID?, cwd: String?) -> Source? {
        guard LeadTeams.role(label: label) == .lead, let session, let cwd, !cwd.isEmpty else { return nil }
        return Source(root: cwd, session: session.uuidString)
    }

    /// One earlier session: what it said with the user (empty when its transcript is missing or unreadable), then the
    /// handover that ended it.
    public struct Part: Equatable, Sendable {
        public var handover: Handover
        public var entries: [ChatEntry]
    }

    /// At most this many earlier sessions are read for a chat, each at most `tailBytes` from its end: opening a chat
    /// costs the same however many handovers the project has had.
    public static let maxSessions = 3
    public static let tailBytes = 1024 * 1024
    /// Entries the record keeps (the newest).
    public static let kept = 50

    /// The reason a handover the user started (a new lead over a running one) gives on its divider.
    public static let startedReason = "a new lead was started in its place"

    public static func file(root: String) -> String {
        (BoardStore(root: root).folder as NSString).appendingPathComponent("lead-handovers.json")
    }

    public static func load(root: String) -> [Handover] {
        guard let data = FileManager.default.contents(atPath: file(root: root)) else { return [] }
        return (try? JSONDecoder().decode([Handover].self, from: data)) ?? []
    }

    /// Records a handover in its project's record (the newest `kept`).
    public static func record(_ handover: Handover) throws {
        let path = file(root: handover.root)
        try VibePaths.ensurePrivate(URL(fileURLWithPath: (path as NSString).deletingLastPathComponent))
        let entries = (load(root: handover.root).filter { $0.to != handover.to } + [handover]).suffix(kept)
        try VibePaths.writePrivate(try JSONEncoder().encode(Array(entries)), to: URL(fileURLWithPath: path))
    }

    /// The handovers that led to `session`, oldest first, the newest `maxSessions`: only this project's lead
    /// handovers, each into the session the next one replaced.
    public static func chain(to session: String, root: String, records: [Handover]) -> [Handover] {
        let own = records.filter { $0.role == "lead" && $0.root == root }
        var chain: [Handover] = [], current = session, seen: Set<String> = [session]
        while chain.count < maxSessions, let into = own.last(where: { $0.to == current }), seen.insert(into.from).inserted {
            chain.insert(into, at: 0)
            current = into.from
        }
        return chain
    }

    /// The earlier sessions of the lead in `session`, oldest first. `read`: a transcript's last `tailBytes`, nil when
    /// it's missing or unreadable (its session then shows no turns, its divider still).
    public static func parts(session: String, root: String, home: String,
                             read: (URL) -> Data? = { tail($0) }) -> [Part] {
        let records = load(root: root)
        let into = Set(records.filter { $0.root == root && $0.role == "lead" }.map(\.to))
        return chain(to: session, root: root, records: records).map { handover in
            let data = handover.transcript.flatMap { TranscriptReader.checkedURL($0, home: home) }
                .flatMap { url, format in format == .claude ? read(url) : nil }
            var log = ChatLog()
            if let data { log.append(ChatReader.read(data, format: .claude).events) }
            return Part(handover: handover, entries: conversation(log.entries, startedByHandover: into.contains(handover.from)))
        }
    }

    /// The entries the chat shows of a session: without the handover's own machinery (the note request typed to the
    /// old lead, its note), and for a session a handover started, without its start prompt.
    public static func conversation(_ entries: [ChatEntry], startedByHandover: Bool) -> [ChatEntry] {
        entries.filter { entry in
            switch entry.kind {
            case .prompt(let text, _), .steered(let text, _):
                return !text.contains(LeadRotation.request) && !(startedByHandover && isStartPrompt(text))
            case .reply(let text):
                return !text.contains(LeadRotation.noteMarker)
            case .tool:
                return true
            }
        }
    }

    /// A lead's start prompt (`LeadPrompts.leadStart`), as typed or relayed.
    static func isStartPrompt(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(LeadPrompts.startOpening)
    }

    /// The chat's items for the earlier sessions: each one's conversation, then its divider.
    public static func items(_ parts: [Part]) -> [ChatItem] {
        parts.flatMap { part in
            ChatTimeline.items(part.entries, newAfter: nil)
                + [.handover(id: "handover:\(part.handover.to)", notice: part.handover.notice, at: part.handover.at)]
        }
    }

    /// A transcript's last `tailBytes`, from its first whole line.
    public static func tail(_ url: URL) -> Data? {
        try? LeadRotation.tailData(path: url.path, bytes: UInt64(tailBytes))
    }
}
