import Foundation

/// The tool server's build on Linux (the start plan's S5): an installed build is `<prefix>/<commit>/bin/<program>` with
/// `<prefix>/<commit>/build-info` beside its `bin/` (`BuildInfo`, the install's record), so a merge receipt and the gate
/// (`LeadToolset.gateLag`) name the build that runs, as the Mac's app bundle names its own (`ServerBuild.read`, whose
/// one hook calls `read(executable:)` where there is no app bundle and `Platform.CodeIdentity.isAvailable` is false).
public enum ServerBuildLinux {
    /// What the gate's refusal asks the user to do on Linux (`GateLag.refusal`, the Mac's `scripts/build-app.sh
    /// --install`): an install of the base's head, then the switch to it, which is the user's (D14).
    public static let installHint = "install it with ~/.vibeswitcher/v2/builds/current/Resources/install-node.sh COMMIT, then vs switch COMMIT"

    /// The build of the executable at `path`: the path resolved (`realpath`: `current/bin/x` names the build's own
    /// folder), then the `build-info` two folders up from it (`<c>/bin/x` → `<c>/build-info`), whose commit it is.
    /// `changed` is whether the executable's SHA-256 isn't its `binaries` entry (another file, or none recorded for its
    /// name), so the gate fails closed on a build it can't vouch for. `builtAt` is nil: an installed build is named by
    /// its commit, never by a date. Nil when the executable or its `build-info` can't be read.
    public static func read(executable path: String) -> ServerBuild? {
        guard let resolved = realpath(path, nil) else { return nil }
        let real = String(cString: resolved)
        free(resolved)
        let bin = (real as NSString).deletingLastPathComponent
        guard (bin as NSString).lastPathComponent == "bin",
              case .success(let info) = BuildInfo.read(buildFolder: (bin as NSString).deletingLastPathComponent),
              let bytes = FileManager.default.contents(atPath: real) else { return nil }
        let recorded = info.binaries[(real as NSString).lastPathComponent]
        return ServerBuild(commit: info.commit, changed: recorded != BuildInfo.sha256(of: bytes), builtAt: nil)
    }
}
