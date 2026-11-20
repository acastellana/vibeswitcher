import Foundation
import VibeCore

/// What the user accepted of the presets file, and what changed since (the security review of the page-actions lane,
/// 2026-11-20): the bytes the user's explicit `config accept` sealed are kept beside the node's own record, so the next
/// accept card says what changed in presets (names, kinds, commands, variables by name; `config held --diff` with
/// their values, a secret-looking one masked), not only "changed"; and the user's edits (`presets.edit`) start only
/// from a file as the user accepted it, so nothing a worker wrote is carried into an edit made in the user's voice.
extension SessionPresets {
    /// The copy of the presets file as the user last accepted it. A file of the uid's, as `presets.json` is: it is
    /// believed only while its bytes hash to the vault's record of that accept (`acceptedKey`).
    static func acceptedCopyURL(nodeRoot: URL) -> URL { nodeRoot.appendingPathComponent("v2/presets-accepted.json") }

    /// After the user's accept recorded `hash` (`markAccepted`): the file's bytes kept as accepted, when they still hash
    /// to it (a file that moved since keeps no copy: the next card shows the whole file). Best effort: a copy not kept
    /// only makes the next card list the whole file.
    static func keepAcceptedCopy(hash: String, nodeRoot: URL) {
        guard case .success(let data?) = bytes(root: nodeRoot), sealFingerprint(of: data) == hash else { return }
        let url = acceptedCopyURL(nodeRoot: nodeRoot)
        try? VibePaths.ensurePrivate(url.deletingLastPathComponent(), within: nodeRoot)
        try? VibePaths.writePrivate(data, to: url)
    }

    /// The presets as the user last accepted them: the kept copy, only when its bytes hash to the vault's record of the
    /// user's accept (`record[acceptedKey]`); nil otherwise (none kept, or not what was accepted).
    static func acceptedPresets(nodeRoot: URL, record: [String: String]?) -> LaunchPresets? {
        guard let accepted = record?[acceptedKey],
              let data = try? Data(contentsOf: acceptedCopyURL(nodeRoot: nodeRoot)), data.count <= fileLimit,
              sealFingerprint(of: data) == accepted else { return nil }
        return decode(data).presets
    }

    /// A preset in a few words for an accept card or its difference: its kind and what it runs, its variables (by name,
    /// or with `values` each as the confirmation shows it: a secret-looking one `<set>`), whether a shell stays.
    static func described(_ preset: LaunchPreset, values: Bool) -> String {
        var parts = [preset.kind == .shell ? "a shell" : "\(preset.kind == .claude ? "Claude" : preset.kind.rawValue): `\(preset.command)`"]
        if !preset.env.isEmpty {
            let shown = shownValues(preset)
            parts.append("sets " + preset.env.keys.sorted().map { values ? "\($0)=\(shown[$0] ?? "<set>")" : $0 }.joined(separator: ", "))
        }
        if preset.keepShell { parts.append("a shell stays") }
        return ConfigSeal.inert(preset.name, limit: 80) + " (" + ConfigSeal.inert(parts.joined(separator: "; "), limit: 600) + ")"
    }

    /// What changed in presets from `before` (nil: nothing known of the last accept, so every preset of `after` is
    /// listed) to `after`, one line each: `+` added, `-` removed, `~` changed (was, now), and the folders' defaults.
    /// The built-ins as this build makes them are left out.
    static func changeLines(before: LaunchPresets?, after: LaunchPresets, values: Bool) -> [String] {
        let old = before ?? LaunchPresets(global: [])
        var lines: [String] = []
        func scope(_ title: String, _ was: [LaunchPreset], _ now: [LaunchPreset]) {
            let was = was.filter { !isBuiltInCopy($0) }, now = now.filter { !isBuiltInCopy($0) }
            var found: [String] = []
            for preset in now {
                if let earlier = was.first(where: { $0.id == preset.id }) ?? was.first(where: { $0.name == preset.name }) {
                    if earlier != preset { found.append("~ \(described(earlier, values: values)) → \(described(preset, values: values))") }
                } else {
                    found.append("+ " + described(preset, values: values))
                }
            }
            for preset in was where !now.contains(where: { $0.id == preset.id || $0.name == preset.name }) {
                found.append("- " + described(preset, values: values))
            }
            if !found.isEmpty { lines.append(title + ":"); lines += found.map { "  " + $0 } }
        }
        scope("every folder", old.global, after.global)
        for root in Set(old.byProject.keys).union(after.byProject.keys).sorted() {
            scope(ConfigSeal.inert(root, limit: 200), old.byProject[root] ?? [], after.byProject[root] ?? [])
        }
        let named = { (presets: LaunchPresets, root: String, id: UUID?) -> String in
            guard let id else { return "none" }
            return ConfigSeal.inert(presets.presets(for: root).first { $0.id == id }?.name ?? id.uuidString, limit: 80)
        }
        for root in Set(old.defaults.keys).union(after.defaults.keys).sorted() where old.defaults[root] != after.defaults[root] {
            lines.append("default for \(ConfigSeal.inert(root, limit: 200)): \(named(after, root, after.defaults[root])) (was \(named(old, root, old.defaults[root])))")
        }
        return lines
    }

    /// The accept card's line for the presets file: what changed since the user's last accept, names only (a card
    /// reaches a web page, which never gets a variable's value), or the presets as they are when the last accept isn't
    /// known.
    static func cardChange(before: LaunchPresets?, after: LaunchPresets) -> String {
        let lines = changeLines(before: before, after: after, values: false)
        let head = before == nil ? "presets now (no accepted copy to compare)" : "presets changed since you accepted them"
        guard !lines.isEmpty else { return before == nil ? "no presets of yours" : "presets: no preset changed (only the file's text)" }
        return head + ": " + lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "; ")
    }

    /// `config held --diff ~/.vibeswitcher/presets.json`: what changed in presets since the user's last accept, each
    /// variable's value as the confirmation shows it (a terminal's reply only). Asks the vault: never on the queue.
    static func difference(vault: LeadVault?, nodeRoot: URL) -> [String] {
        let file = read(root: nodeRoot)
        guard file.fingerprint != nil else { return file.problems.isEmpty ? ["(no presets file)"] : file.problems.map { ConfigSeal.inert($0, limit: 400) } }
        let record = (try? vault?.guardedRecord(root: acceptRoot(nodeRoot: nodeRoot))) ?? nil
        let before = acceptedPresets(nodeRoot: nodeRoot, record: record)
        let lines = changeLines(before: before, after: file.presets, values: true)
        return [before == nil ? "── presets now (no accepted copy to compare: every preset of yours)" : "── presets since you last accepted them"]
            + (lines.isEmpty ? ["  no preset changed"] : lines)
    }
}
