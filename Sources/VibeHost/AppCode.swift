import Foundation
import VibeCore

/// Whether a process runs the app's code, told by its code signature and not by its path: a process can exec the
/// app's binary under a pid that connected as something else, and a path says nothing of what was loaded from it.
/// Builds are ad-hoc signed (no team), so the identity is the code directory hash. The checks are the platform's
/// (`Platform.CodeIdentity`; on Linux there are none, and `runs` is false).
enum AppCode {
    /// The process `token` names, as it runs now (Security refuses a token whose pid exec'd since), is valid code
    /// whose cdhash is the one of the code at `executable`.
    static func runs(_ token: Platform.PeerToken, executable: String) -> Bool {
        Platform.CodeIdentity.runs(token, executable: executable)
    }

    /// The CPU type and subtype a process runs.
    typealias Architecture = Platform.CodeIdentity.Architecture

    /// The architecture the process `pid` runs (the slice of a universal binary it was started from).
    static func architecture(of pid: pid_t) -> Architecture? { Platform.CodeIdentity.architecture(of: pid) }

    /// The cdhash of the code on disk at `path` (for a universal binary, this machine's architecture).
    static func cdhash(atPath path: String, architecture: Architecture? = nil) -> Data? {
        Platform.CodeIdentity.cdhash(atPath: path, architecture: architecture)
    }
}
