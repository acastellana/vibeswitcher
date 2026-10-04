import CryptoKit
import Foundation

/// Which session a request means. A tty outlives its session: when an agent exits, the tab (or later a
/// new tab reusing the same ttysNNN) can hold another one. The agent process — its pid and start time —
/// is the session.
public enum SessionIdentity {
    public static func id(tty: String, pid: Int32, startedAt: Date) -> String {
        let key = "\(tty)|\(pid)|\(Int64((startedAt.timeIntervalSince1970 * 1000).rounded()))"
        return Base64URL.encode(Data(SHA256.hash(data: Data(key.utf8))).prefix(12))
    }

    /// Whether that agent process is still the one running (a pid can be reused by a later process).
    public static func isRunning(pid: Int32, startedAt: Date) -> Bool {
        guard let info = ProcessTable.info(pid: pid) else { return false }
        return abs(info.startTime.timeIntervalSince(startedAt)) < 1
    }
}
