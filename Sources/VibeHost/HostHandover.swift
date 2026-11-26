import CryptoKit
import Darwin
import Foundation
import VibeCore

/// A host update that keeps every session: the running host re-executes itself, in place, as the new build.
///
/// Same process, so the sessions' programs stay its children (`waitpid` still reports how they end), and the PTYs, the
/// lock and the listening socket stay open across the exec (they're the descriptors the new image inherits). The rest
/// (each session's info, everything it printed, input not yet written) goes in a state file only this user can read,
/// which the new build reads and deletes; the screens are rebuilt from what each session printed. Clients lose their
/// connection and come back to the same socket. Secrets the host keeps in memory never touch the file: they go through
/// a socket whose reading end the new build inherits (see `SecretChannel`).
///
/// A build that can't take over never replaces the running one: it's run first as a probe that reads the state, and
/// the exec happens only when the probe says it can. If the new build then can't restore after all, it executes the
/// old build's own copy again (`--handover-fallback`), which restores it.
public enum HostHandover {
    /// Bumped whenever `State` changes shape: a build reads only its own.
    public static let format = 1
    /// What the probe prints when it can take over.
    static let probeAnswer = "vibeswitcher-host handover \(format) ok"

    public struct Session: Codable, Equatable {
        public var info: HostSession
        /// Nil: the PTY is closed already.
        public var masterFD: Int32?
        /// What the session printed (the replay): the new build's ring and screen start from it.
        public var output: Data
        public var pendingInput: Data
        /// An ended session's last screen, how it was drawn, and the lines above it (it has no replay any more).
        public var ended: Ended?
        /// The session whose process asked for this one (see `HostServer`'s kill rule); nil: the app or no session.
        public var startedBy: UUID?
        /// The app asked for it: one of the user's (see `HostServer`'s `openedByApp`). Nil from builds before that.
        public var openedByApp: Bool?
        /// Its program asked for focus events (see `FocusEvents`): a program asks once, and the replay seldom still
        /// holds it. Nil from builds before that: read off `output` then.
        public var focusEvents: Bool?

        public struct Ended: Codable, Equatable {
            public var screen: String
            public var runs: [ScreenRun]
            public var history: String
        }

        public init(info: HostSession, masterFD: Int32?, output: Data, pendingInput: Data, ended: Ended? = nil, startedBy: UUID? = nil) {
            self.info = info
            self.startedBy = startedBy
            self.masterFD = masterFD
            self.output = output
            self.pendingInput = pendingInput
            self.ended = ended
        }
    }

    public struct State: Codable, Equatable {
        public var format = HostHandover.format
        public var fromBuild: Int
        /// When the host (this process) first started.
        public var startedAt: Date
        public var lockFD: Int32
        public var listenFD: Int32
        /// The reading end of the secret channel, or nil when there's nothing secret.
        public var secretFD: Int32?
        /// In the order they were started.
        public var sessions: [Session]

        /// Every descriptor the new image must inherit.
        var descriptors: [Int32] { [lockFD, listenFD] + [secretFD].compactMap { $0 } + sessions.compactMap(\.masterFD) }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notExecutable(String)
        case write(Int32)
        case unreadable(String)
        case wrongFormat(Int)
        case badDescriptor(Int32)
        case probe(String)
        case secretTooLarge(Int)
        case exec(Int32)
        /// Not a handover from the running host this one replaces (see `receive`).
        case refused(String)

        public var description: String {
            switch self {
            case .notExecutable(let path): return "\(path) isn't an executable"
            case .write(let error): return "couldn't write the state file: \(String(cString: strerror(error)))"
            case .unreadable(let why): return "couldn't read the state file: \(why)"
            case .wrongFormat(let format): return "the state file is format \(format); this build reads \(HostHandover.format)"
            case .badDescriptor(let fd): return "descriptor \(fd) didn't survive"
            case .probe(let why): return "the new build can't take over: \(why)"
            case .secretTooLarge(let size): return "\(size) bytes of secrets don't fit the channel"
            case .exec(let error): return "couldn't execute the new build: \(String(cString: strerror(error)))"
            case .refused(let why): return "handover refused: \(why)"
            }
        }
    }

