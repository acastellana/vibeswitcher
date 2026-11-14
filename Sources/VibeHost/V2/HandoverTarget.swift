import Foundation
import VibeCore

/// The handover's target in the user's host (the stage 2 plan's Task 9d, S2-D7, S2-D8; the security architecture
/// document's S8 and S9, threat T17): with an install root (`HostServer.Config.installRoot`: `~/.vibeswitcher/v2/builds`
/// for the node's host, a scratch host's `--install-root` in tests), a host hands over only to an installed build it
/// checked, on the sealed copy that is then probed and run (`HostServer.handOverThroughMemory`), so there is no gap
/// between the check and the use:
///
/// - **Not a script.** The copy's first bytes aren't `\x7fELF` (`SealedCopy.isScript`): refused by name. A script's
///   interpreter reads it by path, which is a file a worker can change.
/// - **Not inside a git worktree**, nor a **session's working folder**: refused by name, the folder named. A worktree is
///   a folder holding `.git` (a folder, or a worktree's file), looked for from the target's folder up to the install
///   folder (included) for a target inside it, and up to `/` for one outside; a session's folder only when it doesn't
///   strictly hold the install folder (a shell in the home holds every installed build). A session working in the
///   install folder itself refuses every build there: it could have staged any of them.
/// - **Inside the install folder**, as `<install folder>/<build>/bin/vibeswitcher-host`, both resolved (`realpath`), so
///   a link inside the install folder to a build elsewhere is refused as elsewhere.
/// - **Recorded**: that build's `build-info` (`BuildInfo`, a newer format refused) records the SHA-256 of the copy's
///   own bytes as `vibeswitcher-host`.
///
/// On success the same build's `vibeswitcher-server` is loaded into a sealed copy and checked against the same record
/// (`server(of:)`), when the host runs a server child; it travels in `State.images.server`, and the new image starts
/// its server child again from it once idle (`ServerChild`).
///
/// Scratch hosts have no install root and hand over as before (from their own sealed copies, Task 9c). The Mac: none of
/// it (`installRoot` is nil there, and `HostServer.handOver(to:)` keeps its by-path handover).
public enum HandoverTarget {
    /// A scratch host's install folder (test-only: the user's host refuses it, `HostHardening.testFlags`).
    public static let installRootFlag = "--install-root"
    /// Where the node's builds are installed, under the account's own home.
    public static let nodeInstallFolder = ".vibeswitcher/v2/builds"

    /// Why a target was refused.
    public struct Refused: Error, Equatable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// A target that passed: its build's record and folder (`<install folder>/<build>`, resolved).
    public struct Build: Equatable {
        public var info: BuildInfo
        public var folder: String

        /// The build's own image of `name`: `<folder>/bin/<name>`.
        public func binary(_ name: String) -> String { folder + "/bin/" + name }
    }

    /// The install root of a host started with `arguments` (Linux): the account's own `~/.vibeswitcher/v2/builds` for the
    /// node's host (`--node`, `accountHome` from the user database), else a scratch host's `--install-root` (never the
    /// user's host's: `ownsLaunchers` refuses the flag). Nil otherwise, and on the Mac.
    public static func installRoot(arguments: [String], ownsLaunchers: Bool, accountHome: String?) -> URL? {
        guard !Platform.CodeIdentity.isAvailable else { return nil }
        if arguments.contains(HostImages.nodeFlag) {
            return accountHome.map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(nodeInstallFolder, isDirectory: true) }
        }
        guard !ownsLaunchers, let root = HostImages.value(after: installRootFlag, in: arguments), root.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: root, isDirectory: true)
    }

    /// Whether `copy`, loaded from `path`, is an installed build's host image under `installRoot` (the rules above):
    /// its build, or why not. `sessionFolders`: the working folders of the host's sessions.
    public static func check(_ copy: Platform.ProcessSelf.SealedCopy, path: String, installRoot: String,
                             sessionFolders: [String] = []) -> Result<Build, Refused> {
        if copy.isScript { return .failure(Refused("\(path) is a script, not an installed build's image")) }
        guard let resolved = realPath(path) else { return .failure(Refused("\(path) can't be resolved")) }
        guard let root = realPath(installRoot) else { return .failure(Refused("the install folder \(installRoot) isn't there")) }
        let inside = isInside(resolved, root)
        if let worktree = worktree(holding: resolved, upTo: inside ? root : "/") {
            return .failure(Refused("\(path) is inside a git worktree (\(worktree))"))
        }
        for given in sessionFolders {
            let folder = realPath(given) ?? (given as NSString).standardizingPath
            guard folder != "/", !isInside(root, folder), isInside(resolved, folder) else { continue }
            return .failure(Refused("\(path) is inside a session's working folder (\(folder))"))
        }
        guard inside else { return .failure(Refused("\(path) isn't inside the install folder (\(root))")) }
        let parts = resolved.dropFirst(root.count + 1).split(separator: "/").map(String.init)
        guard parts.count == 3, parts[1] == "bin", parts[2] == BuildInfo.host else {
            return .failure(Refused("\(path) isn't an installed build's \(BuildInfo.host) (\(root)/<build>/bin/\(BuildInfo.host))"))
        }
        let folder = root + "/" + parts[0]
        let info: BuildInfo
        switch BuildInfo.read(buildFolder: folder) {
        case .success(let read): info = read
        case .failure(let why): return .failure(Refused("its build-info: \(why.description)"))
        }
        if let mismatch = info.mismatch(of: copy, as: BuildInfo.host) { return .failure(Refused(mismatch)) }
        return .success(Build(info: info, folder: folder))
    }

    /// `build`'s `vibeswitcher-server`, loaded into a sealed copy and checked against the same `build-info`: the copy,
    /// or why not (nothing left open).
    public static func server(of build: Build) -> Result<Platform.ProcessSelf.SealedCopy, Refused> {
        let path = build.binary(BuildInfo.server)
        switch Platform.ProcessSelf.sealedCopy(of: path, name: BuildInfo.server) {
        case .failure(let error):
            return .failure(Refused("\(BuildInfo.server): \(path) couldn't be loaded into a sealed copy (\(String(cString: strerror(error.code))))"))
        case .success(let copy):
            if copy.isScript {
                Sys.close(copy.fd)
                return .failure(Refused("\(BuildInfo.server): \(path) is a script, not an installed build's image"))
            }
            if let mismatch = build.info.mismatch(of: copy, as: BuildInfo.server) {
                Sys.close(copy.fd)
                return .failure(Refused(mismatch))
            }
            return .success(copy)
        }
    }

    /// The nearest folder holding `.git` from `path`'s folder up to `ceiling` (included), or nil.
    static func worktree(holding path: String, upTo ceiling: String) -> String? {
        var folder = (path as NSString).deletingLastPathComponent
        while true {
            var info = stat()
            if lstat((folder as NSString).appendingPathComponent(".git"), &info) == 0 { return folder }
            guard folder != ceiling, folder != "/", !folder.isEmpty else { return nil }
            folder = (folder as NSString).deletingLastPathComponent
        }
    }

    /// Whether `path` is strictly inside `folder` (both resolved).
    static func isInside(_ path: String, _ folder: String) -> Bool {
        folder == "/" ? path != "/" : path.hasPrefix(folder + "/")
    }

    /// `path` resolved (`realpath`), or nil when it can't be.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
