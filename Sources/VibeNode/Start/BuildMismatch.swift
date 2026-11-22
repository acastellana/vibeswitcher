import Foundation
import VibeCore

/// The command line and the server it reached are different builds (the architecture review's row 11, 2026-11-22):
/// right after a switch, or when an installed command line meets a server still on the build before, a new option
/// the server doesn't take is refused (`RequestArguments`) and a renamed field reads as missing. The command line
/// says so once, on stderr, so the user knows to restart or switch.
public enum BuildMismatch {
    /// The commit of the installed build `executable` (`/proc/self/exe`) runs from: `<build>/bin/<name>` with
    /// `<build>/build-info.json` naming it (`BuildInfo`). nil for a development build, which names none.
    public static func own(executable: String) -> String? {
        guard let program = NodeFolders.resolved(executable) else { return nil }
        let bin = (program as NSString).deletingLastPathComponent
        guard (bin as NSString).lastPathComponent == "bin" else { return nil }
        guard case .success(let info) = BuildInfo.read(buildFolder: (bin as NSString).deletingLastPathComponent) else { return nil }
        return info.commit
    }

    /// What the command line says when the server (its hello's `server.commit`) runs another build than its own; nil
    /// when they are the same, or either isn't known (a development build; a server that says `unknown`).
    public static func warning(own: String?, server: String) -> String? {
        guard let own, NodeUnit.isCommit(own), NodeUnit.isCommit(server), own != server else { return nil }
        return "the server runs build \(server.prefix(12)), this command line \(own.prefix(12)): restart the node or switch "
            + "(`vibeswitcher switch \(own)`) to use this command's new options"
    }
}
