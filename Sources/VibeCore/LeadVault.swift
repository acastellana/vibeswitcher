import CryptoKit
import Darwin
import Foundation

/// Who's who in a project lead's team, kept where the team's tools don't reach: `~/.vibeswitcher/lead/` (0700,
/// files 0600), outside every repository and worktree. Each session VibeSwitcher starts for a role gets a random
/// capability (in its tool server's environment) bound to that session; the role, the task, the verifier's verdict
/// and the lead's branch head as the lead last left it are read from here, never from the board or from the
/// tool server's arguments, which any worker can write.
///
/// The team runs as your Unix user, so this is a guard rail, not a sandbox: a process that reads these files (the
/// roles' deny rules keep their own tools out) could still forge them.
public struct LeadVault: Sendable {
    public struct Member: Codable, Equatable, Sendable {
        public var role: LeadLaunch.Role
        public var task: String?
        /// SHA-256 of the capability; the capability itself is only in the session's tool server's environment.
        public var tokenHash: String
        /// The session host's id of the session it was issued for, once it started.
        public var session: String?
        /// For a verifier: the branch's commit it was asked to check.
        public var auditing: String?
        public var issuedAt: Double
    }

    /// A verdict as the verifier's own tool server recorded it.
    public struct Verdict: Codable, Equatable, Sendable {
        public var task: String
        public var completion: LeadEvidence.Completion
        public var integrity: LeadEvidence.Integrity
        public var summary: String
        /// The commit it covers: the one the verifier was started on.
        public var commit: String
        /// The verifier that gave it (its capability's hash and its session).
        public var verifier: String
        public var session: String
        public var at: Double

        public var passes: Bool { completion == .complete && integrity == .clean }
    }

    struct Team: Codable {
        var root: String
        var members: [Member] = []
        var verdicts: [String: Verdict] = [:]
        /// Each branch's head as the lead last left it (after its own merges, or when it started).
        var heads: [String: String] = [:]
    }

    public let folder: URL

    public init(folder: URL) { self.folder = folder }

    public static var standard: LeadVault { LeadVault(folder: VibePaths.root.appendingPathComponent("lead", isDirectory: true)) }

    /// The environment variable a role's tool server finds its capability in.
    public static let environmentKey = "VIBESWITCHER_LEAD_CAPABILITY"

    // MARK: Capabilities

    /// A new capability for a role in the repository. It replaces the role's earlier one (the lead's, or the task's
    /// worker's or verifier's): only the newest session holds the role. A new verifier also voids the task's verdict.
    public func issue(role: LeadLaunch.Role, root: String, task: String?, auditing: String? = nil) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = generator.next() }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try update(root: root) { team in
            team.members.removeAll { $0.role == role && $0.task == task }
            if role == .verifier, let task { team.verdicts[task] = nil }
            team.members.append(Member(role: role, task: task, tokenHash: Self.hash(token), session: nil, auditing: auditing,
                                       issuedAt: Date().timeIntervalSince1970))
        }
        return token
    }

    /// Ties a capability to the session it was issued for (once the session host started it).
    public func bind(_ token: String, root: String, session: String) throws {
        try update(root: root) { team in
            guard let index = team.members.firstIndex(where: { $0.tokenHash == Self.hash(token) }) else { return }
            team.members[index].session = session
        }
    }

    /// Withdraws a capability (its session didn't start).
    public func revoke(_ token: String, root: String) throws {
        try update(root: root) { team in team.members.removeAll { $0.tokenHash == Self.hash(token) } }
    }

    /// A task is over (cleaned up): its worker's and verifier's capabilities and its verdict go.
    public func retire(root: String, task: String) throws {
        try update(root: root) { team in
            team.members.removeAll { $0.task == task }
            team.verdicts[task] = nil
        }
    }

    /// The lead starts (from VibeSwitcher, at your request): a new capability for it, and `branch` taken as it is
    /// now, as the head merges start from.
    public func startLead(root: String, branch: String) throws -> String {
        let capability = try issue(role: .lead, root: root, task: nil)
        let head = Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: root)
        if head.ok, !head.output.isEmpty { try setHead(head.output, root: root, branch: branch) }
        return capability
    }

    /// The member a capability belongs to in this repository, if it's still current.
    public func member(_ token: String, root: String) -> Member? {
        load(root: root).members.first { $0.tokenHash == Self.hash(token) }
    }

    /// The role's current member (the lead, or a task's worker or verifier).
    public func current(_ role: LeadLaunch.Role, root: String, task: String?) -> Member? {
        load(root: root).members.first { $0.role == role && $0.task == task }
    }

    // MARK: Verdicts

    public func record(_ verdict: Verdict, root: String) throws {
        try update(root: root) { $0.verdicts[verdict.task] = verdict }
    }

    public func verdict(root: String, task: String) -> Verdict? { load(root: root).verdicts[task] }

    public func clearVerdict(root: String, task: String) throws {
        try update(root: root) { $0.verdicts[task] = nil }
    }

    // MARK: The lead's branch

    /// The branch's head as the lead last left it.
    public func head(root: String, branch: String) -> String? { load(root: root).heads[branch] }

    public func setHead(_ commit: String, root: String, branch: String) throws {
        try update(root: root) { $0.heads[branch] = commit }
    }

    // MARK: Files

    /// Where a role's launch files go (they hold its capability).
    public func runFolder(root: String, name: String) -> URL {
        folder.appendingPathComponent("run/\(Self.key(root))/\(name)", isDirectory: true)
    }

    /// A private place for merges' scratch worktrees and locks.
    public func scratch(root: String, _ name: String) -> URL {
        folder.appendingPathComponent("scratch/\(Self.key(root))/\(name)")
    }

    /// Creates `folder` (and what's under it up to `url`) private to you.
    public func ensurePrivate(_ url: URL) throws {
        var created: [URL] = []
        var current = url
        while current.path.hasPrefix(folder.path), !FileManager.default.fileExists(atPath: current.path) {
            created.append(current)
            current = current.deletingLastPathComponent()
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for directory in created + [folder] { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
    }

    func teamFile(_ root: String) -> URL { folder.appendingPathComponent("teams/\(Self.key(root)).json") }

    func load(root: String) -> Team {
        guard let data = FileManager.default.contents(atPath: teamFile(root).path),
              let team = try? JSONDecoder().decode(Team.self, from: data) else { return Team(root: Self.canonical(root)) }
        return team
    }

    func update(root: String, _ change: (inout Team) throws -> Void) throws {
        let file = teamFile(root)
        try ensurePrivate(file.deletingLastPathComponent())
        let fd = open(file.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        flock(fd, LOCK_EX)
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        var team = load(root: root)
        try change(&team)
        try Self.writePrivate(try JSONEncoder().encode(team), to: file)
    }

    /// Writes a file only you can read (0600), atomically.
    public static func writePrivate(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        guard rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func canonical(_ root: String) -> String {
        URL(fileURLWithPath: (root as NSString).standardizingPath).resolvingSymlinksInPath().path
    }

    /// A repository's name in the vault: the same however its path is written.
    static func key(_ root: String) -> String { String(hash(canonical(root)).prefix(20)) }
}
