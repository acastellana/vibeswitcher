import Foundation

/// The tool server's build on Linux (the start plan's S5): an installed build is `<prefix>/<commit>/bin/<program>` with
/// `<prefix>/<commit>/build-info` beside its `bin/` (`BuildInfo`, the install's record), so a merge receipt and the gate
/// (`LeadToolset.gateLag`) name the build that runs, as the Mac's app bundle names its own (`ServerBuild.read`, whose
/// one hook calls `read(executable:)` where there is no app bundle and `Platform.CodeIdentity.isAvailable` is false).
public enum ServerBuildLinux {
    /// What the gate's refusal asks the user to do on Linux (`GateLag.refusal`, the Mac's `scripts/build-app.sh
    /// --install`): an install of the base's head, then the switch to it, which is the user's (D14).
    public static let installHint = "`vibeswitcher update COMMIT` installs it and switches to it, with one code"

    /// The build of the executable at `path`: the path resolved (`realpath`: `current/bin/x` names the build's own
    /// folder), then the `build-info` two folders up from it (`<c>/bin/x` → `<c>/build-info`), whose commit it is.
    /// `changed` is whether that record doesn't vouch for the program, so the gate fails closed on a build it can't
    /// vouch for, with `changedWhy` saying why: the program's SHA-256 isn't its `binaries` entry (another file, or none
    /// recorded for its name), or the record's commit isn't its folder's name (`NodeFolders.verifyBuild`'s rule: a
    /// record whose `commit` alone was rewritten names another build). The bytes hashed are the running image's when
    /// `path` is this process's own executable (`image(of:)`). `builtAt` is nil: an installed build is named by its
    /// commit, never by a date. Nil when the executable or its `build-info` can't be read.
    public static func read(executable path: String) -> ServerBuild? { read(executable: path, image: nil) }

    /// The running image: the file this process was started from, even once another is renamed over its path.
    static let selfImage = "/proc/self/exe"

    /// What to read `real`'s bytes from: `selfImage` when `real` is the path this process was started from (the
    /// kernel's name for it, " (deleted)" after it once the file is replaced), so the bytes hashed are what runs, not
    /// what was put at the path since (the review of S5); `real` itself otherwise, and where there is no `/proc`.
    static func image(of real: String) -> String {
        guard let own = try? FileManager.default.destinationOfSymbolicLink(atPath: selfImage) else { return real }
        let deleted = " (deleted)"
        return (own.hasSuffix(deleted) ? String(own.dropLast(deleted.count)) : own) == real ? selfImage : real
    }

    /// `read(executable:)`, its bytes read from `image` (a test's), else from `image(of:)`.
    static func read(executable path: String, image: String?) -> ServerBuild? {
        guard let resolved = realpath(path, nil) else { return nil }
        let real = String(cString: resolved)
        free(resolved)
        let bin = (real as NSString).deletingLastPathComponent
        let folder = (bin as NSString).deletingLastPathComponent
        guard (bin as NSString).lastPathComponent == "bin", case .success(let info) = BuildInfo.read(buildFolder: folder),
              let bytes = FileManager.default.contents(atPath: image ?? Self.image(of: real)) else { return nil }
        let name = (real as NSString).lastPathComponent
        let commit = String(info.commit.prefix(12))
        let why: String?
        if ServerBuild.validCommit((folder as NSString).lastPathComponent) != info.commit {
            why = "its build-info names commit \(commit), not its folder's name"
        } else if let recorded = info.binaries[name] {
            why = recorded == BuildInfo.sha256(of: bytes) ? nil : "its program's SHA-256 isn't the one \(commit)'s build-info records for \(name)"
        } else {
            why = "\(commit)'s build-info records no \(name)"
        }
        return ServerBuild(commit: info.commit, changed: why != nil, builtAt: nil, changedWhy: why)
    }
}
