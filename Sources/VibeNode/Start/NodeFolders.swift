import Foundation
import VibeCore

/// Where the node's pieces are, from what no environment variable moves (the start plan's ST-D2 to ST-D4): the unit
/// folder and the runtime folder from the account's home and uid, the mode from what a same-uid process can't change,
/// swiftly's and node's folders from fixed places, and the build `start` starts, checked against its `build-info`.
/// Every path and reader is a parameter, so tests drive this with scratch folders and stand-ins.
public enum NodeFolders {
    /// The command line's name in an installed build's `bin/` (built as `vibeswitcher-cli`).
    public static let installedCLI = "vibeswitcher"

    /// The unit folder: always `<home>/.config/systemd/user`, the home from `getpwuid`. Neither the command line's
    /// `XDG_CONFIG_HOME` nor the manager's environment (`set-environment`, which isn't the manager's lookup path)
    /// chooses it (ST-D2).
    public static func unitFolder(accountHome: String) -> String { join(accountHome, ".config/systemd/user") }

    /// The user's runtime folder, `/run/user/<uid>`, never `$XDG_RUNTIME_DIR`.
    public static func runtimeFolder(uid: uid_t) -> String { "/run/user/\(uid)" }

    /// Where installs go unless told otherwise: `<home>/.vibeswitcher/v2/builds`.
    public static func defaultPrefix(accountHome: String) -> String { join(accountHome, ".vibeswitcher/v2/builds") }

    /// The user's node's root, `<home>/.vibeswitcher`, the home from `getpwuid` (the root the host started with
    /// `--node` takes): where a detached node's record and log are (S3), whatever the command line's HOME says.
    public static func nodeRoot(accountHome: String) -> String { join(accountHome, ".vibeswitcher") }

    /// How the node is started on this machine.
    public enum Mode: Equatable, Sendable {
        /// pid 1 is systemd and the user manager's socket is there: the unit.
        case systemd
        /// pid 1 isn't systemd: the detached start (ST-D6).
        case noSystemd
        /// pid 1 is systemd, but `<runtime>/systemd/private` is missing: refused ("the user manager's socket is
        /// missing"), never taken for "no systemd".
        case socketMissing
    }