    /// Writes `state` to `path`, readable by this user only, replacing what was there. Returns the bytes written (what
    /// a `Proof` covers).
    @discardableResult
    static func write(_ state: State, to path: String) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data: Data
        do { data = try encoder.encode(state) } catch { throw Failure.write(EINVAL) }
        let partial = path + ".partial"
        unlink(partial)
        let fd = open(partial, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.write(errno) }
        var written = 0
        let failure: Int32? = data.withUnsafeBytes { raw in
            while written < raw.count {
                let count = Darwin.write(fd, raw.baseAddress! + written, raw.count - written)
                if count < 0 { if errno == EINTR { continue }; return errno }
                written += count
            }
            return fsync(fd) == 0 ? nil : errno
        }
        Darwin.close(fd)
        if let failure {
            unlink(partial)
            throw Failure.write(failure)
        }
        guard rename(partial, path) == 0 else {
            let error = errno
            unlink(partial)
            throw Failure.write(error)
        }
        return data
    }

    public static func read(from path: String) throws -> State { try decode(contents(of: path)) }

    static func contents(of path: String) throws -> Data {
        do { return try Data(contentsOf: URL(fileURLWithPath: path)) } catch { throw Failure.unreadable(error.localizedDescription) }
    }

    static func decode(_ data: Data) throws -> State {
        // The format first: a state of another shape wouldn't decode, and that should say why.
        struct Header: Decodable { var format: Int }
        guard let header = try? PropertyListDecoder().decode(Header.self, from: data) else { throw Failure.unreadable("not a state file") }
        guard header.format == format else { throw Failure.wrongFormat(header.format) }
        do { return try PropertyListDecoder().decode(State.self, from: data) } catch { throw Failure.unreadable("\(error)") }
    }

    /// What a build started with `--handover` takes over: the state, and the secrets the build before handed over.
    public struct Received {
        public var state: State
        public var secrets: Data?
    }

    /// The argument the build before's proof comes in (see `Proof`).
    public static let proofFlag = "--handover-proof"

    /// `--handover PATH`: the state at `path` and the secrets of its channel, for the host on `lockPath`, taken only
    /// from the running host this process replaces. A handover is this same process re-executed (see `exec`): what it
    /// inherits is the old image's, and nothing else is. Anything else is refused (`Failure.refused`, said in the log
    /// at `logPath`) before the secrets are read, and nothing is written:
    /// - Every host: `state.lockFD` is the lock at `lockPath`, and it's this descriptor that holds it (the kernel's
    ///   answer, not the file's). While a host runs, nothing else holds its lock.
    /// - The user's host with its vault key (`userHost`, `key()`, read only after the lock): `proof` (`--handover-proof`)
    ///   holds under that key for these state bytes, this process (its pid and start time, from the kernel) and this
    ///   lock (see `Proof`), and the channel holds the secrets it names. Only a host holding the Keychain's key makes
    ///   one, and only for its own exec. Without it a process of your account that holds a free lock could hand the
    ///   genuine host a vault of its own to seal under that key.
    /// A keyless host (a scratch host on its own lock, or the user's when the Keychain didn't give the key) keeps its
    /// vault in memory only: it takes the secrets once the lock holds.
    public static func receive(from path: String, lockPath: String, userHost: Bool, proof: String?, logPath: String?,
                               key: () -> SymmetricKey?) throws -> Received {
        let refuse: (String) -> Failure = { why in
            HostLog(path: logPath).note("host: handover refused: \(why)")
            return Failure.refused(why)
        }
        let data = try contents(of: path)
        var state = try decode(data)
        if let why = Lock.notHeld(state.lockFD, path: lockPath) { throw refuse(why) }
        guard userHost, let key = key() else {
            return Received(state: state, secrets: takeSecrets(from: &state))
        }
        guard let proof else { throw refuse("it carries no proof that the running host made it (a build from before proofs, or not the host)") }
        guard let claimed = Proof.Claim(proof), Proof.holds(claimed, key: key, state: data, lockFD: state.lockFD, lockPath: lockPath) else {
            throw refuse("its proof doesn't hold for this state, this process and this lock")
        }
        let secrets = takeSecrets(from: &state)
        // The channel gone (a build that couldn't take over read it before going back): no secrets, the vault as saved.
        if let secrets, Proof.digest(secrets) != claimed.secrets {
            throw refuse("its secrets aren't the ones its proof names")
        }
        return Received(state: state, secrets: secrets)
    }

    /// The lock a handover inherits.
    enum Lock {
        /// Why `fd` isn't the lock at `path` held through this very descriptor; nil when it is.
        static func notHeld(_ fd: Int32, path: String) -> String? {
            var held = stat()
            var there = stat()
            guard fd >= 0, fstat(fd, &held) == 0 else { return "its lock descriptor \(fd) isn't open" }
            guard lstat(path, &there) == 0, (there.st_mode & S_IFMT) == S_IFREG, held.st_dev == there.st_dev, held.st_ino == there.st_ino else {
                return "its lock descriptor isn't the lock file"
            }
            // Whether anyone holds it, asked through a description of its own: nobody, and the descriptor handed on
            // wasn't holding it.
            let probe = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard probe >= 0 else { return "the lock file doesn't open" }
            defer { Darwin.close(probe) }
            if flock(probe, LOCK_EX | LOCK_NB) == 0 { return "nobody held the lock" }
            // Held: by this descriptor (taking it again through it succeeds), or by another process.
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return "another process holds the lock" }
            return nil
        }
    }

    /// What tells the new image its handover came from the running host it replaces: an HMAC under a key derived from
    /// the vault's Keychain key (never the sealing key itself), over the state file's bytes, the digest of the
    /// secrets in the channel, the process (pid and start time, the same across the exec, as the kernel reports them
    /// for the process checking: never fields of the file) and the lock (its path and file). Carried in argv
    /// (`--handover-proof`): it gives nothing to a process that sees it, since it holds for this process alone.
    enum Proof {
        private static let domain = Data("vibeswitcher-host handover proof 1".utf8)
        /// The digest of no secrets.
        static let none = Data(count: 32)

        struct Claim: Equatable {
            var tag: Data
            /// The secrets' digest (`digest`), `none` for none.
            var secrets: Data

            init(tag: Data, secrets: Data) {
                self.tag = tag
                self.secrets = secrets
            }

            /// Parsed from `text` (`description`); nil when it isn't one.
            init?(_ text: String) {
                let parts = text.split(separator: ".", omittingEmptySubsequences: false)
                guard parts.count == 2, let tag = Proof.bytes(hex: parts[0]), let secrets = Proof.bytes(hex: parts[1]), tag.count == 32, secrets.count == 32 else {
                    return nil
                }
                self.init(tag: tag, secrets: secrets)
            }

            var description: String { Proof.hex(tag) + "." + Proof.hex(secrets) }
        }

        static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

        static func bytes<Text: StringProtocol>(hex text: Text) -> Data? {
            let digits = Array(text.utf8)
            guard digits.count % 2 == 0 else { return nil }
            func value(_ digit: UInt8) -> UInt8? {
                switch digit {
                case 48...57: return digit - 48
                case 97...102: return digit - 87
                default: return nil
                }
            }
            var data = Data(capacity: digits.count / 2)
            for index in stride(from: 0, to: digits.count, by: 2) {
                guard let high = value(digits[index]), let low = value(digits[index + 1]) else { return nil }
                data.append(high << 4 | low)
            }
            return data
        }

        static func key(from vaultKey: SymmetricKey) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: vaultKey, info: Data("dev.vibeswitcher.host-handover".utf8), outputByteCount: 32)
        }

        static func digest(_ secrets: Data?) -> Data { secrets.map { Data(SHA256.hash(data: $0)) } ?? none }

        /// The proof for a handover of `state` (its bytes as written) with `secrets` by this process, holding the lock
        /// `lockFD` at `lockPath`; nil when the process or the lock can't be told.
        /// The process a proof is for: this one (a test's another).
        struct Process {
            var pid: pid_t
            var started: (seconds: UInt64, microseconds: UInt64)

            static var this: Process? { startTime(of: getpid()).map { Process(pid: getpid(), started: $0) } }
        }

        static func make(vaultKey: SymmetricKey, state: Data, secrets: Data?, lockFD: Int32, lockPath: String,
                         process: Process? = .this) -> Claim? {
            let secrets = digest(secrets)
            guard let process, let message = message(state: state, secrets: secrets, lockFD: lockFD, lockPath: lockPath, process: process) else {
                return nil
            }
            return Claim(tag: Data(HMAC<SHA256>.authenticationCode(for: message, using: key(from: vaultKey))), secrets: secrets)
        }

        static func holds(_ claim: Claim, key vaultKey: SymmetricKey, state: Data, lockFD: Int32, lockPath: String) -> Bool {
            guard let process = Process.this,
                  let message = message(state: state, secrets: claim.secrets, lockFD: lockFD, lockPath: lockPath, process: process) else { return false }
            return HMAC<SHA256>.isValidAuthenticationCode(claim.tag, authenticating: message, using: key(from: vaultKey))
        }

        private static func message(state: Data, secrets: Data, lockFD: Int32, lockPath: String, process: Process) -> Data? {
            var lock = stat()
            guard fstat(lockFD, &lock) == 0 else { return nil }
            var message = domain
            for number in [UInt64(UInt32(bitPattern: process.pid)), process.started.seconds, process.started.microseconds,
                           UInt64(UInt32(bitPattern: lock.st_dev)), lock.st_ino] {
                withUnsafeBytes(of: number.bigEndian) { message.append(contentsOf: $0) }
            }
            let path = Data(lockPath.utf8)
            withUnsafeBytes(of: UInt64(path.count).bigEndian) { message.append(contentsOf: $0) }
            message.append(path)
            message.append(Data(SHA256.hash(data: state)))
            message.append(secrets)
            return message
        }

        /// When the process `pid` started, as the kernel has it (an exec in place keeps it).
        static func startTime(of pid: pid_t) -> (seconds: UInt64, microseconds: UInt64)? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            return (info.pbi_start_tvsec, info.pbi_start_tvusec)
        }
    }

    /// `--handover-probe PATH`: whether this build can take over from the state at `path`. Call first thing in `main`.
    public static func probeIfAsked(_ arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--handover-probe"), arguments.indices.contains(index + 1) else { return }
        do {
            _ = try read(from: arguments[index + 1])
            print(probeAnswer)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("vibeswitcher-host: handover probe: \(error)\n".utf8))
            exit(1)
        }
    }

    /// How long the probe may take to answer. On a loaded Mac most of it is the system's check of the new build's first
    /// exec (amfid, one new binary at a time for the whole Mac), before any of its code runs: on 2026-10-19 amfid
    /// answered nothing for 108 s at load 200, and the 15 s once given here refused good builds. The sessions carry on
    /// meanwhile (the probe runs off the server's queue); this only ends a build that hangs. Time awake: a Mac that
    /// sleeps while the probe waits (2026-11-15: from the second a handover began) gave it no time to answer.
    static let probeLimit: TimeInterval = 180

    /// Runs `executable --handover-probe path` and waits (up to `timeout`) for it to say it can take over. Blocks: not on
    /// the server's queue.
    static func probe(_ executable: String, statePath: String, timeout: TimeInterval = probeLimit, time: MacTime = .real) throws {
        var pipe: [Int32] = [-1, -1]
        guard Darwin.pipe(&pipe) == 0 else { throw Failure.probe("no pipe") }
        defer { Darwin.close(pipe[0]) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var all: sigset_t = ~0
        var none: sigset_t = 0
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, pipe[1], 1)
        posix_spawn_file_actions_addinherit_np(&actions, 2)
        let words = [executable, "--handover-probe", statePath]
        let argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        Darwin.close(pipe[1])
        guard spawned == 0 else { throw Failure.probe(String(cString: strerror(spawned))) }

        _ = fcntl(pipe[0], F_SETFL, fcntl(pipe[0], F_GETFL) | O_NONBLOCK)
        var output = Data()
        var status: Int32 = 0
        let deadline = time.awake() + timeout
        while waitpid(pid, &status, WNOHANG) == 0 {
            guard time.awake() < deadline else {
                kill(pid, SIGKILL)
                waitpid(pid, &status, 0)
                throw Failure.probe("it didn't answer")
            }
            output.append(drain(pipe[0]))
            usleep(10_000)
        }
        output.append(drain(pipe[0]))
        let answer = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0, answer.hasSuffix(probeAnswer) else {
            throw Failure.probe(answer.isEmpty ? "it exited with status \(status)" : "it said \(answer.suffix(200))")
        }
    }

    private static func drain(_ fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { return data }
            data.append(contentsOf: buffer[0..<count])
        }
    }

    /// Replaces this process's image with `executable`, keeping its pid. `inherit`: the descriptors the new image gets
    /// (besides 0–2); nil keeps every descriptor not marked close-on-exec. Returns only when that failed, with
    /// nothing changed.
    public static func exec(_ executable: String, arguments: [String], inherit: [Int32]?) -> Failure {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var flags = POSIX_SPAWN_SETEXEC | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        if inherit != nil { flags |= POSIX_SPAWN_CLOEXEC_DEFAULT }
        posix_spawnattr_setflags(&attributes, Int16(flags))
        // Default handling and an empty mask, as at a fresh start (the host ignores SIGPIPE and SIGHUP, and its queue's
        // threads block most signals; `main` sets up its own).
        var all: sigset_t = ~0
        var none: sigset_t = 0
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd in [0, 1, 2] + (inherit ?? []) { posix_spawn_file_actions_addinherit_np(&actions, fd) }
        // An in-place exec refuses to hand on a descriptor marked close-on-exec (EBADF): unmark the ones it keeps
        // (everything else still closes), and mark them again if it fails.
        let marked = (inherit ?? []).filter { fcntl($0, F_GETFD) & FD_CLOEXEC != 0 }
        marked.forEach { _ = fcntl($0, F_SETFD, 0) }
        defer { marked.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) } }
        let words = [executable] + arguments
        let argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        return .exec(result == 0 ? EINVAL : result)
    }

    /// The secrets the build before handed over (`HostServer.secretsForHandover`), exactly the bytes it gave; nil when
    /// it gave none. Read once: the channel is closed and `state` no longer names it, so `HostServer.start(restoring:)`
    /// returns nil for them after this.
    public static func takeSecrets(from state: inout State) -> Data? {
        guard let fd = state.secretFD else { return nil }
        state.secretFD = nil
        return isOpen(fd) ? SecretChannel.take(fd) : nil
    }

    /// Whether `fd` is an open descriptor.
    static func isOpen(_ fd: Int32) -> Bool { fd >= 0 && fcntl(fd, F_GETFD) != -1 }

    /// Carries secrets to the new image without writing them anywhere: they're written into a local socket before the
    /// exec, and the new build reads them from the end it inherits, then closes it.
    enum SecretChannel {
        /// The reading end, holding `secret` and then end-of-file.
        static func make(_ secret: Data) throws -> Int32 {
            var pair: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw Failure.secretTooLarge(secret.count) }
            let (reader, writer) = (pair[0], pair[1])
            var room = Int32(min(secret.count + 65_536, 8 << 20))
            setsockopt(writer, SOL_SOCKET, SO_SNDBUF, &room, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(reader, SOL_SOCKET, SO_RCVBUF, &room, socklen_t(MemoryLayout<Int32>.size))
            for fd in [reader, writer] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            _ = fcntl(writer, F_SETFL, fcntl(writer, F_GETFL) | O_NONBLOCK)
            var written = 0
            secret.withUnsafeBytes { raw in
                while written < raw.count {
                    let count = Darwin.write(writer, raw.baseAddress! + written, raw.count - written)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { return }
                    written += count
                }
            }
            Darwin.close(writer)
            guard written == secret.count else {
                Darwin.close(reader)
                throw Failure.secretTooLarge(secret.count)
            }
            return reader
        }

        /// Everything in the channel; closes it.
        static func take(_ fd: Int32) -> Data {
            defer { Darwin.close(fd) }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return data }
                data.append(contentsOf: buffer[0..<count])
            }
        }
    }
}
