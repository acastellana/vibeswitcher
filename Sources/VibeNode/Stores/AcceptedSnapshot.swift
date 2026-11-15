import Foundation
import VibeCore

/// The last accepted state of each project (the security document's S7: "a diff aid, not a lock"), at
/// `<root>/v2/accepted.json` (format 1), written at each accept (the engine plan's E8): `config accept` keeps the
/// sealed config's hashes (every watched thing the vault records once it sealed the card's), the guard rails' values
/// and the review floor the card showed; `base accept` keeps the base's head. After a host restart, whose vault starts
/// over, `config held` then says of each held thing whether it is the same as at the last accept, changed, or new
/// (`since`), and `base show` takes the snapshot's head as "from", marked unverified. It is unsealed: a worker of the
/// user's uid can rewrite it, so the user reads the values, not just the marks, and nothing here is ever taken as
/// accepted (the vault's record is).
public struct AcceptedSnapshot: Codable, Equatable, Sendable {
    public static let currentFormat = 1

    /// One project's last accepts.
    public struct Project: Codable, Equatable, Sendable {
        /// When `config accept` last ran for it (seconds since 1970), and what it left recorded.
        public var configAt: Double?
        /// The watched things' hashes by the vault's key (`ConfigSeal.isWatchedKey`).
        public var hashes: [String: String]
        /// The guard rails' values, by key, as the card showed them.
        public var guarded: [String: String]
        public var floor: LeadReviewFloor?
        /// When `base accept` last ran for it, and the head it recorded, by branch.
        public var headsAt: Double?
        public var heads: [String: String]

        public init(configAt: Double? = nil, hashes: [String: String] = [:], guarded: [String: String] = [:], floor: LeadReviewFloor? = nil,
                    headsAt: Double? = nil, heads: [String: String] = [:]) {
            self.configAt = configAt
            self.hashes = hashes
            self.guarded = guarded
            self.floor = floor
            self.headsAt = headsAt
            self.heads = heads
        }
    }

    public var format: Int
    /// By root.
    public var projects: [String: Project]

    public init(projects: [String: Project] = [:]) {
        format = Self.currentFormat
        self.projects = projects
    }

    /// `<root>/v2/accepted.json`.
    public static func url(root: URL) -> URL {
        root.appendingPathComponent("v2", isDirectory: true).appendingPathComponent("accepted.json")
    }

    /// The snapshot at `root`: empty when there's none, or it doesn't read (it's a diff aid: nothing is lost that the
    /// vault needs).
    public static func load(root: URL) -> AcceptedSnapshot {
        guard let data = try? Data(contentsOf: url(root: root)), let snapshot = try? JSONDecoder().decode(AcceptedSnapshot.self, from: data),
              snapshot.format == currentFormat else { return AcceptedSnapshot() }
        return snapshot
    }

    /// One read-change-write at a time in this process (the accepts are asked off the engine's queue).
    private static let lock = NSLock()

    /// `project`'s entry changed by `change` and written at `root` (0600, in a 0700 `v2` folder, whole and renamed into
    /// place). A root that isn't there is never made for it: that throws.
    public static func update(root: URL, project: String, _ change: (inout Project) -> Void) throws {
        try lock.withLock {
            var snapshot = load(root: root)
            var entry = snapshot.projects[project] ?? Project()
            change(&entry)
            snapshot.projects[project] = entry
            guard FileManager.default.fileExists(atPath: root.path) else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: root.path]) }
            let url = url(root: root)
            try VibePaths.ensurePrivate(url.deletingLastPathComponent(), within: root)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try VibePaths.writePrivate(try encoder.encode(snapshot), to: url)
        }
    }

    /// What a held thing (`key`, the vault's, with the `hash` it's held at) is against the last accept, in words: the
    /// same, changed, or not in it; nil when no accept is known for the project.
    public static func since(key: String, hash: String, in project: Project?) -> String? {
        guard let project, let at = project.configAt else { return nil }
        let when = NodeWire.dateText(Date(timeIntervalSince1970: at))
        switch project.hashes[key] {
        case hash?: return "the same as at your last accept (\(when))"
        case .some: return "changed since your last accept (\(when))"
        case nil: return "not in your last accept (\(when))"
        }
    }

    /// The same for a guard rail's value now.
    public static func since(rail key: String, value: String, in project: Project?) -> String? {
        guard let project, let at = project.configAt else { return nil }
        let when = NodeWire.dateText(Date(timeIntervalSince1970: at))
        switch project.guarded[key] {
        case value?: return "the same as at your last accept (\(when))"
        case .some(let before): return "changed since your last accept (\(when)), from “\(ConfigSeal.inert(before, limit: 200))”"
        case nil: return "not in your last accept (\(when))"
        }
    }
}
