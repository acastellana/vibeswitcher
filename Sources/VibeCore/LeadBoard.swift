import Darwin
import Foundation

/// What a worker is asked to do: the bounded contract it runs and the verifier checks.
public struct LeadContract: Codable, Equatable, Sendable {
    public var goal: String
    /// Checks the result must pass (commands to run, behaviors to see).
    public var acceptance: [String]
    /// What it must not touch or do.
    public var boundaries: [String]
    /// What it should know: files, decisions, earlier evidence.
    public var context: String

    public init(goal: String, acceptance: [String], boundaries: [String], context: String) {
        self.goal = goal
        self.acceptance = acceptance
        self.boundaries = boundaries
        self.context = context
    }
}

/// The verifier's report: what it found in the worker's branch, not what the worker said.
public struct LeadEvidence: Codable, Equatable, Sendable {
    public enum Completion: String, Codable, Sendable { case complete, incomplete, blocked }
    public enum Integrity: String, Codable, Sendable { case clean, suspect, violation }
    public var completion: Completion
    public var integrity: Integrity
    public var summary: String
    public var at: Double
    /// The branch's commit the verifier looked at: only that commit may be merged on this verdict.
    public var commit: String?

    public init(completion: Completion, integrity: Integrity, summary: String, commit: String? = nil, at: Double = Date().timeIntervalSince1970) {
        self.completion = completion
        self.integrity = integrity
        self.summary = summary
        self.commit = commit
        self.at = at
    }

    public var passes: Bool { completion == .complete && integrity == .clean }
}

/// A milestone a worker noted with its `progress` tool.
public struct LeadCheckpoint: Codable, Equatable, Sendable {
    public var text: String
    public var at: Double

    public init(text: String, at: Double = Date().timeIntervalSince1970) {
        self.text = text
        self.at = at
    }
}

/// Why a task last failed: an audit that didn't pass, or a merge that conflicted or failed its tests. Kept when the
/// task goes back to work, so what's being reworked stays in view.
public struct LeadSetback: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable { case review, merge }
    public var stage: Stage
    public var reason: String
    /// The verdict, when an audit failed it.
    public var evidence: LeadEvidence?
    public var at: Double

    public init(stage: Stage, reason: String, evidence: LeadEvidence? = nil, at: Double = Date().timeIntervalSince1970) {
        self.stage = stage
        self.reason = reason
        self.evidence = evidence
        self.at = at
    }
}

/// What a merge put on the lead's branch.
public struct LeadMergeRecord: Codable, Equatable, Sendable {
    public var commit: String
    /// The test command ran on it and passed (false: there was none, so nothing ran).
    public var tested: Bool
    public var at: Double

    public init(commit: String, tested: Bool, at: Double = Date().timeIntervalSince1970) {
        self.commit = commit
        self.tested = tested
        self.at = at
    }
}

public struct LeadTask: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable, CaseIterable {
        /// On the board, no worker yet.
        case planned
        /// A worker has it.
        case running
        /// The worker says it's done; the verifier checks.
        case review
        /// Verified and merged.
        case done
        /// Verified as not done (or the worker gave up); the lead decides what next.
        case failed
        /// Waiting on something (an answer, another task).
        case blocked
    }

    public var id: String
    public var slug: String
    public var title: String
    public var contract: LeadContract
    public var status: Status
    /// The session host's id of the worker running it.
    public var worker: String?
    public var verifier: String?
    /// The worker session the lead itself stopped (stop_worker): its end is no news to the lead.
    public var stopped: String?
    public var branch: String?
    public var worktree: String?
    public var evidence: LeadEvidence?
    public var createdAt: Double
    // The fields below are optional: older boards have none of them.
    /// When it took its current status (`BoardStore.update` stamps every change).
    public var since: Double?
    /// When its first worker started.
    public var startedAt: Double?
    /// Rounds of work: 1 for the first worker, one more each time it goes back to work after failing (the lead
    /// messages its worker or starts a new one).
    public var attempts: Int?
    /// Why it last failed; kept through the rework.
    public var setback: LeadSetback?
    /// Why it's blocked (the worker's words, or the lead stopped it); cleared when it works again.
    public var blocker: String?
    /// The worker's milestones, oldest first.
    public var checkpoints: [LeadCheckpoint]?
    /// The worker's last "done" report.
    public var report: String?
    public var merged: LeadMergeRecord?

    public static let keptCheckpoints = 40

    /// Rework rounds so far (0 on the first attempt).
    public var rework: Int { max(0, (attempts ?? 1) - 1) }

    public init(id: String = UUID().uuidString, slug: String, title: String, contract: LeadContract, status: Status = .planned) {
        self.id = id
        self.slug = slug
        self.title = title
        self.contract = contract
        self.status = status
        self.createdAt = Date().timeIntervalSince1970
    }
}

