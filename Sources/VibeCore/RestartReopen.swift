import Foundation

/// After a Mac restart: the window sessions that were open, offered once to reopen (the restart card).
///
/// The session host keeps the window sessions, so they outlive an app relaunch; a restart ends the host and every
/// session with it. The app keeps a record of the live ones (`Record`, rewritten as they start and end, so a hard
/// shutdown with no quit still leaves it current); at launch, a host that has none of them (none running, or a new one)
/// means they're gone, and the card lists them (`offer`). Your own sessions and the leads only: a lead's workers and
/// verifiers are its to restart (`leadNotice`).
public enum RestartReopen {
    /// What a session was to you: one of your own, or a project lead.
    public enum Role: String, Codable, Sendable {
        case user, lead
    }

    /// One recorded session: enough to resume its conversation in its folder with no host to ask.
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        /// The session host's id it had.
        public var id: UUID
        /// Where its window session was started (a lead's: its repository).
        public var folder: String
        public var agent: Agent
        /// The agent's own session id (from its hooks): what `--resume` takes. Nil until its hooks said it.
        public var agentSessionID: String?
        public var role: Role
        /// The repository or folder name: "acme".
        public var project: String
        /// What the list called it: your name for it, else the project.
        public var name: String
        /// The preset's command it ran (the resume is that plus `--resume <id>`); nil when it ran the agent plainly.
        public var command: String?
        /// The window session's label ("Claude", "Lead · acme").
        public var label: String
        public var cols: Int
        public var rows: Int

