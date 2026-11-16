import Foundation
import VibeCore

/// A change under a watched thing that nobody accepted: one the seal holds, or one since the vault recorded it (a change
/// no look has held yet: S7's `.listing` sees a rewrite by its `ctime`). `hooks.install` (the builds folder, ST-D17) and
/// `build.switch` (the builds folder and the unit's folder, the lead's call of 2026-11-16 on the S8c review's finding 5)
/// are refused while one is there, so the user looks at it (`config held`) and accepts it before they act.
///
/// Before the vault has recorded a thing at all (a fresh vault before its first accept) there is nothing to compare: the
/// request goes on, and the first accept shows the thing as it is. A name the seal doesn't watch in this home (the Mac's
/// list has none of these) is no refusal. A detector at the point the request asks it: a change made after it is held
/// at the next look, not refused here.
///
/// Blocking: the vault's calls go to the host, so never on the link's queue.
public enum HeldChange {
    /// Why a request that depends on the watched things `names` (seal names, `~/…`) of `home` is refused, or nil; `accept`
    /// says what the user does first.
    public static func refusal(_ names: [String], home: String, vault: LeadVault, accept: String) -> StartRefusal? {
        let watched = ConfigSeal.homeWatched(home: home)
        let items = names.compactMap { name in watched.first { $0.name == name } }
        guard !items.isEmpty else { return nil }
        let record: [String: String]?
        do { record = try vault.guardedRecord(root: home) } catch {
            let asked = items.map(\.name).joined(separator: " and ")
            return StartRefusal("the vault can't be asked what it holds of \(asked): \(ConfigSeal.inert("\(error)", limit: .max))", exitCode: 1)
        }
        let held = Set(ConfigSeal.held(in: record))
        for item in items where held.contains(item.name) {
            return StartRefusal("\(item.name) holds a change not accepted: \(accept)")
        }
        for item in items {
            guard let recorded = record?[ConfigSeal.keyPrefix + item.name] else { continue }
            guard ConfigSeal.fingerprint(item) == recorded else {
                return StartRefusal("\(item.name) changed since the vault recorded it: \(accept)")
            }
        }
        return nil
    }
}
