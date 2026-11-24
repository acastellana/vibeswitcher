import Foundation
import VibeCore

/// The one code of `vibeswitcher update` (2026-11-24, the lead's rule): beside the switch it names, it seals only these,
/// and only when every check passes; anything else held stays held, listed before the code.
///
/// (a) **The builds folder** (`~/.vibeswitcher/v2/builds`, a `.listing`), sealed by `build.switch` before its plan when
///     the request carries what `update` saw (`InstallSeen`):
///   1. the folder before the install was the one the vault accepted (`before`, its listing hash, is the accepted one);
///   2. between before and after, only these top-level entries changed: `COMMIT` added (absent before), `installs`
///      and `current` (`installChange`, judged by `update` itself, the user's process, as it ran the install);
///   3. the folder now is the one `update` saw right after the install (`after`, its listing hash: inodes and change
///      times included, which no process can set back), and the vault seals exactly that hash;
///   4. `COMMIT` is laid out as install-node lays it out (`layoutRefusal`: `bin/`, `Resources/`, `build-info`, regular
///      files and folders, no links, nothing group- or other-writable; `bin/` the programs `build-info` names, each of
///      its recorded sha256, `NodeFolders.verifyBuild`); `current` links to `COMMIT`; `installs`' last line names it.
/// (b) **The unit folder** (`~/.config/systemd/user`, a `.folder`), sealed by `build.seal` after the follow-up: the
///     folder now, but for the node's unit with its `ExecStart` put back to the build it switched from, hashes to the
///     accepted one (`unitSwap`): `ExecStart` is the only line that changed, and it is exactly what the follow-up writes
///     for `COMMIT` (`NodeUnit.execStart`). The vault seals the folder's hash from the same read.
///
/// The vault's accept carries `SwitchSeal.partialKey`, so it seals what it is shown and holds the rest.
public enum SwitchSealCheck {
    /// What `update` saw of the builds folder around its install: the listing hash before and after.
    public struct InstallSeen: Codable, Equatable, Sendable {
        public var before: String
        public var after: String
        public init(before: String, after: String) {
            self.before = before
            self.after = after
        }
    }

    /// The top-level entries that changed between `before` and `after` (`SwitchSeal.entries`) beyond what an install of
    /// `commit` changes: `commit` added (absent before), `installs`, `current`. Empty: only the install's.
    public static func installChange(before: [String: String], after: [String: String], commit: String) -> [String] {
        guard NodeUnit.isCommit(commit) else { return ["\(ConfigSeal.inert(commit, limit: 80)) isn't a commit (40 lowercase hex digits)"] }
        var other: [String] = []
        if before[commit] != nil { other.append("\(commit) was there before the install") }
        if after[commit] == nil { other.append("\(commit) isn't there after the install") }
        for name in Set(before.keys).union(after.keys).sorted() where ![commit, "installs", "current"].contains(name) {
            switch (before[name], after[name]) {
            case (nil, _?): other.append("\(ConfigSeal.inert(name, limit: 80)) added")
            case (_?, nil): other.append("\(ConfigSeal.inert(name, limit: 80)) removed")
            case let (was?, now?) where was != now: other.append("\(ConfigSeal.inert(name, limit: 80)) changed")
            default: break
            }
        }
        return other
    }

