import Foundation
import VibeCore

/// The one code of `vibeswitcher update` (2026-11-24, the lead's rule): beside the switch it names, it seals only these,
/// and only when every check passes; anything else held stays held, listed before the code.
///
/// (a) **The builds folder** (`~/.vibeswitcher/v2/builds`, a `.listing`), sealed by `build.switch` before its plan when
///     the request carries what `update` saw (`InstallSeen`):
///   1. the folder before the install was the one the vault accepted (`before`, its listing hash, is the accepted one);
///   2. between before and after, only these top-level entries changed: `COMMIT` added (absent before), `installs`
///      and `current` (`installChange`, judged here from the listing's lines `update` sends, which hash to the
///      accepted hash, against the lines read now);
///   3. the folder now is the one `update` saw right after the install (`after`, its listing hash: inodes and change
///      times included, which no process can set back), and the vault seals exactly that hash;
///   4. `COMMIT` is laid out as install-node lays it out (`layoutRefusal`: `bin/`, `Resources/`, `build-info`, regular
///      files and folders, no links, nothing group- or other-writable; `bin/` the programs `build-info` names, each of
///      its recorded sha256, `NodeFolders.verifyBuild`); `current` links to `COMMIT`; `installs`' last line names it.
/// (c) **`current`, moved by the follow-up** (a plain `switch`'s, to a build installed and accepted before), sealed by
///     `build.seal` before (b): the builds folder's listing from just before the follow-up (`buildsBefore`, sent by the
///     command line) hashes to the accepted hash; since, only `current` changed (`installChange`'s grouping, the
///     folder's own line aside); it links to the target, an installed build. An `update`'s follow-up leaves `current`
///     as the install left it (`SwitchFollowUp.moveCurrent` writes nothing when it names the target already), so its
///     builds folder is as (a) sealed it (the real node, 2026-11-27: the follow-up moved `current` onto itself after
///     (a), a new link, so the folder and then the unit stayed held after the update's one code).
/// (b) **The unit folder** (`~/.config/systemd/user`, a `.folder`), sealed by `build.seal` after the follow-up: the
///     folder now, but for the node's unit with its `ExecStart` put back to the build it switched from, hashes to the
///     accepted one (`unitSwap`): `ExecStart` is the only line that changed, and it is exactly what the follow-up writes
///     for `COMMIT` (`NodeUnit.execStart`). The vault seals the folder's hash from the same read.
///
/// The vault's accept carries `SwitchSeal.partialKey`, so it seals what it is shown and holds the rest.
public enum SwitchSealCheck {
    /// What `update` saw of the builds folder around its install: the listing's lines before (`SwitchSeal.listingLines`:
    /// the server hashes them to the accepted hash, and judges the top-level entries from them itself) and its hash
    /// after.
    public struct InstallSeen: Codable, Equatable, Sendable {
        public var beforeListing: [String]
        public var after: String
        public var before: String { SwitchSeal.listingHash(lines: beforeListing) }
        public init(beforeListing: [String], after: String) {
            self.beforeListing = beforeListing
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
            let now = SwitchSeal.listingLines(prefix)
            guard SwitchSeal.listingHash(lines: now) == seen.after else {
                return Sealed(sealed: [], held: ConfigSeal.held(in: record), refusals: ["the builds folder changed after the install: its change stays held (`vs config held`)"])
            }
            // Judged here, from the lines the accepted hash vouches for: only the install's top-level entries changed.
            let other = installChange(before: SwitchSeal.entries(lines: seen.beforeListing), after: SwitchSeal.entries(lines: now), commit: commit)
            guard other.isEmpty else {
                return Sealed(sealed: [], held: ConfigSeal.held(in: record), refusals: ["the builds folder changed beyond the install (" + other.joined(separator: "; ") + "): it stays held (`vs config held`)"])
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

    /// (c): the builds folder sealed as the follow-up left it, when its only change since `buildsBefore` (the accepted
    /// listing, from just before the follow-up) is `current`, linking to `to`. Nothing to do when it is the accepted one
    /// already. Reads the disk and the vault.
    public static func sealCurrent(prefix: String, to: String, buildsBefore: [String], home: String, vault: LeadVault) -> Sealed {
        guard NodeUnit.isCommit(to) else { return Sealed(sealed: [], held: [], refusals: ["\(ConfigSeal.inert(to, limit: 80)) isn't a commit: nothing was sealed"]) }
        do {
            let record = try vault.guardedRecord(root: home) ?? [:]
            let now = SwitchSeal.listingLines(prefix)
            if record[SwitchSeal.buildsKey] == SwitchSeal.listingHash(lines: now) { return Sealed(sealed: [], held: ConfigSeal.held(in: record), refusals: []) }
            guard !buildsBefore.isEmpty, record[SwitchSeal.buildsKey] == SwitchSeal.listingHash(lines: buildsBefore) else {
                return Sealed(sealed: [], held: ConfigSeal.held(in: record), refusals: ["the builds folder before the switch's follow-up wasn't the one you last accepted: its change stays held (`vs config held`)"])
            }
            let before = SwitchSeal.entries(lines: buildsBefore), after = SwitchSeal.entries(lines: now)
            let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
            guard changed.isSubset(of: [SwitchFollowUp.currentLink]) else {
                return Sealed(sealed: [], held: ConfigSeal.held(in: record), refusals: ["the builds folder changed beyond the switch's `current` ("
                    + changed.subtracting([SwitchFollowUp.currentLink]).sorted().map { ConfigSeal.inert($0, limit: 80) }.joined(separator: ", ") + "): it stays held (`vs config held`)"])
            }
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: NodeFolders.join(prefix, SwitchFollowUp.currentLink)),
                  target == to || target == NodeFolders.join(prefix, to) else {
                return Sealed(sealed: [], held: ConfigSeal.held(in: record), refusals: ["current doesn't link to \(to): the builds folder stays held (`vs config held`)"])
            }
            if case .failure(let refused) = NodeFolders.verifyBuild(folder: NodeFolders.join(prefix, to), prefix: prefix) {
                return Sealed(sealed: [], held: ConfigSeal.held(in: record), refusals: ["current links to \(to), which isn't an installed build (\(refused.text)): the builds folder stays held"])
            }
            return vaultAccept([SwitchSeal.buildsKey: SwitchSeal.listingHash(lines: now)], name: SwitchSeal.buildsName, home: home, vault: vault)
        } catch {
            return Sealed(sealed: [], held: [], refusals: ["the vault couldn't be asked (\(error)): nothing of the builds folder was accepted"])
        }
    }

    /// `build.seal`'s: (c), then (b), what each sealed and refused together.
    public static func sealSwitch(unitFolder: String, unitFile: String, prefix: String, from: String, to: String, buildsBefore: [String]?,
                                  home: String, vault: LeadVault) -> Sealed {
        let current = buildsBefore.map { sealCurrent(prefix: prefix, to: to, buildsBefore: $0, home: home, vault: vault) }
        // A node with no unit (started detached: its follow-up moves `current` alone) has none to seal.
        guard FileManager.default.fileExists(atPath: NodeFolders.join(unitFolder, unitFile)) else {
            return current ?? Sealed(sealed: [], held: [], refusals: [])
        }
        let unit = sealUnit(unitFolder: unitFolder, unitFile: unitFile, prefix: prefix, from: from, to: to, home: home, vault: vault)
        return Sealed(sealed: (current?.sealed ?? []) + unit.sealed, held: unit.held, refusals: (current?.refusals ?? []) + unit.refusals)
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

    /// `update`'s install script, or why it isn't run (the review of 16f0ce69, U1): the install-node of the build this
    /// command line was proved installed from (`own`, its folder: `NodeFolders.installedBuild` of `/proc/self/exe`),
    /// never whatever `current` names; `current` naming that very build (install-node runs only as `current`'s copy);
    /// the script a regular file, no link, writable by its owner alone. Whether it is the accepted one is the builds
    /// folder's seal's to say (`buildsHeld`, asked of the server around this).
    public static func installScript(prefix: String, own: String) -> Result<String, StartRefusal> {
        guard let ownReal = NodeFolders.resolved(own), let currentReal = NodeFolders.resolved(NodeFolders.join(prefix, "current")) else {
            return .failure(StartRefusal("update: \(ConfigSeal.inert(prefix, limit: .max))/current or this command line's build can't be resolved: nothing was asked or run"))
        }
        guard ownReal == currentReal else {
            return .failure(StartRefusal("update: current names \(ConfigSeal.inert(currentReal, limit: .max)), not the build this command line runs from "
                                         + "(\(ConfigSeal.inert(ownReal, limit: .max))): nothing was asked or run; `vibeswitcher config held` shows what changed under the builds folder"))
        }
        let script = NodeFolders.join(ownReal, "Resources/install-node.sh")
        var info = stat()
        guard lstat(script, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o022 == 0 else {
            return .failure(StartRefusal("update: \(ConfigSeal.inert(script, limit: .max)) isn't a regular file only its owner can write: nothing was asked or run"))
        }
        return .success(script)
    }

    /// The install script opened for its run (the re-read of e2fa0714, B): its descriptor, when what it opened is the
    /// regular file whose line the listing `listing` (the builds folder at `prefix` as last read, the accepted one) holds
    /// for it, the same inode, size, mode and times, on the folder's device. The run reads the script through this
    /// descriptor (`/dev/fd/N`), so a file renamed into its place after this is never what runs. Close-on-exec here; the
    /// spawn keeps it.
    public static func openScript(_ script: String, prefix: String, listing: [String]) -> Result<Int32, StartRefusal> {
        let refused = { (why: String) in Result<Int32, StartRefusal>.failure(StartRefusal("update: \(why): nothing was run or switched (`vibeswitcher config held`)")) }
        guard let prefixReal = NodeFolders.resolved(prefix), script.hasPrefix(prefixReal + "/") else { return refused("the install script isn't under the builds folder") }
        let relative = String(script.dropFirst(prefixReal.count + 1))
        let fd = open(script, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | O_NOCTTY)
        guard fd >= 0 else { return refused("the install script can't be opened") }
        var info = stat(), folder = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, lstat(prefixReal, &folder) == 0, info.st_dev == folder.st_dev,
              listing.contains(SwitchSeal.listingLine(info, path: script, relative: relative)) else {
            close(fd)
            return refused("the install script opened isn't the file the accepted builds folder lists")
        }
        return .success(fd)
    }

    /// The text by which an install-node takes `--self PATH` (runs from a sealed copy of its bytes): an older one, without
    /// it, runs from the checked descriptor itself.
    public static let takesSelf = "--self) self_given=$2"

    /// The checked script's bytes (`fd`, `openScript`'s) read once into a sealed memfd (the review of a1ce87ce: a
    /// descriptor pins the inode, not the bytes), then the file's `fstat` compared with the listing's line for it again:
    /// a write in place anywhere between the listing's read and the end of the copy changed its change time, which
    /// nothing sets back, so the copy is the listed file's bytes, or nothing is run.
    public static func sealedScript(_ fd: Int32, script: String, prefix: String, listing: [String]) -> Result<Platform.ProcessSelf.SealedCopy, StartRefusal> {
        let refused = { (why: String) in
            Result<Platform.ProcessSelf.SealedCopy, StartRefusal>.failure(StartRefusal("update: \(why): nothing was run or switched (`vibeswitcher config held`)"))
        }
        guard let prefixReal = NodeFolders.resolved(prefix), script.hasPrefix(prefixReal + "/") else { return refused("the install script isn't under the builds folder") }
        let copy: Platform.ProcessSelf.SealedCopy
        switch Platform.ProcessSelf.sealedCopy(of: fd, name: "install-node.sh") {
        case .failure(let error): return refused("the install script couldn't be copied to sealed memory (\(error))")
        case .success(let made): copy = made
        }
        var info = stat()
        guard fstat(fd, &info) == 0, Int(info.st_size) == copy.size,
              listing.contains(SwitchSeal.listingLine(info, path: script, relative: String(script.dropFirst(prefixReal.count + 1)))) else {
            close(copy.fd)
            return refused("the install script changed after the accepted builds folder was read")
        }
        return .success(copy)
    }

    /// The argv that runs `command` in a transient scope of the user's systemd manager (the re-read of e2fa0714, A):
    /// nothing the install starts is in the terminal's scope, so the voice rule never takes it for the user's.
    public static func scopeArguments(runner: String, command: [String]) -> [String] {
        [runner, "--user", "--scope", "--quiet", "--collect", "--"] + command
    }

    /// Why the user's systemd manager can't take the install's scope (no `systemd-run`, no manager's socket under
    /// `/run/user/<uid>`), or nil.
    public static func userManagerRefusal(runner: String = "/usr/bin/systemd-run", uid: uid_t = getuid()) -> String? {
        guard FileManager.default.isExecutableFile(atPath: runner) else { return "\(runner) isn't there" }
        let socket = "/run/user/\(uid)/systemd/private"
        var info = stat()
        guard lstat(socket, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { return "the user's systemd manager isn't running (no \(socket))" }
        return nil
    }
}