        public init(id: UUID, folder: String, agent: Agent, agentSessionID: String?, role: Role, project: String, name: String,
                    command: String?, label: String, cols: Int, rows: Int) {
            self.id = id
            self.folder = folder
            self.agent = agent
            self.agentSessionID = agentSessionID
            self.role = role
            self.project = project
            self.name = name
            self.command = command
            self.label = label
            self.cols = cols
            self.rows = rows
        }
    }

    /// The live sessions to record, from the host's list and the store's sessions (which carry the agent's session id,
    /// your name for it and its role). `previous`: the record so far, whose agent session id and name a session keeps
    /// while a scan doesn't say them (its hooks not read yet). Ended sessions, plain shells and the leads' workers and
    /// verifiers aren't recorded.
    public static func entries(hosted: [HostSession], sessions: [Session], previous: [Entry]) -> [Entry] {
        let known = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        let agents = Dictionary(sessions.compactMap { session in session.hostID.map { ($0, session) } }, uniquingKeysWith: { $1 })
        return hosted.filter(\.isLive).compactMap { host in
            let session = agents[host.id], before = known[host.id]
            guard let agent = session?.agent ?? host.agent.flatMap(Agent.init(rawValue:)) ?? before?.agent else { return nil }
            let role: Role
            switch session?.teamRole ?? LeadTeams.role(label: host.label) {
            case .worker?, .verifier?: return nil
            case .lead?: role = .lead
            case nil: role = .user
            }
            let project = session?.project ?? before?.project ?? SessionNaming.name(forProjectRoot: host.cwd)
            return Entry(id: host.id, folder: host.cwd, agent: agent, agentSessionID: session?.agentSessionID ?? before?.agentSessionID,
                         role: role, project: project, name: session?.displayName ?? before?.name ?? project,
                         command: host.command, label: host.label, cols: host.cols, rows: host.rows)
        }
    }

    /// The recorded sessions the card lists at launch, given the host's sessions (nil: no host runs). None when the host
    /// has any of them (the app relaunched onto the host they live in: a session that ended meanwhile is no restart), or
    /// when the record is empty.
    public static func offer(record: [Entry], hostSessions: [HostSession]?) -> [Entry] {
        let listed = Set((hostSessions ?? []).map(\.id))
        guard !record.contains(where: { listed.contains($0.id) }) else { return [] }
        return ordered(record)
    }

    /// Leads first (their teams wait on them), then your own sessions, each in the recorded order.
    public static func ordered(_ entries: [Entry]) -> [Entry] {
        entries.filter { $0.role == .lead } + entries.filter { $0.role != .lead }
    }

    /// Why a session can't be resumed: it would otherwise start a fresh conversation, which reopening never does.
    public enum Blocker: Equatable, Sendable {
        case noConversation, folderGone

        public var text: String {
            switch self {
            case .noConversation: return "Can't reopen: its conversation id wasn't known"
            case .folderGone: return "Can't reopen: its folder is gone"
            }
        }
    }

    public static func blocker(_ entry: Entry, folderExists: (String) -> Bool = RestartReopen.isFolder) -> Blocker? {
        guard let id = entry.agentSessionID, !id.isEmpty else { return .noConversation }
        return folderExists(entry.folder) ? nil : .folderGone
    }

    public static func isFolder(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    /// The sessions a click reopens, in order (leads first): `chosen` (Choose's ticks; nil: Reopen all), less those
    /// that can't be resumed.
    public static func toReopen(_ offered: [Entry], chosen: Set<UUID>?, folderExists: (String) -> Bool = RestartReopen.isFolder) -> [Entry] {
        ordered(offered).filter { entry in (chosen?.contains(entry.id) ?? true) && blocker(entry, folderExists: folderExists) == nil }
    }

    /// What a user session's resume runs: the sidebar's Resume (`LaunchPlan.resumeCommand`), the same conversation in
    /// the same folder.
    public static func spawnRequest(_ entry: Entry) -> SpawnRequest? {
        guard let id = entry.agentSessionID, !id.isEmpty else { return nil }
        return LaunchPlan.resumeRequest(cwd: entry.folder, base: entry.command, agent: entry.agent, sessionID: id,
                                        cols: entry.cols, rows: entry.rows, label: entry.label)
    }

    /// The one message a reopened lead starts with: the Mac restarted, its workers and verifiers ended, and which of
    /// its tasks had a worker running, to start again (`start_worker` continues in the task's worktree).
    public static func leadNotice(board: LeadBoard) -> String {
        let working = board.tasks.filter { $0.status == .running && $0.worker != nil && $0.worker != $0.stopped }
        let checking = board.tasks.filter { $0.status == .review && !$0.awaitedVerifiers.isEmpty }
        var text = "The Mac restarted, and its session host ended with every session in it: your workers and verifiers aren't running any more. "
            + "The user reopened you in your same conversation."
        if working.isEmpty {
            text += " No task had a worker running."
        } else {
            text += " Tasks that had workers running: " + working.map { "\($0.slug) (\($0.title))" }.joined(separator: ", ") + ". "
                + "Restart each with start_worker: it continues in the task's existing worktree, its commits kept."
        }
        if !checking.isEmpty {
            text += " Tasks whose verifier was checking: " + checking.map(\.slug).joined(separator: ", ") + "; audit starts it again."
        }
        return text + " Check the board first."
    }

    /// The record on disk: the live sessions as last seen, written whenever they change.
    public struct Record: Codable, Equatable, Sendable {
        public var entries: [Entry]
        public var updatedAt: Date

        public init(entries: [Entry], updatedAt: Date = Date()) {
            self.entries = entries
            self.updatedAt = updatedAt
        }
    }

    public static var file: URL { VibePaths.root.appendingPathComponent("open-sessions.json") }

    /// The record's sessions, or none (no file, or one this build can't read).
    public static func load(from file: URL = RestartReopen.file) -> [Entry] { loadRecord(from: file)?.entries ?? [] }

    /// The record, or nil (no file, or one this build can't read).
    public static func loadRecord(from file: URL = RestartReopen.file) -> Record? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? decoder.decode(Record.self, from: data)
    }

    /// An entry less its window size: what decides whether the record needs writing again.
    public static func withoutSize(_ entry: Entry) -> Entry {
        var entry = entry
        entry.cols = 0
        entry.rows = 0
        return entry
    }

    /// When this Mac last started (nil: unknown).
    public static func bootTime() -> Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
    }

    /// Writes the record (0600, atomically, flushed: it has to be there after a power cut).
    public static func save(_ entries: [Entry], to file: URL = RestartReopen.file) throws {
        try VibePaths.ensurePrivate(file.deletingLastPathComponent())
        try VibePaths.writePrivate(try encoder.encode(Record(entries: entries)), to: file, syncing: { fsync($0) == 0 })
    }

    /// Writes the record off the caller's thread (an fsync can take a while, and the sessions change on every resize):
    /// one write at a time, in order, the latest record handed to it winning over any it hasn't started yet.
    public final class RecordWriter: @unchecked Sendable {
        public let file: URL
        private let failed: @Sendable (Error) -> Void
        private let queue = DispatchQueue(label: "vibeswitcher.restart-record", qos: .utility)
        private let lock = NSLock()
        private var next: [Entry]?
        private var draining = false

        public init(file: URL, failed: @escaping @Sendable (Error) -> Void = { _ in }) {
            self.file = file
            self.failed = failed
        }

        public func write(_ entries: [Entry]) {
            lock.lock()
            next = entries
            let start = !draining
            draining = true
            lock.unlock()
            if start { queue.async { self.drain() } }
        }

        /// Returns once every record handed to `write` so far is on disk.
        public func flush() { queue.sync {} }

        private func drain() {
            while true {
                lock.lock()
                guard let entries = next else {
                    draining = false
                    lock.unlock()
                    return
                }
                next = nil
                lock.unlock()
                do { try RestartReopen.save(entries, to: file) } catch { failed(error) }
            }
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
