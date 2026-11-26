import Foundation
import VibeCore

/// What a checked Mac node's sessions are given back of a user's environment (the node on the Mac's design, "The
/// LaunchAgent", "Sessions' environment"): the checked start resets the host's own environment to a fixed list, umask
/// 077 and no core files, so its sessions would lose what a Terminal session has from launchd. The session's own login
/// shell (`$SHELL -l -i`) builds `PATH` and what the user's startup files export; the host gives each session's spawn,
/// and not its server child, what launchd gives a Terminal and no shell sets, from launchd and the user's files, never
/// from its starter.
public struct CheckedSessions: Equatable, Sendable {
    /// Added to each session's environment on its spawn.
    public var environment: [String: String]
    /// The session's program's umask, set by its launcher.
    public var umask: mode_t

    public init(environment: [String: String], umask: mode_t) {
        self.environment = environment
        self.umask = umask
    }

    // MARK: A scratch host shaped as a checked node (tests)

    /// A scratch host's test flag: it resets itself as a checked node does (`HostImages.checkedNodeEnvironment`,
    /// `Platform.NodeReset.processState`), `HOME` the folder after it in place of the user database's, and its sessions
    /// are given what a checked node's are. Refused for the user's host, a `--node` host and a host on the node's lock;
    /// not in a checked node's grammar.
    public static let testShapeFlag = "--test-checked-shape"

    /// `main`'s step for `testShapeFlag` in `arguments`, before it reads its environment: nil without the flag (nothing
    /// done); else the scratch home it reset itself for, or why it may not start. `lock` is the host's `--lock`, which
    /// must be given and be neither the user's host's (`usersLock`) nor the node's (`HostImages.isNodeLock`).
    public static func takeTestShape(arguments: [String], isMacNode: Bool, lock: String?, usersLock: String) -> Result<String, HostImages.Refused>? {
        guard let index = arguments.firstIndex(of: testShapeFlag) else { return nil }
        guard Platform.CodeIdentity.isAvailable, !isMacNode else { return .failure(HostImages.Refused("\(testShapeFlag) is a Mac scratch host's only")) }
        guard arguments.indices.contains(index + 1), case let home = arguments[index + 1], home.hasPrefix("/") else {
            return .failure(HostImages.Refused("\(testShapeFlag) needs an absolute scratch home after it"))
        }
        guard let lock, !isSameLock(lock, usersLock), !HostImages.isNodeLock(lock, accountHome: HostImages.accountHome) else {
            return .failure(HostImages.Refused("\(testShapeFlag) is a scratch host's only: give it its own --lock"))
        }
        let given = ProcessInfo.processInfo.environment
        let wanted = HostImages.checkedNodeEnvironment(HostImages.nodeEnvironment(given, accountHome: home, accountName: HostImages.accountName,
                                                                                  shell: HostImages.accountShell))
        for name in Set(given.keys).union(wanted.keys) where given[name] != wanted[name] {
            if let value = wanted[name] { setenv(name, value, 1) } else { unsetenv(name) }
        }
        if let why = Platform.NodeReset.processState(keeping: []) { return .failure(HostImages.Refused(why)) }
        return .success(home)
    }

    /// Whether `lock` is `other` by file, or may become it: a link (dangling or not) always; the same device and inode
    /// when both are there; else the same folder by device and inode and the same name; the same text always.
    static func isSameLock(_ lock: String, _ other: String) -> Bool {
        if lock == other { return true }
        // A link is refused as the user's (the re-check's note 5): the host opens `--lock` with no link followed, and a
        // link to the user's lock before it exists would be it once made.
        var link = stat()
        if lstat(lock, &link) == 0, link.st_mode & S_IFMT == S_IFLNK { return true }
        var a = stat(), b = stat()
        if stat(lock, &a) == 0, stat(other, &b) == 0 { return a.st_dev == b.st_dev && a.st_ino == b.st_ino }
        guard (lock as NSString).lastPathComponent == (other as NSString).lastPathComponent,
              stat((lock as NSString).deletingLastPathComponent, &a) == 0, stat((other as NSString).deletingLastPathComponent, &b) == 0 else { return false }
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }

    /// What a checked node's sessions are given, read once at the host's start: `SSH_AUTH_SOCK` launchd's own for the
    /// user's domain (`launchctl getenv`, `variable`), taken only when it is an absolute path to a socket `uid` owns, no
    /// link (`socketOwner`); `__CF_USER_TEXT_ENCODING` as launchd gives it, from `<accountHome>/.CFUserTextEncoding`
    /// (`file`); the umask 022. Never a value of this process's environment (its starter's, which the reset dropped).
    public static func read(uid: uid_t, accountHome: String,
                            variable: (String) -> String? = launchdVariable,
                            socketOwner: (String) -> uid_t? = socketOwner,
                            file: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> CheckedSessions {
        var environment: [String: String] = [:]
        if let socket = variable("SSH_AUTH_SOCK"), socket.hasPrefix("/"), !socket.contains("\n"), socketOwner(socket) == uid {
            environment["SSH_AUTH_SOCK"] = socket
        }
        environment["__CF_USER_TEXT_ENCODING"] = textEncoding(uid: uid, file: file((accountHome as NSString).appendingPathComponent(".CFUserTextEncoding")))
        return CheckedSessions(environment: environment, umask: 0o022)
    }

    /// launchd's value of `name` for the user's domain (`/bin/launchctl getenv NAME`, `Platform.Service.launchctl`),
    /// nil without one or without launchctl.
    public static func launchdVariable(_ name: String) -> String? {
        guard let launchctl = Platform.Service.launchctl, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return nil }
        let out = Platform.pipeCommand("'\(launchctl)' getenv \(name)", input: Data(), patience: 5, stopSignals: [])
        let text = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The owner of the socket at `path`, nil when it isn't one (a link isn't followed).
    public static func socketOwner(_ path: String) -> uid_t? {
        var status = stat()
        guard lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFSOCK else { return nil }
        return status.st_uid
    }

    /// `0x<uid>:<encoding>:<region>`, as launchd gives `__CF_USER_TEXT_ENCODING`: the two numbers of the user's
    /// `.CFUserTextEncoding` (hex with `0x`, or decimal), `0x0:0x0` without a readable one.
    public static func textEncoding(uid: uid_t, file: String?) -> String {
        func number(_ text: Substring) -> UInt32? {
            text.hasPrefix("0x") ? UInt32(text.dropFirst(2), radix: 16) : UInt32(text)
        }
        let parts = (file ?? "").trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        let numbers = parts.count == 2 ? parts.compactMap(number) : []
        let (encoding, region) = numbers.count == 2 ? (numbers[0], numbers[1]) : (0, 0)
        return String(format: "0x%X:0x%X:0x%X", uid, encoding, region)
    }
}