    /// The mode, from what a same-uid process can't change: `systemdSystem` (`/run/systemd/system`) is a folder and
    /// `initComm` (`/proc/1/comm`) says `systemd`; then whether `<runtimeFolder>/systemd/private` exists.
    public static func mode(runtimeFolder: String, systemdSystem: String = "/run/systemd/system", initComm: String = "/proc/1/comm") -> Mode {
        var info = stat()
        let folder = lstat(systemdSystem, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
        let comm = (try? String(contentsOfFile: initComm, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard folder, comm == "systemd" else { return .noSystemd }
        return lstat(join(runtimeFolder, "systemd/private"), &info) == 0 ? .systemd : .socketMissing
    }

    /// What `lstat` says of `path` as `Platform.Tools.FileStatus` (a link is itself), or nil.
    public static func fileStatus(_ path: String) -> Platform.Tools.FileStatus? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return (owner: info.st_uid, mode: info.st_mode, isFile: info.st_mode & S_IFMT == S_IFREG)
    }

    /// The unit's two PATH folders, from fixed places, never the shell's PATH (ST-D4):
    /// - swift: `<home>/.local/share/swiftly/bin`, holding `swift`;
    /// - node: `<home>/.nvm/versions/node/<nodeVersion>/bin` when the user typed `--node-version`; else an existing
    ///   unit's (`existingUnit`, which must be of that form); else the one `v*` there holding `node`.
    ///
    /// Each must be absolute, a folder (not a link), owned by `uid` and writable by nobody else, as must every folder
    /// from it up to the home; none under `/mnt/`. `status` reads a path without following a link (a test stands in
    /// for another uid).
    public static func toolFolders(accountHome: String, nodeVersion: String?, existingUnit: NodeUnit.Inputs?, uid: uid_t = getuid(),
                                   status: (String) -> Platform.Tools.FileStatus? = fileStatus) -> Result<(swiftBin: String, nodeBin: String), StartRefusal> {
        guard accountHome.hasPrefix("/") else {
            return .failure(StartRefusal("the home \(ConfigSeal.inert(accountHome, limit: .max)) isn't an absolute path"))
        }
        let swiftBin = join(accountHome, ".local/share/swiftly/bin")
        if let refused = folderRefusal(swiftBin, label: "swift folder", home: accountHome, uid: uid, status: status) { return .failure(refused) }
        guard NodePreflight.isExecutableFile(join(swiftBin, "swift")) else {
            return .failure(StartRefusal("the swift folder \(ConfigSeal.inert(swiftBin, limit: .max)) holds no swift (swiftly's)"))
        }
        let versions = join(accountHome, ".nvm/versions/node")
        let nodeBin: String
        if let nodeVersion {
            guard isVersion(nodeVersion) else {
                return .failure(StartRefusal("--node-version \(ConfigSeal.inert(nodeVersion, limit: .max)) isn't a version of the form vX.Y.Z"))
            }
            nodeBin = join(versions, "\(nodeVersion)/bin")
        } else if let existingUnit {
            let version = ((existingUnit.nodeBin as NSString).deletingLastPathComponent as NSString).lastPathComponent
            guard existingUnit.nodeBin == join(versions, "\(version)/bin"), isVersion(version) else {
                return .failure(StartRefusal("the unit's node folder \(ConfigSeal.inert(existingUnit.nodeBin, limit: .max)) isn't one of \(ConfigSeal.inert(versions, limit: .max))/v*/bin: `start --node-version vX.Y.Z` picks one"))
            }
            nodeBin = existingUnit.nodeBin
        } else {
            let holding = ((try? FileManager.default.contentsOfDirectory(atPath: versions)) ?? [])
                .filter { isVersion($0) && NodePreflight.isExecutableFile(join(versions, "\($0)/bin/node")) }
                .sorted()
            guard let only = holding.first else {
                return .failure(StartRefusal("node: no folder \(ConfigSeal.inert(versions, limit: .max))/v*/bin holds node"))
            }
            guard holding.count == 1 else {
                return .failure(StartRefusal("node: more than one version in \(ConfigSeal.inert(versions, limit: .max)) (\(holding.map { ConfigSeal.inert($0, limit: .max) }.joined(separator: ", "))): `start --node-version vX.Y.Z` picks one"))
            }
            nodeBin = join(versions, "\(only)/bin")
        }
        if let refused = folderRefusal(nodeBin, label: "node folder", home: accountHome, uid: uid, status: status) { return .failure(refused) }
        guard NodePreflight.isExecutableFile(join(nodeBin, "node")) else {
            return .failure(StartRefusal("the node folder \(ConfigSeal.inert(nodeBin, limit: .max)) holds no node"))
        }
        return .success((swiftBin: swiftBin, nodeBin: nodeBin))
    }

    /// The installed build at `folder`, or why it isn't one `start` starts: a direct child of `prefix` (both by
    /// `realpath`), itself a folder and not a link (a link `<prefix>/A` to a sibling `<prefix>/B` would have B checked
    /// and run under A's name: the review of S1), named for a commit (40 hex digits), whose `build-info` names that
    /// commit, and whose `bin/` holds exactly the regular files `build-info` records, each with the hash recorded
    /// (ST-D3). The commit returned is the folder's own name.
    public static func verifyBuild(folder: String, prefix: String) -> Result<BuildInfo, StartRefusal> {
        guard let resolvedPrefix = resolved(prefix) else {
            return .failure(StartRefusal("the prefix \(ConfigSeal.inert(prefix, limit: .max)) can't be resolved"))
        }
        guard let resolvedFolder = resolved(folder) else {
            return .failure(StartRefusal("the build \(ConfigSeal.inert(folder, limit: .max)) can't be resolved"))
        }
        guard (resolvedFolder as NSString).deletingLastPathComponent == resolvedPrefix else {
            return .failure(StartRefusal("the build \(ConfigSeal.inert(folder, limit: .max)) resolves to \(ConfigSeal.inert(resolvedFolder, limit: .max)), not a folder directly in the prefix \(ConfigSeal.inert(resolvedPrefix, limit: .max))"))
        }
        guard let own = fileStatus(folder), own.mode & S_IFMT == S_IFDIR,
              (folder as NSString).lastPathComponent == (resolvedFolder as NSString).lastPathComponent else {
            return .failure(StartRefusal("the build \(ConfigSeal.inert(folder, limit: .max)) is a link (to \(ConfigSeal.inert(resolvedFolder, limit: .max))), not a commit's own folder"))
        }
        let name = (resolvedFolder as NSString).lastPathComponent
        guard NodeUnit.isCommit(name) else {
            return .failure(StartRefusal("the build's folder \(ConfigSeal.inert(name, limit: .max)) isn't named for a commit (40 hex digits)"))
        }
        let info: BuildInfo
        switch BuildInfo.read(buildFolder: resolvedFolder) {
        case .failure(let refused): return .failure(StartRefusal("the build's record: \(ConfigSeal.inert(refused.description, limit: .max))"))
        case .success(let read): info = read
        }
        guard info.commit == name else {
            return .failure(StartRefusal("\(ConfigSeal.inert(resolvedFolder, limit: .max))/\(BuildInfo.fileName) names the commit \(info.commit), not its folder's \(name)"))
        }
        let bin = join(resolvedFolder, "bin")
        let entries = ((try? FileManager.default.contentsOfDirectory(atPath: bin)) ?? []).sorted()
        guard Set(entries) == Set(info.binaries.keys) else {
            return .failure(StartRefusal("\(ConfigSeal.inert(bin, limit: .max)) holds \(entries.map { ConfigSeal.inert($0, limit: .max) }.joined(separator: ", ")); \(BuildInfo.fileName) records \(info.binaries.keys.sorted().joined(separator: ", "))"))
        }
        for entry in entries {
            let path = join(bin, entry)
            guard fileStatus(path)?.isFile == true, let bytes = FileManager.default.contents(atPath: path) else {
                return .failure(StartRefusal("\(ConfigSeal.inert(path, limit: .max)) isn't a regular file that can be read"))
            }
            let hash = BuildInfo.sha256(of: bytes)
            if let recorded = info.binaries[entry], recorded != hash {
                return .failure(StartRefusal("\(ConfigSeal.inert(path, limit: .max)): its sha256 \(hash) isn't the one \(BuildInfo.fileName) records for \(ConfigSeal.inert(entry, limit: .max)) (\(recorded))"))
            }
        }
        return .success(info)
    }

    /// The installed build this command line runs from (`executable`: `/proc/self/exe`), or why `start` and the
    /// `stop` fallback refuse in node mode (ST-D3): resolved with `realpath`, it must be
    /// `<prefix>/<40 hex>/bin/vibeswitcher` of a build `verifyBuild` takes, its own hash among those checked.
    public static func installedBuild(executable: String, prefix: String) -> Result<(commit: String, folder: String), StartRefusal> {
        func refused(_ why: String) -> Result<(commit: String, folder: String), StartRefusal> {
            .failure(StartRefusal("start runs only from an installed build: \(why)"))
        }
        guard let resolvedPrefix = resolved(prefix) else { return refused("the prefix \(ConfigSeal.inert(prefix, limit: .max)) can't be resolved") }
        guard let program = resolved(executable) else { return refused("\(ConfigSeal.inert(executable, limit: .max)) can't be resolved") }
        let bin = (program as NSString).deletingLastPathComponent
        let folder = (bin as NSString).deletingLastPathComponent
        guard (program as NSString).lastPathComponent == installedCLI, (bin as NSString).lastPathComponent == "bin",
              (folder as NSString).deletingLastPathComponent == resolvedPrefix, NodeUnit.isCommit((folder as NSString).lastPathComponent) else {
            return refused("this command line is \(ConfigSeal.inert(program, limit: .max)), not <prefix>/<commit>/bin/\(installedCLI) in \(ConfigSeal.inert(resolvedPrefix, limit: .max))")
        }
        switch verifyBuild(folder: folder, prefix: resolvedPrefix) {
        case .failure(let refusal): return refused(refusal.text)
        case .success(let info): return .success((commit: info.commit, folder: folder))
        }
    }

    /// The build an existing unit runs, or why `start` won't start it (ST-D3): its text in `start`'s form
    /// (`NodeUnit.inputs(parsing:prefix:)`) for a commit `verifyBuild` takes, the commit it verified being the one the
    /// unit names. Every refusal says that removing the unit file lets `start` run `current`.
    ///
    /// Only the commit (and, through `toolFolders(existingUnit:)`, the node folder, checked there) is taken from what
    /// this returns. Its `home` and `swiftBin` are the unit's text, checked only for what a unit can hold: `start`
    /// rewrites the unit from `getpwuid`'s home and `toolFolders`' result, never writing these back (ST-D3's "restores
    /// every other line"; the review of S1).
    public static func unitBuild(unitText: String, prefix: String) -> Result<NodeUnit.Inputs, StartRefusal> {
        func refused(_ refusal: StartRefusal) -> Result<NodeUnit.Inputs, StartRefusal> {
            .failure(StartRefusal("the unit's build isn't started: \(refusal.text); removing the unit file lets `start` run `current`"))
        }
        switch NodeUnit.inputs(parsing: unitText, prefix: prefix) {
        case .failure(let refusal): return refused(refusal)
        case .success(let inputs):
            switch verifyBuild(folder: join(prefix, inputs.commit), prefix: prefix) {
            case .failure(let refusal): return refused(refusal)
            case .success(let info) where info.commit != inputs.commit:
                return refused(StartRefusal("the unit names the commit \(inputs.commit), and its folder holds \(info.commit)'s build"))
            case .success: return .success(inputs)
            }
        }
    }

    /// Why `start` refuses the user manager's environment (a `systemctl --user show-environment` text), or nil (ST-D2):
    /// each name outside `NodeFacts.expectedManagerEnvironment` but those the unit unsets for a desktop session
    /// (`NodeUnit.unsetFromManager`), and how to clear it.
    ///
    /// S2 runs it twice: in the facts (ST-D5 step 3), and again on a fresh `show-environment` after its own
    /// `daemon-reload` and right before `start` (step 10). A `daemon-reload` re-reads `user.conf`'s
    /// `DefaultEnvironment=` and runs the `environment.d` generators again, so a name written there after step 3
    /// shows only then (the review of S1). A `set-environment` between that read and `start` is still a race only the
    /// host started with `--node` can close, by checking its own environment.
    public static func managerRefusal(showEnvironment text: String) -> StartRefusal? {
        let names = NodeFacts.extraVariables(showEnvironment: text).filter { !NodeUnit.unsetFromManager.contains($0) }
        guard !names.isEmpty else { return nil }
        return StartRefusal("the user manager's environment holds what start doesn't expect: \(names.map { ConfigSeal.inert($0, limit: .max) }.joined(separator: ", ")). The manager gives these to what it starts, and the host runs git; clear each with `systemctl --user unset-environment NAME`, and look in ~/.config/environment.d for what set it")
    }

    /// Why `start` refuses the user manager's own configuration in the home, or nil: `<home>/.config/systemd/user.conf`
    /// or a `user.conf.d/*.conf` there that sets `DefaultEnvironment=` (given to every unit) or `ManagerEnvironment=`
    /// (the manager's own, which its generators read), naming the file and the key. Any worker can write these, and
    /// the manager applies them at the next `daemon-reload` or login, past what `show-environment` said before
    /// (the review of S1). An empty assignment (a reset) and a commented line are taken.
    public static func managerConfigRefusal(accountHome: String) -> StartRefusal? {
        let systemd = join(accountHome, ".config/systemd")
        let dropIns = join(systemd, "user.conf.d")
        let files = [join(systemd, "user.conf")] + ((try? FileManager.default.contentsOfDirectory(atPath: dropIns)) ?? [])
            .filter { $0.hasSuffix(".conf") }.sorted().map { join(dropIns, $0) }
        for file in files {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            let unit = NodeUnit.parse(text)
            for key in ["DefaultEnvironment", "ManagerEnvironment"] where (unit[key] ?? []).contains(where: { !$0.isEmpty }) {
                return StartRefusal("\(ConfigSeal.inert(file, limit: .max)) sets \(key)=, which the user manager gives to what it starts at its next daemon-reload or login, past start's check of its environment; remove that line (and run `systemctl --user daemon-reload`)")
            }
        }
        return nil
    }

    // MARK: - Helpers

    /// Why `path`, the unit's `label` folder, isn't one it takes, or nil: absolute with no `.` or `..`, not under
    /// `/mnt/`, inside `home`; it and every folder above it up to `home` a folder (not a link), owned by `uid`,
    /// writable by neither group nor others.
    static func folderRefusal(_ path: String, label: String, home: String, uid: uid_t, status: (String) -> Platform.Tools.FileStatus?) -> StartRefusal? {
        let named = "the \(label) \(ConfigSeal.inert(path, limit: .max))"
        if let why = NodeUnit.pathRefusal(path) { return StartRefusal("\(named): \(why)") }
        let top = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
        guard path == top || path.hasPrefix(top + "/") else { return StartRefusal("\(named) isn't in the home \(ConfigSeal.inert(top, limit: .max))") }
        var folder = path
        while true {
            let shown = ConfigSeal.inert(folder, limit: .max)
            guard let found = status(folder) else {
                return StartRefusal(folder == path ? "\(named) is missing" : "\(named): \(shown) can't be read")
            }
            guard found.mode & S_IFMT == S_IFDIR else { return StartRefusal("\(named): \(shown) isn't a folder (a link isn't taken)") }
            guard found.owner == uid else { return StartRefusal("\(named): \(shown) is owned by uid \(found.owner), not yours (\(uid))") }
            guard found.mode & (S_IWGRP | S_IWOTH) == 0 else { return StartRefusal("\(named): \(shown) is writable by its group or others") }
            if folder == top { return nil }
            folder = (folder as NSString).deletingLastPathComponent
        }
    }

    /// `vX`, `vX.Y` or `vX.Y.Z`, digits only: nvm's version folders' names.
    static func isVersion(_ name: String) -> Bool {
        guard name.hasPrefix("v") else { return false }
        let parts = name.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.count <= 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    /// `path` resolved with `realpath`, or nil.
    static func resolved(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    /// `name` (a relative path) inside `folder`.
    static func join(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }
}
