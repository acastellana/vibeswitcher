import Foundation
import VibeCore

/// A detached host's stdout and stderr are appended to `<root>/v2/host.log` (`NodeStarter.startDetached`), which its
/// server child inherits: nothing else would ever cap it. The detached start names that file to the host
/// (`logVariable`); every minute, and once at its start, the host empties it past `Platform.Stdio.logLimit`, keeping one
/// older copy (`Platform.Stdio.capError`), while its stderr is that file. A host started any other way (the unit, whose
/// stderr is the journal's socket; a test's, writing to its own file; a user's own `2>>file`) is never touched.
public enum StderrCap {
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?

    /// The variable the detached start names the log in (`NodeStarter.detachedEnvironment`).
    public static let logVariable = "VIBESWITCHER_HOST_LOG"

    /// Starts the minute's check (once per process), when the detached start named the log.
    public static func start(every interval: TimeInterval = 60, limit: Int = Platform.Stdio.logLimit) {
        guard timer == nil, let path = getenv(logVariable).map({ String(cString: $0) }), path.hasPrefix("/") else { return }
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.schedule(deadline: .now(), repeating: interval)
        source.setEventHandler { Platform.Stdio.capError(path: path, limit: limit) }
        source.resume()
        timer = source
    }
}
