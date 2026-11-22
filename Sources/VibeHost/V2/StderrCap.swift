import Foundation
import VibeCore

/// A detached host's stdout and stderr are appended to `<root>/v2/host.log` (`NodeStarter.startDetached`), which its
/// server child inherits: nothing else would ever cap it. Every minute, and once at its start, the host empties it
/// past `Platform.Stdio.logLimit`, keeping one older copy (`Platform.Stdio.capError`). Under the unit stderr is the
/// journal's socket and this does nothing.
public enum StderrCap {
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?

    /// Starts the minute's check (once per process).
    public static func start(every interval: TimeInterval = 60, limit: Int = Platform.Stdio.logLimit) {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.schedule(deadline: .now(), repeating: interval)
        source.setEventHandler { Platform.Stdio.capError(limit: limit) }
        source.resume()
        timer = source
    }
}
