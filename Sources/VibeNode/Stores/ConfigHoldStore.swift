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
    public struct Item: Codable, Equatable, Sendable {
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
        /// What it is in plain words (`HeldWhat`): its kind, a short phrase, and where known what it went from and to.
        public var about: HeldWhat.Described?
        /// A git config's changed keys as data (`ConfigSeal.HeldDetail.keys`), which `HeldWhat` classifies by.
        public var keys: [ConfigSeal.KeyChange]?

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
    public struct Rail: Codable, Equatable, Sendable {
        public var key: String
        public var value: String
        public var sinceAccept: String?
        /// Against the last accept (2026-11-25, the plain card): `changed` (its value then is `old`, nil when it wasn't
        /// set), `same` (only from a snapshot this host's vault sealed), or `unknown` (no accept known, or a snapshot the
        /// vault didn't seal: after a restart).
        public var changed: Changed?
        public var old: String?
        /// Whether the accept records this value: the vault holds another, or none for it (`wouldRecord`'s rails); nil
        /// when it holds no rails at all for the project (`Shown.recordsAll`).
        public var records: Bool?
        /// Its value is what workflow.md gives when it doesn't set it (a first accept names the others).
        public var atDefault: Bool?

        public enum Changed: String, Codable, Sendable { case changed, same, unknown }

        public init(key: String, value: String, sinceAccept: String? = nil) {
            self.key = key
            self.value = value
            self.sinceAccept = sinceAccept
        }
    }

    /// What a held-config card showed: the items, the hashes the accept seals, and what `workflow.md` proposes (the
    /// floor, and the guard rails' hashes with its `base_branch`'s, `recordedHashes`), recorded at the accept.
    public struct Shown: Codable, Equatable, Sendable {
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
        /// The held things this card leaves to the home folder's card, which shows them with the same hashes
        /// (`SharedHome`): not in `items` nor `hashes`. Set by the engine as it draws the card; nil on the home's own
        /// card and when none is shared.
        public var sharedHome: SharedHome?
        /// The card's plain line of what changed (`HeldWhat.summary`), and who it holds: a project's name, or nil for the
        /// home folder's card, which holds every project.
        public var summary: String?
        public var holds: String?
        public var holdsEvery: Bool?
        /// No rules are recorded for the project yet (a first accept, or a fresh vault): the accept records them all.
        /// The default screen names every one not at its default (`Rail.atDefault`) and counts the rest.
        public var recordsAll: Bool?
        /// Whether a page may accept this card, as `pageRefusal` judges it when the card is drawn (nil: it couldn't be
        /// told, so no).
        public var pageMayAccept: Bool?
        /// Nothing held, and no guard rail recorded for the folder: the vault's first look is owed (a host restart
        /// since): accepting confirms the project's rules once. Such a card is no hold (not blocking).
        public var firstLook: Bool?
        /// Its accept would record the project's rules (`wouldRecord`): `vibeswitcher approve` sets it aside for its own
        /// `config held FOLDER`.
        public var recordsRules: Bool?

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

    /// What a project's held-config card leaves to the home folder's (the Mac-wide seal's things, held in every root's
    /// record at a fresh vault's first look): the names, each with the same hash on `card` (the home's, `folder`). The
    /// project's card neither lists nor seals them (a card's accept seals exactly what it shows, all of it on its short
    /// lines): it says them in one line, and the home's card's accept seals them for every project. On 2026-11-23 after a
    /// restart the user read four near-identical 100-line cards, about 85 lines of each the home's.
    public struct SharedHome: Codable, Equatable, Sendable {
        public var names: [String]
        public var card: String
        public var folder: String

        public init(names: [String], card: String, folder: String) {
            self.names = names
            self.card = card
            self.folder = folder
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
    /// that showed nothing (`checkConfig(root:shown: [:])`), so a fresh vault's first look holds what it has nothing
    /// recorded for and what changed since the last look is held, while nothing is sealed and a held first look stays
    /// held (the security follow-ups' item 20: a `shown` with nothing in it never ends it, only `accept`'s marked hashes
    /// do): an app's look with no card (`checkConfig(root:)`) would seal everything held that didn't move since, as an
    /// older app's Accept does (the E6 review), and the app's `ConfigHolds.look` only reads the record. A look the vault
    /// refuses is only
    /// said. First, look or not, the server's own config writes the host didn't take when they were made are asked
    /// again (`retrySealingAppWrites`): only the hashes those writes left are sealed so. `snapshot`: the project's last accepts (E8's `AcceptedSnapshot`), which say of each held thing and guard rail
    /// whether it's the same, changed or new since. Fails when the record can't be read.
    /// What accepting `shown` would record besides its seals, exactly as `accept` records it (each guard rail of the card's
    /// `rails` whose hash isn't the one the vault recorded, `base_branch` among them, or that it never recorded; and
    /// "the review floor" when the card proposes one and the vault has none): empty when it records nothing of the kind.
    /// `vibeswitcher approve` keeps such a card out of its batches, and refuses its accept inside one (`inBatch`).
    public static func wouldRecord(_ shown: Shown, root: String, vault: LeadVault) throws -> [String] {
        let recorded = try vault.guardedSettings(root: root) ?? [:]
        var said = shown.rails.keys.sorted().filter { recorded[$0] != shown.rails[$0] }
        if shown.floor != nil, try vault.reviewFloor(root: root) == nil { said.append("the review rules") }
        return said
    }

    /// What keeps an acting page from accepting `shown` (a page never seals a review floor or a guard rail it didn't see
    /// recorded: an agent's edit of workflow.md, held, then clicked through, would be the floors' `set` by another path),
    /// from the card alone: no accept recorded yet (a first accept), or a guard rail not known to be the same as at the
    /// last accept (changed, new, or its snapshot not sealed by this host's vault: the card's "?"). Empty: the card may
    /// be accepted from a page, as far as the card says (`pageRefusal` asks the vault too).
    public static func pageNotSame(_ shown: Shown) -> [String] {
        guard shown.lastAccept != nil else { return ["no accept recorded yet"] }
        return shown.guarded.filter { !($0.sinceAccept?.hasPrefix("the same as at your last accept") ?? false) }.map(\.key)
    }

    /// What an acting page is told when it may not accept a card (`pageNotSame`, `pageRefusal`'s names).
    /// At most three named, then how many more (2026-11-25: the real node's listed every rule).
    public static func pageRefusalWords(_ changed: [String]) -> String {
        let named = changed.prefix(3).map { ConfigSeal.inert($0, limit: 80) }.joined(separator: ", ")
            + (changed.count > 3 ? " and \(changed.count - 3) more" : "")
        return "rules changed (\(named)): accept this one in a terminal: vibeswitcher config held"
    }

    /// The same, the vault asked (in the accept's own turn of `work`): `pageNotSame`, and each guard rail whose hash
    /// isn't the one recorded or never was (`wouldRecord`), a review floor proposed while none is recorded, one proposed
    /// that isn't the recorded one, or no rails recorded at all.
    public static func pageRefusal(_ shown: Shown, root: String, vault: LeadVault) throws -> [String] {
        var said = pageNotSame(shown)
        guard try vault.guardedSettings(root: root) != nil else { return said + ["no rules recorded yet"] }
        said += try wouldRecord(shown, root: root, vault: vault)
        if let proposed = shown.floor, let recorded = try vault.reviewFloor(root: root), proposed != recorded { said.append("the review rules") }
        var seen = Set<String>()
        return said.filter { seen.insert($0).inserted }
    }

    public static func held(root: String, vault: LeadVault, home: String, look: Bool = true,
                            snapshot: AcceptedSnapshot.Project? = nil) -> Result<Shown, Error> {
        // The server's own writes of the agents' config (`hooks install`) the host couldn't seal when they were made,
        // asked again first, as the app's `ConfigHolds.look` does (the S6 review).
        vault.retrySealingAppWrites()
        if look { _ = try? vault.checkConfig(root: root, shown: [:]) }
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
        let vouched = AcceptedSnapshot.vouch(snapshot, root: root, vault: vault, record: record)
        let facts = names.isEmpty ? HeldWhat.Facts() : HeldWhat.facts(home: home)
        let items = names.map { name in
            var item = Item(name: name, changedAt: times[name], size: sizes[name], hash: String((byName[name]?.hash ?? "").prefix(12)), change: changes[name],
                            outside: outside.contains(name), files: details[name]?.files ?? [],
                            sinceAccept: byName[name].flatMap { AcceptedSnapshot.since(key: $0.key, hash: $0.hash, in: snapshot, vouched: vouched.item($0.key)) })
            item.keys = details[name]?.keys
            item.about = HeldWhat.describe(item, facts: facts)
            return item
        }
        let workflow = LeadWorkflow.load(from: workflowPath(root: root))
        // What the vault recorded of the rails: none yet is a first accept; a vault that couldn't be asked draws no card
        // (what it would record can't be told).
        let recorded: [String: String]?
        do { recorded = try vault.guardedSettings(root: root) } catch { return .failure(error) }
        let proposed = recordedHashes(workflow)
        let defaults = LeadWorkflow()
        let guarded = guardedValues(workflow).map { rail -> Rail in
            var shown = Rail(key: rail.key, value: rail.value, sinceAccept: AcceptedSnapshot.since(rail: rail.key, value: rail.value, in: snapshot, vouched: vouched.rail(rail.key)))
            (shown.changed, shown.old) = changed(rail: rail.key, value: rail.value, in: snapshot, vouched: vouched.rail(rail.key))
            shown.records = recorded.map { $0[rail.key] != proposed[rail.key] }
            shown.atDefault = rail.value == LeadVault.guardedValue(rail.key, in: defaults)
            return shown
        }
        var shown = Shown(items: items, hashes: hashes, floor: LeadReviewFloor.starting(from: workflow), rails: proposed,
                          baseBranch: workflow.baseBranch, guarded: guarded,
                          lastAccept: snapshot?.configAt.map { Date(timeIntervalSince1970: $0) })
        shown.summary = HeldWhat.summary(items: items)
        // No rule recorded yet: a first accept records them all (each rail's `records` then nil).
        let none = recorded.map { recorded in !LeadVault.guardedKeys.contains { recorded[$0] != nil } } ?? true
        shown.recordsAll = none && !guarded.isEmpty
        if none { for index in shown.guarded.indices { shown.guarded[index].records = nil } }
        shown.pageMayAccept = (try? pageRefusal(shown, root: root, vault: vault)).map(\.isEmpty) ?? false
        let every = (root as NSString).standardizingPath == (home as NSString).standardizingPath
        shown.holdsEvery = every
        shown.holds = every ? nil : LeadMail.project(of: root)
        return .success(shown)
    }

    /// A guard rail against the last accept: changed (with its value then), the same (only `vouched`), or unknown.
    static func changed(rail key: String, value: String, in snapshot: AcceptedSnapshot.Project?, vouched: Bool) -> (Rail.Changed, String?) {
        guard let snapshot, snapshot.configAt != nil else { return (.unknown, nil) }
        switch snapshot.guarded[key] {
        case value?: return (vouched ? .same : .unknown, nil)
        case .some(let before): return (.changed, before)
        case nil: return (.changed, nil)
        }
    }

    /// workflow.md's guard rails that are set (`LeadVault.guardedValue` isn't empty), in `LeadVault.guardedKeys`' order.
    public static func guardedValues(_ workflow: LeadWorkflow) -> [(key: String, value: String)] {
        LeadVault.guardedKeys.compactMap { key in
            let value = LeadVault.guardedValue(key, in: workflow)
            return value.isEmpty ? nil : (key, value)
        }
    }

    /// The key an accept adds to the hashes its card showed (`accept`): a vault mark (`ConfigSeal.keyPrefix` then `#`),
    /// so no watched thing's, which the vault's judge never seals or compares; it makes an accept's `shown` never empty.
    static let acceptMark = ConfigSeal.keyPrefix + "#accept"

    /// What an accept did.
    public enum Accepted: Equatable, Sendable {
        /// Sealed what the card showed (the names the vault sealed anew, else the card's), then recorded the floor (the
        /// floor in force after) and the rails. `homeWaits`: what the card left to the home's card and is still held
        /// (`SharedHome`): this folder's first look goes on, and neither rails nor floor are recorded until this folder's
        /// card is accepted again after the home's.
        case sealed(names: [String], floor: LeadReviewFloor?, homeWaits: [String] = [])
        /// The config moved past what the card showed: nothing was sealed, it's held again.
        case changedSince(held: [String])
    }

    /// The user's accept of the card that showed `shown`, in EN-D7's order: the seal of exactly those hashes first
    /// (`checkConfig(root:shown:)`, which ends the root's first-look hold), then the rails and the floor `workflow.md`
    /// proposed as the card showed them (`setReviewFloor(onlyIfUnset: true)`, which the vault refuses while the first
    /// look still holds). Then the snapshot (`snapshotRoot`, E8's `AcceptedSnapshot`) keeps what the vault records now of
    /// the watched things, the rails' values and the floor the card showed, with the vault's seal of them: a diff aid for
    /// the next `config held`, not written when nothing was sealed. The hashes go with `acceptMark`, so the vault tells
    /// this accept from `held`'s look even for a card that showed nothing (the look's `shown` is empty, and never ends
    /// the first-look hold). Fails when the vault can't be asked.
    public static func accept(_ shown: Shown, root: String, vault: LeadVault, snapshotRoot: URL? = nil) -> Result<Accepted, Error> {
        do {
            let check = try vault.checkConfig(root: root, shown: shown.hashes.merging([acceptMark: "1"]) { first, _ in first })
            // What the card left to the home's (`sharedHome`) may still be held: never "changed since", only waiting.
            let left = Set(shown.sharedHome?.names ?? [])
            guard check.held.allSatisfy(left.contains) else { return .success(.changedSince(held: check.held)) }
            let homeWaits = check.held
            var floor: LeadReviewFloor?
            if homeWaits.isEmpty {
                if !shown.rails.isEmpty { try vault.setGuardedSettings(shown.rails, root: root) }
                if let proposed = shown.floor { floor = try vault.setReviewFloor(proposed, root: root, onlyIfUnset: true) }
            }
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
            return .success(.sealed(names: check.resealed.isEmpty ? shown.items.map(\.name) : check.resealed, floor: floor, homeWaits: homeWaits))
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
