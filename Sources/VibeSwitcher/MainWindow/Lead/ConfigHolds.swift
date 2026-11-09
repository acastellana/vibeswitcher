import Foundation
import VibeCore

/// The agents' config each team's vault holds (`ConfigSeal`): changed while its workers or verifiers ran, which holds
/// new workers, verifiers and merges until you accept it here. Read from the session host's vault at each refresh, it
/// is a card in the lead's chat naming the files, with Accept. Your click is the acceptance, and only here: the vault
/// seals a held change only for the app (`LeadVault.checkConfig`). The lead hears of it (`onAccepted`).
final class ConfigHolds: ObservableObject {
    /// What's held, by repository root: names only (never contents).
    @Published private(set) var held: [String: [String]] = [:]
    /// Of those, what changed outside a team session (code that runs: only your Accept seals it, whoever changed it).
    @Published private(set) var outside: [String: Set<String>] = [:]
    /// The roots whose acceptance runs.
    @Published private(set) var accepting: Set<String> = []
    /// What changed in each held thing (its keys, "hooks.SessionStart added"; never a value), by root and name.
    @Published private(set) var changes: [String: [String: String]] = [:]
    /// When each held thing was last changed, by root and name (a folder: its newest changed file): read in the
    /// background with what's held, so the card never reads a file on the main thread.
    @Published private(set) var changedAt: [String: [String: Date]] = [:]
    /// Each held thing's files and sessions, by root and name (`ConfigSeal.HeldDetail`).
    @Published private(set) var details: [String: [String: ConfigSeal.HeldDetail]] = [:]
    /// What most likely made each held change, by root and name: read at each look, since the sync's manifest can land
    /// after the files.
    @Published private(set) var sources: [String: [String: ConfigSeal.Source]] = [:]
    /// Said after an Accept that found the config moved past what the card showed.
    @Published private(set) var notices: [String: String] = [:]
    /// The one file whose difference is open, by root ("<name>\n<path>").
    @Published private(set) var openDifference: [String: String] = [:]
    /// What's been read of the open files' differences, by `differenceKey`.
    @Published private(set) var differences: [String: ConfigSeal.Difference] = [:]
    /// The held folders with their whole list open ("<root>\n<name>").
    @Published private(set) var showingAll: Set<String> = []

    /// The hashes the card was last drawn from, by root: what Accept seals.
    private var shownHashes: [String: [String: String]] = [:]

    var vault: LeadVault
    /// The home the card reads: the sync's manifest and the differences.
    var home: String
    private let background: (@escaping () -> Void) -> Void
    private let main: (@escaping () -> Void) -> Void
    /// Something new is held (by root): the files.
    var onHeld: (String, [String]) -> Void = { _, _ in }
    /// Your click sealed these.
    var onAccepted: (String, [String]) -> Void = { _, _ in }
    private var looking: Set<String> = []