    /// Why `<prefix>/<commit>` isn't a build as install-node lays it out, or `current` and `installs` don't name it; nil
    /// when it is.
    public static func layoutRefusal(prefix: String, commit: String) -> String? {
        // Its shape before any path is made of it or compared with it (`../x`, a name `installs`' line merely starts with).
        guard NodeUnit.isCommit(commit) else { return "\(ConfigSeal.inert(commit, limit: 80)) isn't a commit (40 lowercase hex digits)" }
        let folder = NodeFolders.join(prefix, commit)
        if case .failure(let refused) = NodeFolders.verifyBuild(folder: folder, prefix: prefix) { return refused.text }
        let allowed: [String: Set<String>] = ["": ["bin", "Resources", "build-info"], "Resources": ["bin", "lib", "install-node.sh"]]
        func walk(_ relative: String) -> String? {
            let path = relative.isEmpty ? folder : NodeFolders.join(folder, relative)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return "\(relative.isEmpty ? commit : relative) can't be read" }
            for name in names.sorted() {
                let shown = relative.isEmpty ? name : relative + "/" + name
                if let only = allowed[relative], !only.contains(name) { return "\(ConfigSeal.inert(shown, limit: 120)) isn't part of a build install-node lays out" }
                var info = stat()
                guard lstat(NodeFolders.join(path, name), &info) == 0 else { return "\(ConfigSeal.inert(shown, limit: 120)) can't be read" }
                if info.st_mode & 0o022 != 0 { return "\(ConfigSeal.inert(shown, limit: 120)) is writable by others than its owner" }
                switch info.st_mode & S_IFMT {
                case S_IFDIR: if let why = walk(shown) { return why }
                case S_IFREG: break
                default: return "\(ConfigSeal.inert(shown, limit: 120)) isn't a regular file or a folder"
                }
            }
            return nil
        }
        if let why = walk("") { return why }
        let current = NodeFolders.join(prefix, "current")
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: current), target == commit || target == folder else {
            return "current doesn't link to \(commit)"
        }
        let installs = (try? String(contentsOfFile: NodeFolders.join(prefix, "installs"), encoding: .utf8)) ?? ""
        guard installs.split(separator: "\n").last?.hasPrefix(commit + " ") == true else { return "installs' last line doesn't name \(commit)" }
        return nil
    }

    /// The unit's text `bytes` with its `ExecStart` for `to` put back to `from` (both under `prefix`), when it holds
    /// exactly one `ExecStart` line and that line is the follow-up's for `to`; nil otherwise.
    public static func unitSwap(_ bytes: Data, prefix: String, from: String, to: String) -> Data? {
        guard NodeUnit.isCommit(from), NodeUnit.isCommit(to), from != to, let text = String(data: bytes, encoding: .utf8) else { return nil }
        let line = { (commit: String) in "ExecStart=" + NodeUnit.execStart(prefix: prefix, commit: commit).joined(separator: " ") }
        var lines = text.components(separatedBy: "\n")
        let starts = lines.indices.filter { lines[$0].hasPrefix("ExecStart") }
        guard starts.count == 1, lines[starts[0]] == line(to) else { return nil }
        lines[starts[0]] = line(from)
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// What a seal did: the names sealed, and what stays held (names), or why nothing of it was.
    public struct Sealed: Equatable, Sendable {
        public var sealed: [String]
        public var held: [String]
        public var refusals: [String]
    }

    /// (a) for `commit`: the builds folder at `prefix` sealed as `seen.after`, for the vault's record of `home`, when every
    /// check passes. Reads the disk and the vault.
    public static func sealBuilds(prefix: String, commit: String, seen: InstallSeen, home: String, vault: LeadVault) -> Sealed {
        guard NodeUnit.isCommit(commit) else { return Sealed(sealed: [], held: [], refusals: ["\(ConfigSeal.inert(commit, limit: 80)) isn't a commit: nothing was sealed"]) }
        do {
            let record = try vault.guardedRecord(root: home) ?? [:]
            guard record[SwitchSeal.buildsKey] == seen.before else {
                return Sealed(sealed: [], held: ConfigSeal.held(in: record), refusals: ["the builds folder before the install wasn't the one you last accepted: its change stays held (`vs config held`)"])
            }
            if let why = layoutRefusal(prefix: prefix, commit: commit) {
                return Sealed(sealed: [], held: ConfigSeal.held(in: record), refusals: ["the builds folder isn't as the install left it: \(why)"])
            }
            guard SwitchSeal.listingHash(prefix) == seen.after else {
                return Sealed(sealed: [], held: ConfigSeal.held(in: record), refusals: ["the builds folder changed after the install: its change stays held (`vs config held`)"])
            }
            return vaultAccept([SwitchSeal.buildsKey: seen.after], name: SwitchSeal.buildsName, home: home, vault: vault)
        } catch {
            return Sealed(sealed: [], held: [], refusals: ["the vault couldn't be asked (\(error)): nothing of the builds folder was accepted"])
        }
    }

    /// (b) for a switch from `from` to `to`: the unit folder `unitFolder` sealed when the node's unit in it changed only
    /// in its `ExecStart`, from `from`'s to `to`'s. Reads the disk and the vault.
    public static func sealUnit(unitFolder: String, unitFile: String, prefix: String, from: String, to: String, home: String, vault: LeadVault) -> Sealed {
        guard NodeUnit.isCommit(from), NodeUnit.isCommit(to), from != to else {
            return Sealed(sealed: [], held: [], refusals: ["the switch's builds aren't two commits (40 lowercase hex digits): nothing was sealed"])
        }
        do {
            let record = try vault.guardedRecord(root: home) ?? [:]
            // The unit may name `to` only once its build is laid out as install-node lays it out and the builds folder,
            // holding it, is the sealed one (nothing of it held).
            if let why = layoutRefusal(prefix: prefix, commit: to) {
                return Sealed(sealed: [], held: ConfigSeal.held(in: record), refusals: ["the unit stays held: \(to)'s build isn't as install-node lays it out (\(why))"])
            }
            guard record[SwitchSeal.buildsKey] == SwitchSeal.listingHash(prefix), !ConfigSeal.held(in: record).contains(SwitchSeal.buildsName) else {
                return Sealed(sealed: [], held: ConfigSeal.held(in: record), refusals: ["the unit stays held: the builds folder holding \(to) isn't the accepted one yet (`vs config held`)"])
            }
            guard let accepted = record[SwitchSeal.unitFolderKey] else {
                return Sealed(sealed: [], held: ConfigSeal.held(in: record), refusals: ["the vault records no accepted unit folder: its change stays held (`vs config held`)"])
            }
            guard let read = SwitchSeal.folderHashes(folder: unitFolder, name: SwitchSeal.unitFolderName, file: unitFile, swap: { unitSwap($0, prefix: prefix, from: from, to: to) }) else {
                return Sealed(sealed: [], held: ConfigSeal.held(in: record), refusals: ["the unit's ExecStart isn't the one the switch writes for \(to), or it isn't its only change: its change stays held (`vs config held`)"])
            }
            if read.now == accepted { return Sealed(sealed: [], held: ConfigSeal.held(in: record), refusals: []) }
            guard read.swapped == accepted else {
                return Sealed(sealed: [], held: ConfigSeal.held(in: record), refusals: ["the unit folder changed beyond the unit's ExecStart since your last accept: it stays held (`vs config held`)"])
            }
            return vaultAccept([SwitchSeal.unitFolderKey: read.now], name: SwitchSeal.unitFolderName, home: home, vault: vault)
        } catch {
            return Sealed(sealed: [], held: [], refusals: ["the vault couldn't be asked (\(error)): nothing of the unit folder was accepted"])
        }
    }

    /// The vault's partial accept of `shown`.
    static func vaultAccept(_ shown: [String: String], name: String, home: String, vault: LeadVault) -> Sealed {
        do {
            let check = try vault.checkConfig(root: home, shown: shown.merging([SwitchSeal.partialKey: "1"]) { first, _ in first })
            let sealed = !check.held.contains(name)
            return Sealed(sealed: sealed ? [name] : [], held: check.held,
                          refusals: sealed ? [] : ["\(name) changed again before the vault's look: it stays held (`vs config held`)"])
        } catch {
            return Sealed(sealed: [], held: [], refusals: ["the vault didn't take the accept (\(error))"])
        }
    }
}
