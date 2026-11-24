import Foundation

extension LeadVault {
    /// `appWrite` whose seal depends on what the write found (the node's Codex trust, `NodeCodexTrust`): `write`'s
    /// result given to `seal`, and only when it says so are the watched things in `paths` that changed asked to be
    /// sealed as the app's (as `appWrite` does; a change it doesn't seal stays held, for `config held`). On a throw
    /// nothing is sealed. The caller calls `sealAppWrites` after, as with `appWrite`.
    public func appWrite<T>(_ paths: [String], home: String = VibePaths.home, sealIf seal: (T) -> Bool, _ write: () throws -> T) rethrows -> T {
        let items = ConfigSeal.homeWatched(home: home).filter { item in
            !item.path.isEmpty && paths.contains { $0 == item.path || $0.hasPrefix(item.path + "/") }
        }
        let before = items.map(ConfigSeal.fingerprint)
        let result = try write()
        guard seal(result) else { return result }
        var lines: [String] = []
        for (item, was) in zip(items, before) {
            guard let was, let now = ConfigSeal.fingerprint(item), now != was else { continue }
            lines.append("\(item.name)\t\(was)\t\(now)")
        }
        if !lines.isEmpty { ConfigSeal.pending(for: folder).add(lines) }
        return result
    }
}