    init(vault: LeadVault = .standard, home: String = VibePaths.home,
         background: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) },
         main: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.vault = vault
        self.home = home
        self.background = background
        self.main = main
    }

    /// The leads' roots, at each refresh: one vault call per root, never two at once.
    func look(_ roots: Set<String>) {
        if !Set(held.keys).isSubset(of: roots) { held = held.filter { roots.contains($0.key) } }
        for root in roots where !looking.contains(root) && !accepting.contains(root) {
            looking.insert(root)
            let vault = self.vault, home = self.home
            background {
                // The app's own writes of the agents' config the host couldn't seal when they were made.
                vault.retrySealingAppWrites()
                let record = Result { try vault.guardedRecord(root: root) }
                let names = record.map { ConfigSeal.held(in: $0) }
                let guarded = try? record.get()
                let outside = guarded.map { Set(ConfigSeal.heldOutside(in: $0)) }
                let changes = guarded.map { ConfigSeal.heldChanges(in: $0) }
                let times = Self.changedAt((try? names.get()) ?? [], root: root, home: home)
                    .merging(guarded.map { ConfigSeal.heldTimes(in: $0) } ?? [:]) { $1 }
                let details = guarded.map { ConfigSeal.heldDetails(in: $0) }
                let hashes = guarded.map { ConfigSeal.heldHashes(in: $0) }
                var sources: [String: ConfigSeal.Source] = [:]
                for name in (try? names.get()) ?? [] { sources[name] = ConfigSeal.likelySource(name: name, detail: details?[name], home: home) }
                self.main {
                    // Not known (the host didn't answer): what was shown stays.
                    if let outside, self.outside[root] ?? [] != outside { self.outside[root] = outside.isEmpty ? nil : outside }
                    if let changes, self.changes[root] ?? [:] != changes { self.changes[root] = changes.isEmpty ? nil : changes }
                    if guarded != nil, self.changedAt[root] ?? [:] != times { self.changedAt[root] = times.isEmpty ? nil : times }
                    if let details, self.details[root] ?? [:] != details {
                        self.details[root] = details.isEmpty ? nil : details
                        // Differences are of the files as the old detail had them.
                        self.differences = self.differences.filter { !$0.key.hasPrefix(root + "\n") }
                    }
                    if guarded != nil, self.sources[root] ?? [:] != sources { self.sources[root] = sources.isEmpty ? nil : sources }
                    if let hashes { self.shownHashes[root] = hashes }
                    self.looked(root, names)
                }
            }
        }
    }

    private func looked(_ root: String, _ result: Result<[String], Error>) {
        looking.remove(root)
        // Not known (the host didn't answer): what was shown stays.
        guard case .success(let names) = result, !accepting.contains(root), (held[root] ?? []) != names else { return }
        held[root] = names.isEmpty ? nil : names
        if !names.isEmpty { onHeld(root, names) }
    }

    /// You clicked Accept on the card showing `names`: the vault seals the agents' config as it is now.
    func accept(_ root: String) {
        guard held[root] != nil, !accepting.contains(root) else { return }
        accepting.insert(root)
        let vault = self.vault, shown = shownHashes[root] ?? [:]
        background {
            let sealed = Result { try vault.checkConfig(root: root, shown: shown) }
            self.main {
                self.accepting.remove(root)
                guard case .success(let check) = sealed else { return }
                guard check.held.isEmpty else {
                    // Moved since the card was drawn: the vault held it anew, so the card redraws to say what's there.
                    self.notices[root] = "This changed again after the card was drawn: nothing was accepted. Look at it again before you accept."
                    self.look([root])
                    return
                }
                let names = self.held[root] ?? []
                self.held[root] = nil
                self.notices[root] = nil
                self.onAccepted(root, check.resealed.isEmpty ? names : check.resealed)
            }
        }
    }

    /// Opens the difference of `file` of the held thing `name`, or closes it if it's the open one. Reads the disk: in
    /// the background, its answer kept for as long as the card is drawn from the same detail.
    func toggleDifference(root: String, name: String, file: ConfigSeal.HeldFile) {
        let open = name + "\n" + file.path
        guard openDifference[root] != open else {
            openDifference[root] = nil
            return
        }
        openDifference[root] = open
        let key = Self.differenceKey(root: root, name: name, file: file)
        guard differences[key] == nil else { return }
        let home = self.home
        background {
            let difference = ConfigSeal.difference(of: file, in: name, home: home)
            self.main { self.differences[key] = difference }
        }
    }

    /// Opens or closes a held folder's whole list.
    func toggleShowingAll(root: String, name: String) {
        let key = root + "\n" + name
        if showingAll.remove(key) == nil { showingAll.insert(key) }
    }

    static func differenceKey(root: String, name: String, file: ConfigSeal.HeldFile) -> String {
        [root, name, file.path, file.after ?? ""].joined(separator: "\n")
    }

    /// When each of `names` was last changed, for the card ("14:02"): nothing for a missing file, or a folder (its own
    /// time moves with whatever is written in it: what's held says when its newest changed file was,
    /// `ConfigSeal.heldTimes`), or a plugin or a settings file's scripts (its path's time isn't the time of the code
    /// that changed). Reads the disk: off the main thread.
    static func changedAt(_ names: [String], root: String, home: String = VibePaths.home) -> [String: Date] {
        guard !names.isEmpty else { return [:] }
        var times: [String: Date] = [:]
        for watched in ConfigSeal.watched(home: home, root: root) where names.contains(watched.name) && (watched.kind == .file || watched.kind == .mcpServers) {
            times[watched.name] = (try? FileManager.default.attributesOfItem(atPath: watched.path))?[.modificationDate] as? Date
        }
        return times
    }
}