/// Something the lead asked you; the answer is steered back into it.
public struct LeadQuestion: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var options: [String]
    public var answer: String?
    public var askedAt: Double
    public var answeredAt: Double?

    public init(id: String = UUID().uuidString, text: String, options: [String]) {
        self.id = id
        self.text = text
        self.options = options
        self.askedAt = Date().timeIntervalSince1970
    }
}

/// A result the lead wants you to see.
public struct LeadUpdate: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var body: String
    /// Image files (screenshots) and a branch or diff to look at.
    public var images: [String]
    public var at: Double

    public init(id: String = UUID().uuidString, title: String, body: String, images: [String] = []) {
        self.id = id
        self.title = title
        self.body = body
        self.images = images
        self.at = Date().timeIntervalSince1970
    }
}

/// Something a worker or verifier told the lead (done, blocked, a question, a verdict), kept so the lead's status lists
/// what came in even if the message itself never reached it.
public struct LeadReport: Codable, Equatable, Sendable {
    /// Who it's from ("worker add-b", "verifier add-b").
    public var about: String
    public var text: String
    public var at: Double

    public init(about: String, text: String, at: Double = Date().timeIntervalSince1970) {
        self.about = about
        self.text = text
        self.at = at
    }
}

public struct LeadBoard: Codable, Equatable, Sendable {
    /// The lead's session (host id) and agent pid, so answers and events can be steered into it.
    public var leadSession: String?
    public var leadPid: Int32?
    public var leadTTY: String?
    /// The branch the lead builds on and merges into: the one checked out when it first started here.
    public var baseBranch: String?
    public var tasks: [LeadTask] = []
    public var questions: [LeadQuestion] = []
    public var updates: [LeadUpdate] = []
    /// The latest reports for the lead, oldest first, and when its status last listed them. Optional: older boards
    /// have neither.
    public var reports: [LeadReport]?
    public var reportsSeenAt: Double?

    public static let keptReports = 50

    public init() {}

    public func task(_ id: String) -> LeadTask? { tasks.first { $0.id == id || $0.slug == id } }
    public func taskIndex(_ id: String) -> Int? { tasks.firstIndex { $0.id == id || $0.slug == id } }
}

public struct BoardError: Error, CustomStringConvertible {
    public var text: String
    public var description: String { text }
}

/// An exclusive lock on a file, across processes, taken only if free.
public final class FileLock {
    private var fd: Int32

    private init(fd: Int32) { self.fd = fd }

    public static func attempt(_ path: String) -> FileLock? {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return FileLock(fd: fd)
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}

/// The board on disk: `<repo>/.vibeswitcher/board.json`, with the progress log and decisions next to it.
public final class BoardStore: @unchecked Sendable {
    public let root: String
    public var folder: String { (root as NSString).appendingPathComponent(".vibeswitcher") }
    var file: String { (folder as NSString).appendingPathComponent("board.json") }
    private let local = NSLock()

    public init(root: String) { self.root = root }

    /// The board, or an empty one when there's none or it can't be read (for showing it).
    public func load() -> LeadBoard { (try? read()) ?? LeadBoard() }

    /// The board; throws when the file is there but doesn't read (a hand edit, a newer version), so nothing
    /// writes an empty board over it.
    public func read() throws -> LeadBoard {
        guard let data = FileManager.default.contents(atPath: file) else { return LeadBoard() }
        do {
            return try JSONDecoder().decode(LeadBoard.self, from: data)
        } catch {
            throw BoardError(text: "\(file) doesn't read as a board (\(error)); fix or move it, nothing was changed.")
        }
    }

