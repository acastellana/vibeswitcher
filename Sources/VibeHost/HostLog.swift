import Darwin
import Foundation
import VibeCore

/// The host's session log (`~/.vibeswitcher/debug/host.log`): each session started and how it ended, each kill and
/// shutdown, with the client that asked. Each line is written at once (the host may be killed next); it keeps about
/// `maxBytes` and one older file (`.1`). Any thread.
final class HostLog: @unchecked Sendable {
    private let path: String?
    private let maxBytes: Int
    private let lock = NSLock()
    private let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// `path` nil: logs nothing.
    init(path: String?, maxBytes: Int = 1_000_000) {
        self.path = path
        self.maxBytes = maxBytes
    }

    func note(_ text: String) {
        guard let path else { return }
        lock.lock()
        defer { lock.unlock() }
        let line = Data("\(stamp.string(from: Date())) [\(getpid())] \(Redaction.secrets(in: text))\n".utf8)
        let folder = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        if stat(path, &info) == 0, Int(info.st_size) + line.count > maxBytes { rename(path, path + ".1") }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        Darwin.close(fd)
    }

    /// "peer pid 4242 (vibeswitcher-mcp)": the process on the other end of a client's connection.
    static func peer(_ pid: pid_t?) -> String {
        guard let pid else { return "peer pid unknown" }
        return "peer pid \(pid)" + (ProcessTable.info(pid: pid).map { " (\($0.comm))" } ?? "")
    }

    /// "wait status 0x000f, signal 15 (SIGTERM), no core" or "wait status 0x8f00, exit code 143".
    static func waitStatus(_ status: Int32) -> String {
        let raw = "wait status " + String(format: "0x%04x", status)
        let signal = status & 0x7f
        guard signal != 0 else { return "\(raw), exit code \((status >> 8) & 0xff)" }
        return "\(raw), signal \(signal) (\(HostSession.Exit.signalName(signal))), \(status & 0x80 != 0 ? "core dumped" : "no core")"
    }
}
