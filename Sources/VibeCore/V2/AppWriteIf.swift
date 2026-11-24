import Foundation

extension LeadVault {
    /// `appWrite` whose seal depends on what the write left (the node's Codex trust, `NodeCodexTrust`): after `write`,
    /// the watched things in `paths` are fingerprinted, `seal` is asked (it reads what it decides by itself), and they
    /// are fingerprinted again; only when `seal` says so and nothing changed between the two are the ones that changed
    /// since before the write asked to be sealed as the app's (as `appWrite` does). Otherwise nothing is: a change
    /// stays held, for `config held`. On a throw nothing is sealed. Whether it was, beside `write`'s result. The caller
    /// calls `sealAppWrites` after, as with `appWrite`.
    public func appWrite<T>(_ paths: [String], home: String = VibePaths.home, sealIf seal: (T) -> Bool,
                            _ write: () throws -> T) rethrows -> (result: T, sealed: Bool) {
        let items = ConfigSeal.homeWatched(home: home).filter { item in
            !item.path.isEmpty && paths.contains { $0 == item.path || $0.hasPrefix(item.path + "/") }
        }
        let before = items.map(ConfigSeal.fingerprint)
        let result = try write()
        let after = items.map(ConfigSeal.fingerprint)
        guard seal(result), items.map(ConfigSeal.fingerprint) == after else { return (result, false) }
        var lines: [String] = []
        for (item, (was, now)) in zip(items, zip(before, after)) {
            guard let was, let now, now != was else { continue }
            lines.append("\(item.name)\t\(was)\t\(now)")
        }
        if !lines.isEmpty { ConfigSeal.pending(for: folder).add(lines) }
        return (result, true)
    }
}