    /// Reads, changes and writes the board under a lock (other processes too), atomically.
    @discardableResult
    public func update<T>(_ change: (inout LeadBoard) throws -> T) throws -> T {
        try ensureFolder()
        local.lock()
        defer { local.unlock() }
        let fd = open(file + ".lock", O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        flock(fd, LOCK_EX)
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        var board = try read()
        let before = Dictionary(board.tasks.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
        let result = try change(&board)
        // Each status change is stamped, whoever made it: how long a task has been where it is.
        let now = Date().timeIntervalSince1970
        for index in board.tasks.indices where before[board.tasks[index].id] != board.tasks[index].status {
            board.tasks[index].since = before[board.tasks[index].id] == nil ? board.tasks[index].createdAt : now
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(board).write(to: URL(fileURLWithPath: file), options: .atomic)
        return result
    }

    public func appendProgress(_ line: String) throws {
        try append("- \(Self.stamp()) \(line)\n", to: "progress.md", header: "# Progress\n\n")
    }

    public func appendDecision(_ decision: String, why: String) throws {
        try append("## \(Self.stamp()) \(decision)\n\n\(why)\n\n", to: "decisions.md", header: "# Decisions\n\n")
    }

    /// Sets a repository up for a lead: the `.vibeswitcher` folder, kept out of git, with the workflow notes (a
    /// template the first time; yours are never overwritten). Returns the workflow file's path.
    @discardableResult
    public func prepare() throws -> String {
        try ensureFolder()
        try ensureExcluded()
        // The lead's branch: what you're on now, kept for the next leads here (switching branches later doesn't
        // move it; `base_branch:` in the workflow does).
        if try read().baseBranch == nil {
            let branch = Worktrees.currentBranch(root: root) ?? Worktrees.mainBranch(root: root)
            try update { if $0.baseBranch == nil { $0.baseBranch = branch } }
        }
        let workflow = (folder as NSString).appendingPathComponent("workflow.md")
        if !FileManager.default.fileExists(atPath: workflow) {
            try LeadWorkflow.template.write(toFile: workflow, atomically: true, encoding: .utf8)
        }
        return workflow
    }

    /// `.vibeswitcher/` in `.git/info/exclude`: ignored without changing the repo's own files.
    public func ensureExcluded() throws {
        // Where git keeps it: `.git/info/exclude`, or the main repository's when `.git` is a file (a worktree).
        let asked = Git.run(["rev-parse", "--git-path", "info/exclude"], in: root)
        let exclude = asked.ok && !asked.output.isEmpty
            ? (asked.output.hasPrefix("/") ? asked.output : (root as NSString).appendingPathComponent(asked.output))
            : (root as NSString).appendingPathComponent(".git/info/exclude")
        let current = (try? String(contentsOfFile: exclude, encoding: .utf8)) ?? ""
        guard !current.components(separatedBy: "\n").contains("/.vibeswitcher/") else { return }
        try FileManager.default.createDirectory(atPath: (exclude as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let line = (current.isEmpty || current.hasSuffix("\n") ? "" : "\n") + "/.vibeswitcher/\n"
        try (current + line).write(toFile: exclude, atomically: true, encoding: .utf8)
    }

    private func ensureFolder() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    private func append(_ text: String, to name: String, header: String) throws {
        try ensureFolder()
        let path = (folder as NSString).appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: path) { try header.write(toFile: path, atomically: true, encoding: .utf8) }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }
}

/// Branch- and folder-safe names for tasks.
public enum Slug {
    public static func make(_ title: String, taken: Set<String>) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var words: [String] = []
        var current = ""
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        var base = ""
        // The first few words, short enough for a branch name.
        for (index, word) in words.enumerated() {
            let next = base.isEmpty ? String(word.prefix(24)) : base + "-" + word
            guard index < 4, next.count <= 24 else { break }
            base = next
        }
        if base.isEmpty { base = "task" }
        var slug = base
        var number = 2
        while taken.contains(slug) {
            slug = "\(base)-\(number)"
            number += 1
        }
        return slug
    }
}
