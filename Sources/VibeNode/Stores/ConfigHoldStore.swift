import Foundation
import VibeCore

/// The agents' config each project's vault holds (`ConfigSeal`; the app's `ConfigHolds`, rebuilt without its view, the
/// engine plan's E6): changed while its workers or verifiers ran, or never sealed on a fresh vault that holds its first
/// look (S7), which holds new workers, verifiers and merges until the user accepts it. `config held` makes a card bound
/// to exactly the hashes it showed (`Shown.hashes`, the app's `shownHashes`); `config accept CARD` seals those and no
/// others (`checkConfig(root:shown:)`, which ends a root's first-look hold), **then** records the floor and the guard
/// rails `workflow.md` proposes, as the card showed them (EN-D7: the vault refuses the floor while the first look holds).
/// Names, times, sizes and hashes only: never a file's contents, but for the difference asked of one held thing
/// (`difference`), which reads the text the seal kept. Everything here reads the vault or the disk: never on the engine's
/// queue.
public enum ConfigHoldStore {
    /// One held thing as the card shows it.
    public struct Item: Equatable, Sendable {
        public var name: String
        /// When it last changed: a file's own time, a folder's newest changed file's (what the vault holds), none for a
        /// plugin or a settings file's scripts (`changedAt`).
        public var changedAt: Date?
        /// A file's size now; none for anything else.
        public var size: Int?
        /// The hash the card shows and the accept seals, its first 12 characters.
        public var hash: String
        /// What changed (its keys, "hooks.SessionStart added"; never a value), when the vault says.
        public var change: String?
        /// Changed outside a team session (code that runs: only the user's accept seals it).
        public var outside: Bool
        /// A held folder's files that changed.
        public var files: [ConfigSeal.HeldFile]
        /// What it is against the last accept the snapshot knows (`AcceptedSnapshot.since`: the same, changed, new),
        /// when one is known (E8). A diff aid: the snapshot is unsealed.
        public var sinceAccept: String?

        public init(name: String, changedAt: Date? = nil, size: Int? = nil, hash: String = "", change: String? = nil, outside: Bool = false,
                    files: [ConfigSeal.HeldFile] = [], sinceAccept: String? = nil) {
            self.name = name
            self.changedAt = changedAt
            self.size = size
            self.hash = hash
            self.change = change
            self.outside = outside
            self.files = files
            self.sinceAccept = sinceAccept
        }
    }

    /// One of workflow.md's guard rails as the card shows it (E8, S7: "a guarded key shows its value"): its key, its
    /// value now (the `test_command` text, the `merge_policy`), and what it is against the last accept.
    public struct Rail: Equatable, Sendable {
        public var key: String
        public var value: String
        public var sinceAccept: String?

        public init(key: String, value: String, sinceAccept: String? = nil) {
            self.key = key
            self.value = value
            self.sinceAccept = sinceAccept
        }
    }

    /// What a held-config card showed: the items, the hashes the accept seals, and what `workflow.md` proposes (the
    /// floor, and the guard rails' hashes with its `base_branch`'s, `recordedHashes`), recorded at the accept.
    public struct Shown: Equatable, Sendable {
        public var items: [Item]
        public var hashes: [String: String]
        public var floor: LeadReviewFloor?
        public var rails: [String: String]
        /// The base branch `workflow.md` names, as the card showed it.
        public var baseBranch: String?
        /// The guard rails workflow.md sets (a value that isn't empty), with their values, as the card showed them (E8).
        public var guarded: [Rail]
        /// When the last accept the snapshot knows was, if one is (E8).
        public var lastAccept: Date?

        public init(items: [Item] = [], hashes: [String: String] = [:], floor: LeadReviewFloor? = nil, rails: [String: String] = [:],
                    baseBranch: String? = nil, guarded: [Rail] = [], lastAccept: Date? = nil) {
            self.items = items
            self.hashes = hashes
            self.floor = floor
            self.rails = rails
            self.baseBranch = baseBranch
            self.guarded = guarded
            self.lastAccept = lastAccept
        }
    }

    /// The key `base_branch`'s hash is recorded under beside the guard rails: `base show` takes `workflow.md`'s base
    /// only while it is what the user accepted.
    public static let baseBranchKey = "base_branch"

    /// What `config accept` records of `workflow`: its guard rails' hashes (`LeadVault.guardedHashes`) and its base
    /// branch's.
    public static func recordedHashes(_ workflow: LeadWorkflow) -> [String: String] {
        LeadVault.guardedHashes(workflow).merging([baseBranchKey: LeadVault.hash(workflow.baseBranch ?? "")]) { $1 }
    }

