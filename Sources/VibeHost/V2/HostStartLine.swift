import Foundation
import VibeCore

/// The host names its build (the start plan's S5): the `build-info` its start checked (`HostImages.load`, with
/// `--node-root`), kept here once both images matched it, for its notes (`HostNotes.build` and `binaries`, which
/// `hooks.install` checks the build's programs against, ST-D17) and for its start line, which it writes to stderr on
/// Linux once its start checks passed (one hook line in `main`):
///
///     vibeswitcher-host: started pid <pid> build <commit|unknown> SWIFT_BACKTRACE=<value|unset>
///
/// Under the node's unit stderr is the journal's (`_TRANSPORT=stdout`), and the command line takes the line as the
/// start's detail only when journald's `_PID` is the unit's `ExecMainPID` (`NodeJournal.events`, ST-D24): every session
/// is in the unit's cgroup, so a session's `logger` lands under the unit too. A handover's new image keeps the pid and
/// says its own line, with its own build. The Mac: nothing said, nothing kept.
public enum HostStartLine {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var checked: BuildInfo?

    /// The commit of the `build-info` the host's start checked; nil without one (no `--node-root`, the Mac).
    public static var commit: String? { lock.withLock { checked?.commit } }
    /// That record's `binaries`: each program of the build by name, its SHA-256.
    public static var binaries: [String: String]? { lock.withLock { checked?.binaries } }

    /// `info`, as `HostImages.load` checked both images against it.
    static func record(_ info: BuildInfo) {
        lock.withLock { checked = info }
    }

    /// The line, for `pid`, `commit` and the `SWIFT_BACKTRACE` value (nil: unset). The value is the environment's, so
    /// it is made inert (`ConfigSeal.inert`): no control character reaches the journal from it.
    public static func text(pid: pid_t, commit: String?, backtrace: String?) -> String {
        "vibeswitcher-host: started pid \(pid) build \(commit ?? "unknown") SWIFT_BACKTRACE="
            + (backtrace.map { ConfigSeal.inert($0, limit: 200) } ?? "unset")
    }

    /// Writes the line to stderr on Linux; on the Mac nothing.
    public static func say() {
        guard !Platform.CodeIdentity.isAvailable else { return }
        let backtrace = getenv("SWIFT_BACKTRACE").map { String(cString: $0) }
        Platform.Stdio.error(text(pid: getpid(), commit: commit, backtrace: backtrace) + "\n")
    }
}
