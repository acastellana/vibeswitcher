import Foundation
import VibeCore

/// The record of a node started detached (the start plan's ST-D6), `<root>/v2/node.pid`: format 1 JSON holding the
/// host's `pid` and its `startTicks` (`Platform.Processes.link`), so a later reader tells the host from a process
/// that was given its number since. Written 0600 through a temporary file opened with `O_NOFOLLOW` and renamed in, and
/// read with `O_NOFOLLOW`; any process of the user's (a worker's too) can still write it, which `status` says (the
/// weaker voice rule), so a reader checks what it names (`NodeCheck.recordedHost`) before it trusts or signals it.
public struct NodeRecord: Codable, Equatable, Sendable {
    /// The record's format: 1.
    public var format: Int
    public var pid: Int32
    /// When the process started, in the system's clock ticks since boot (`/proc/<pid>/stat`'s field 22).
    public var startTicks: UInt64

    public init(pid: Int32, startTicks: UInt64) {
        format = 1
        self.pid = pid
        self.startTicks = startTicks
    }

    /// The largest record read: a few dozen bytes are written.
    static let readLimit = 4096

    /// `<root>/v2/node.pid`.
    public static func path(root: String) -> String { NodeFolders.join(root, "v2/node.pid") }

    /// The record in `root`, or nil: none, a link, not a regular file, too long, or not format 1 with a pid above 0.
    public static func read(root: String) -> NodeRecord? {
        let fd = Sys.open(path(root: root), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Sys.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= readLimit else { return nil }
        var bytes = [UInt8](repeating: 0, count: readLimit + 1)
        var count = 0
        while count < bytes.count {
            let got = bytes.withUnsafeMutableBytes { Sys.read(fd, $0.baseAddress! + count, $0.count - count) }
            if got < 0, errno == EINTR { continue }
            guard got > 0 else { break }
            count += got
        }
        guard count <= readLimit, let record = try? JSONDecoder().decode(NodeRecord.self, from: Data(bytes[0..<count])),
              record.format == 1, record.pid > 0 else { return nil }
        return record
    }

    /// Writes this record to `root` (its `v2/` made private first): a temporary file beside it, opened with `O_EXCL`
    /// and `O_NOFOLLOW`, 0600, then renamed over `node.pid` (a link there is replaced, never followed).
    public func write(root: String) throws {
        try VibePaths.ensurePrivate(URL(fileURLWithPath: NodeFolders.join(root, "v2"), isDirectory: true))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = Array(try encoder.encode(self)) + [UInt8(ascii: "\n")]
        let target = Self.path(root: root)
        let temporary = NodeFolders.join(root, "v2/.node.pid.\(getpid()).\(UUID().uuidString.prefix(8)).tmp")
        let fd = Sys.open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Platform.Errno(code: errno) }
        var failed: Int32 = 0
        if fchmod(fd, 0o600) != 0 { failed = errno }
        var done = 0
        while failed == 0, done < bytes.count {
            let wrote = bytes.withUnsafeBytes { Sys.write(fd, $0.baseAddress! + done, bytes.count - done) }
            if wrote < 0, errno == EINTR { continue }
            guard wrote > 0 else { failed = wrote < 0 ? errno : EIO; break }
            done += wrote
        }
        if failed == 0, fsync(fd) != 0 { failed = errno }
        Sys.close(fd)
        if failed == 0, rename(temporary, target) != 0 { failed = errno }
        guard failed == 0 else {
            unlink(temporary)
            throw Platform.Errno(code: failed)
        }
    }

    /// Removes `root`'s record when it is still `record` (a start since may have written another).
    public static func remove(root: String, ifStill record: NodeRecord) {
        guard read(root: root) == record else { return }
        unlink(path(root: root))
    }

    /// When the process `pid` started (`Platform.Processes.link`), nil when it has gone or is a zombie (ended, its
    /// parent not yet told). The Mac: its start in microseconds since 1970 (`proc_pidinfo`), compared only with its own.
    public static func liveTicks(_ pid: pid_t) -> UInt64? {
        guard pid > 0, let link = Platform.Processes.link(pid), Platform.Processes.kernelRecord(pid)?.state != .zombie else { return nil }
        return link.startTicks
    }

    /// Whether the recorded process still runs: its pid, started at the recorded tick, and not a zombie.
    public func isLive() -> Bool { Self.liveTicks(pid) == startTicks }

    /// Whether the recorded process has ended, collecting it when it is this process's child (the command line that
    /// started it, or a test): such a child counts as ended only once it is collected, so none is left a zombie. A
    /// multithreaded host's main thread shows as a zombie while its other threads still exit, and can't be collected
    /// yet then (`waitpid` says 0): that isn't ended (seen under load, the review of S3). Any other process: once it no
    /// longer runs from its recorded start.
    public func hasEnded() -> Bool {
        var status: Int32 = 0
        while true {
            let reaped = waitpid(pid, &status, WNOHANG)
            if reaped == pid { return true }
            if reaped == 0 { return false }
            if errno == EINTR { continue }
            return !isLive()
        }
    }
}