    /// `root`'s workflow.md.
    public static func workflowPath(root: String) -> String {
        (BoardStore(root: root).folder as NSString).appendingPathComponent("workflow.md")
    }

    /// What the vault holds for `root` now, as a card shows it. `look`: the vault looks at the config first, as a card
    /// that showed nothing but a look's own key would (`checkConfig(root:shown: LeadVaultV2.configLook)`), so a fresh
    /// vault's first look holds what it has nothing recorded for and what changed since the last look is held, while
    /// nothing is sealed and a held first look stays held (the security follow-ups' item 20: only your accept ends it):
    /// an app's look with no card (`checkConfig(root:)`) would seal everything held that didn't move since, as an older
    /// app's Accept does (the E6 review), and the app's `ConfigHolds.look` only reads the record. A look the vault refuses is only
    /// said. `snapshot`: the project's last accepts (E8's `AcceptedSnapshot`), which say of each held thing and guard rail
    /// whether it's the same, changed or new since. Fails when the record can't be read.
    public static func held(root: String, vault: LeadVault, home: String, look: Bool = true,
                            snapshot: AcceptedSnapshot.Project? = nil) -> Result<Shown, Error> {
        if look { _ = try? vault.checkConfig(root: root, shown: LeadVaultV2.configLook) }
        let record: [String: String]?
        do { record = try vault.guardedRecord(root: root) } catch { return .failure(error) }
        let names = ConfigSeal.held(in: record)
        let outside = Set(ConfigSeal.heldOutside(in: record))
        let changes = ConfigSeal.heldChanges(in: record)
        let times = changedAt(names, root: root, home: home).merging(ConfigSeal.heldTimes(in: record)) { $1 }
        let sizes = sizes(names, root: root, home: home)
        let details = ConfigSeal.heldDetails(in: record)
        // By the record's key, as the accept seals them (`checkConfig(root:shown:)`); the card shows each by its name.
        let hashes = ConfigSeal.heldHashes(in: record)
        let byName = Dictionary(hashes.map { (ConfigSeal.name(ofKey: $0.key), (key: $0.key, hash: $0.value)) }) { first, _ in first }
        // "The same" only from a snapshot this host's vault sealed at the last accept (the security follow-ups' item 18;
        // the close-out review: the record now is that accept's).
        let vouched = AcceptedSnapshot.vouches(snapshot, root: root, vault: vault, record: record)
        let items = names.map { name in
            Item(name: name, changedAt: times[name], size: sizes[name], hash: String((byName[name]?.hash ?? "").prefix(12)), change: changes[name],
                 outside: outside.contains(name), files: details[name]?.files ?? [],
                 sinceAccept: byName[name].flatMap { AcceptedSnapshot.since(key: $0.key, hash: $0.hash, in: snapshot, vouched: vouched) })
        }
        let workflow = LeadWorkflow.load(from: workflowPath(root: root))
        let guarded = guardedValues(workflow).map {
            Rail(key: $0.key, value: $0.value, sinceAccept: AcceptedSnapshot.since(rail: $0.key, value: $0.value, in: snapshot, vouched: vouched))
        }
        return .success(Shown(items: items, hashes: hashes, floor: LeadReviewFloor.starting(from: workflow), rails: recordedHashes(workflow),
                              baseBranch: workflow.baseBranch, guarded: guarded,
                              lastAccept: snapshot?.configAt.map { Date(timeIntervalSince1970: $0) }))
    }

    /// workflow.md's guard rails that are set (`LeadVault.guardedValue` isn't empty), in `LeadVault.guardedKeys`' order.
    public static func guardedValues(_ workflow: LeadWorkflow) -> [(key: String, value: String)] {
        LeadVault.guardedKeys.compactMap { key in
            let value = LeadVault.guardedValue(key, in: workflow)
            return value.isEmpty ? nil : (key, value)
        }
    }

    /// What an accept did.
    public enum Accepted: Equatable, Sendable {
        /// Sealed what the card showed (the names the vault sealed anew, else the card's), then recorded the floor (the
        /// floor in force after) and the rails.
        case sealed(names: [String], floor: LeadReviewFloor?)
        /// The config moved past what the card showed: nothing was sealed, it's held again.
        case changedSince(held: [String])
    }

