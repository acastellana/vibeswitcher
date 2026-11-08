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

    var vault: LeadVault
    private let background: (@escaping () -> Void) -> Void
    private let main: (@escaping () -> Void) -> Void
    /// Something new is held (by root): the files.
    var onHeld: (String, [String]) -> Void = { _, _ in }
    /// Your click sealed these.
    var onAccepted: (String, [String]) -> Void = { _, _ in }
    private var looking: Set<String> = []

    init(vault: LeadVault = .standard,
         background: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) },
         main: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.vault = vault
        self.background = background
        self.main = main
    }

    /// The leads' roots, at each refresh: one vault call per root, never two at once.
    func look(_ roots: Set<String>) {
        if !Set(held.keys).isSubset(of: roots) { held = held.filter { roots.contains($0.key) } }
        for root in roots where !looking.contains(root) && !accepting.contains(root) {
            looking.insert(root)
            let vault = self.vault
            background {
                // The app's own writes of the agents' config the host couldn't seal when they were made.
                vault.sealAppWrites()
                let record = Result { try vault.guardedRecord(root: root) }
                let names = record.map { ConfigSeal.held(in: $0) }
                let guarded = try? record.get()
                let outside = guarded.map { Set(ConfigSeal.heldOutside(in: $0)) }
                let changes = guarded.map { ConfigSeal.heldChanges(in: $0) }
                let times = Self.changedAt((try? names.get()) ?? [], root: root)
                    .merging(guarded.map { ConfigSeal.heldTimes(in: $0) } ?? [:]) { $1 }
                self.main {
                    // Not known (the host didn't answer): what was shown stays.
                    if let outside, self.outside[root] ?? [] != outside { self.outside[root] = outside.isEmpty ? nil : outside }
                    if let changes, self.changes[root] ?? [:] != changes { self.changes[root] = changes.isEmpty ? nil : changes }
                    if guarded != nil, self.changedAt[root] ?? [:] != times { self.changedAt[root] = times.isEmpty ? nil : times }
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
        let vault = self.vault
        background {
            let sealed = Result { try vault.checkConfig(root: root) }
            self.main {
                self.accepting.remove(root)
                guard case .success(let check) = sealed, check.held.isEmpty else { return }
                let shown = self.held[root] ?? []
                self.held[root] = nil
                self.onAccepted(root, check.resealed.isEmpty ? shown : check.resealed)
            }
        }
    }

    /// When each of `names` was last changed, for the card ("14:02"): nothing for a missing file, or a folder (its own
    /// time moves with whatever is written in it: what's held says when its newest changed file was,
    /// `ConfigSeal.heldTimes`). Reads the disk: off the main thread.
    static func changedAt(_ names: [String], root: String, home: String = VibePaths.home) -> [String: Date] {
        guard !names.isEmpty else { return [:] }
        var times: [String: Date] = [:]
        for watched in ConfigSeal.watched(home: home, root: root) where names.contains(watched.name) && watched.kind != .folder {
            times[watched.name] = (try? FileManager.default.attributesOfItem(atPath: watched.path))?[.modificationDate] as? Date
        }
        return times
    }
}