    /// The user's accept of the card that showed `shown`, in EN-D7's order: the seal of exactly those hashes first
    /// (`checkConfig(root:shown:)`, which ends the root's first-look hold), then the rails and the floor `workflow.md`
    /// proposed as the card showed them (`setReviewFloor(onlyIfUnset: true)`, which the vault refuses while the first
    /// look still holds). Then the snapshot (`snapshotRoot`, E8's `AcceptedSnapshot`) keeps what the vault records now of
    /// the watched things, the rails' values and the floor the card showed, with the vault's seal of them: a diff aid for
    /// the next `config held`, not written when nothing was sealed. Fails when the vault can't be asked.
    public static func accept(_ shown: Shown, root: String, vault: LeadVault, snapshotRoot: URL? = nil) -> Result<Accepted, Error> {
        do {
            let check = try vault.checkConfig(root: root, shown: shown.hashes)
            guard check.held.isEmpty else { return .success(.changedSince(held: check.held)) }
            if !shown.rails.isEmpty { try vault.setGuardedSettings(shown.rails, root: root) }
            var floor: LeadReviewFloor?
            if let proposed = shown.floor { floor = try vault.setReviewFloor(proposed, root: root, onlyIfUnset: true) }
            if let snapshotRoot {
                let recorded = ((try? vault.guardedRecord(root: root)) ?? nil)?.filter { ConfigSeal.isWatchedKey($0.key) } ?? shown.hashes
                try? AcceptedSnapshot.update(root: snapshotRoot, project: root) { project in
                    project.configAt = Date().timeIntervalSince1970
                    project.hashes = project.hashes.merging(recorded) { $1 }
                    project.guarded = Dictionary(shown.guarded.map { ($0.key, $0.value) }) { first, _ in first }
                    project.floor = floor ?? shown.floor
                    // Sealed by this vault: "the same" is said from it only while the seal checks.
                    project.seal = try? vault.seal(AcceptedSnapshot.sealMessage(project, root: root))
                }
            }
            return .success(.sealed(names: check.resealed.isEmpty ? shown.items.map(\.name) : check.resealed, floor: floor))
        } catch {
            return .failure(error)
        }
    }

    /// The difference of each changed file of the held thing `name` in `shown`, as lines (`ConfigSeal.difference`:
    /// the text the seal kept against the text now), each untrusted line made inert. Reads the disk.
    public static func difference(_ shown: Shown, name: String, home: String) -> [String]? {
        guard let item = shown.items.first(where: { $0.name == name }) else { return nil }
        guard !item.files.isEmpty else { return ["(no file of \(ConfigSeal.inert(name, limit: 200)) to compare)"] }
        var lines: [String] = []
        for file in item.files {
            lines.append("── " + ConfigSeal.fileLabel(file, in: name))
            switch ConfigSeal.difference(of: file, in: name, home: home) {
            case .lines(let changed, let more, let masked):
                for line in changed {
                    let marker: String
                    switch line.kind {
                    case .added: marker = "+ "
                    case .removed: marker = "- "
                    case .gap: marker = "… "
                    case .same: marker = "  "
                    }
                    lines.append(marker + ConfigSeal.inert(line.text, limit: .max))
                }
                if more > 0 { lines.append("  … \(more) more changed lines") }
                if masked { lines.append("  (a value masked as secret changed too)") }
            case .unavailable(let why), .sameText(let why):
                lines.append("  " + ConfigSeal.inert(why, limit: .max))
            }
        }
        return lines
    }

    /// When each of `names` was last changed (the app's `ConfigHolds.changedAt`, copied): nothing for a missing file, a
    /// folder (its own time moves with whatever is written in it), a plugin or a settings file's scripts. The file's
    /// change time (ctime, E8 and S7), which `touch` can't set back, never its modification time, which anyone who
    /// writes it can. Reads the disk.
    public static func changedAt(_ names: [String], root: String, home: String) -> [String: Date] {
        guard !names.isEmpty else { return [:] }
        var times: [String: Date] = [:]
        for watched in ConfigSeal.watched(home: home, root: root) where names.contains(watched.name) && (watched.kind == .file || watched.kind == .mcpServers) {
            var info = stat()
            guard stat(watched.path, &info) == 0 else { continue }
            let changed = Platform.Files.changed(info)
            times[watched.name] = Date(timeIntervalSince1970: Double(changed.tv_sec) + Double(changed.tv_nsec) / 1_000_000_000)
        }
        return times
    }

    /// Each held file's size now, by name (files only, as `changedAt`). Reads the disk.
    static func sizes(_ names: [String], root: String, home: String) -> [String: Int] {
        guard !names.isEmpty else { return [:] }
        var sizes: [String: Int] = [:]
        for watched in ConfigSeal.watched(home: home, root: root) where names.contains(watched.name) && (watched.kind == .file || watched.kind == .mcpServers) {
            if let size = (try? FileManager.default.attributesOfItem(atPath: watched.path))?[.size] as? NSNumber { sizes[watched.name] = size.intValue }
        }
        return sizes
    }
}
