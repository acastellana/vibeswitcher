import Foundation
import VibeCore

/// The session host hardened from its first statement, which host is the user's, and the test-only flags (the stage 2
/// plan's Task 9a; S2-D5; the security architecture document's S6 and S8).
///
/// **At start.** The host and parser modes of `vibeswitcher-host` call `atStart(mode:)` before they read or take anything:
/// `Platform.ProcessSelf.harden()` (non-dumpable, no core file), then `TracerPid`. A process still dumpable, or traced,
/// refuses to start; a new image after a handover goes back to the old one instead, never reading its state or its
/// secrets (`main`'s `goBack`), and the fallback, traced too, ends. The launcher mode doesn't harden: it execs the
/// session's program at once, and session programs stay dumpable as any program is. The Mac: nothing, as always.
///
/// **Which host is the user's** (`lock(_:usersLock:)`). On Linux the host holding the user's lock (`ownsLaunchers`,
/// which refuses the test-only flags, and on Linux spawns only for a lead and watches its path) is told by the lock
/// file's identity, its device and inode, never by the spelling of its path: `--lock ~/.vibeswitcher//host.lock`, a `..`
/// or `/./` names the user's lock, and a symbolic link as the lock is refused outright. The descriptor the host then
/// holds is the authority: `heldLockIsAllowed` asks it again once it is locked or inherited
/// (`HostServer.Config.heldLockIsAllowed`), and the start is refused unless the host is the user's exactly when what it
/// holds is the user's lock, should the path have been changed in between (a link put there included: what it opened
/// through the link is compared). The Mac compares the strings, as always (`docs/process/v2-mac-tasks.md`).
///
/// **The test-only flags** (`testFlags`) are taken on Linux only by a scratch host (on a lock of its own): the user's
/// host refuses each, saying so in its log (`refused(in:ownsLaunchers:)`), and takes nothing from it. Every one but those
/// a scratch host carries across its handovers (`carriedTestFlags`) is left out of what a build it hands over to is
/// started with (`withoutTestFlags(_:)`). The Mac keeps today's behaviour: any host takes `--handover-test-secret` and
/// carries it across a handover.
///
/// **Who an unreadable process is** (`isOurs(_:)`, S2-D5's "unreadable is the host only by token"). Any process can make
/// itself non-dumpable, so the host names an unreadable process as itself, a parser of its or its server child only by
/// its token (pid and start ticks): its own, recorded at its start; a parser a session holds, which is a child of this
/// process not yet reaped (so its pid can't have been given to another); the server child's, recorded at its spawn. The
/// host sets `UnreadableProcesses.isOurs` to it (VibeCore); every other process leaves it nil. The readers of another
/// process's /proc entries, by the process each runs in, and what each makes of an unreadable process:
///
/// - The host: `HostServer.executable(of:)`, for the orphan sweep (`HostProcesses.orphans`): nil, never an orphan, left
///   alone. `identify` and `session(of:)`'s ancestry (`ProcessTable.ancestry`, `Platform.Processes.link`) and
///   `HostProcesses.isParser`, `HostLog.peer`, the signal's sender: `stat`, `status` and `cmdline`, which stay readable.
///   A session's kill (`HostedSession`, through `SessionStrays.end` and `of(session:started:)`): a descendant of the
///   session's program whose environment can't be read is the session's, and ended with it, unless it is `ours`. `AppConnector`: the server child must read as non-dumpable.
/// - The tool server: `SessionStrays.carrying` (environments: unreadable carries nothing), `SessionStrays.runs` (the
///   app's executable: unreadable isn't the app), `SessionStrays.inside` and `Worktrees`' folder checks (cwd and open
///   files: unreadable is inside nothing), `SessionStrays.isRunning` and `descendants` (stat: still running).
/// - The hook and the command line: `ProcessTable` (stat and cmdline; cwd for Codex's terminals: unknown).
/// - The app (`ShellTidy`, through `SessionStrays.of(session:started:)`): as the host's kill, with no `ours`.
/// - The app and the node (`SessionScanner`, the node's through `LocalSessions`): an agent's cwd
///   (`ProcessTable.cwd(pid:)`) unreadable is unknown: the session is still listed, its folder the hook's or none.
/// - The engine's and the app's readers (`DiskSpace`, `ProcessUsage` (and `ProcessTable.cwd(of:)` beside it), `LoadRecorder`,
///   `StallWatch`, `TestLock`, `WalletCourier`, `WalletLocalLink`, `HeavyJobs`, and the app's `LeadController`, which
///   gives `HeavyJobs` `ProcessTable.cwd(of:)` and `commandName(of:)`): records from `stat` (readable); a cwd, program
///   or open files unreadable is "unknown", left out of what they count, never "gone".
public enum HostHardening {
    public enum Mode: Sendable {
        /// The session host, a fresh start or a new image after a handover.
        case host
        /// A session's parser (`SessionParser`): it holds that session's screen.
        case parser
    }

    /// What `atStart(mode:)` found.
    public enum Start: Equatable, Sendable {
        /// The Mac: nothing done, nothing asked, as always.
        case nothing
        /// Non-dumpable, no core file, traced by no one.
        case hardened
        /// This process may not start (`Refused` says why).
        case refused(String)
    }

    /// Why a host or parser didn't start.
    public struct Refused: Error, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// Hardens this process, then reads who traces it: `refused` when it is still dumpable or a tracer is named (or
    /// none can be read). As the host, it records its own token for `isOurs` first. Call it first thing, before any
    /// secret is read or any descriptor taken. The Mac: `nothing`.
    @discardableResult
    public static func atStart(mode: Mode) -> Start {
        guard !Platform.CodeIdentity.isAvailable else { return .nothing }
        let hardened = Platform.ProcessSelf.harden()
        if mode == .host { state.withLock { $0.own = Platform.Processes.token(getpid()) } }
        guard Platform.ProcessSelf.isDumpable() == false else {
            return .refused("still dumpable after hardening (harden \(hardened ? "held" : "failed"), errno \(errno))")
        }
        guard let tracer = Platform.ProcessSelf.tracer() else { return .refused("its tracer can't be read (/proc/self/status)") }
        guard tracer == 0 else { return .refused("traced by pid \(tracer)") }
        return .hardened
    }

    /// Why the host may not start at all, said and ended on: `atStart` refused it (`start`) and it is no new image of a
    /// handover, which goes back to the build before instead (`handover(in:)` gives the state it was handed). Nil: it
    /// goes on. A `--handover` with no state after it is no handover: refused.
    public static func refusal(_ start: Start, arguments: [String]) -> String? {
        guard case .refused(let why) = start else { return nil }
        return handover(in: arguments) == nil ? why : nil
    }

    /// The state file a new image after a handover is given (`--handover PATH`), as `main` takes it: nil without a
    /// value after the flag.
    public static func handover(in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--handover"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// A parser's first statement (`SessionParser.runIfAsked`, once it knows it is one): hardened, and ended (exit 1,
    /// said on stderr) when refused.
    static func hardenAsParser() {
        if case .refused(let why) = atStart(mode: .parser) {
            FileHandle.standardError.write(Data("vibeswitcher-host: parser not started: \(why)\n".utf8))
            _exit(1)
        }
    }

    // MARK: Which host is the user's

    /// What the lock a host is told to take (`lockPath`) is to the user's lock (`usersLock`, `VibePaths.hostLock`).
    public enum Lock: Equatable, Sendable {
        /// The user's lock: this host is the user's (`ownsLaunchers`).
        case users
        /// A lock of its own: a scratch host.
        case scratch
        /// A symbolic link: refused as a lock (Linux).
        case link
    }

    /// Linux: `lockPath` opened (made when missing, a link not followed, as `HostServer.start` makes it) and compared
    /// with `usersLock` by device and inode (`Platform.Files.sameFile`): `users` when they are the same file, `link` when
    /// `lockPath` is a symbolic link, else `scratch`. When it can't be opened for another reason (no right to it, say),
    /// it fails closed: `users` when it is the user's lock by its entry's device and inode (`lstat`) or by its very
    /// spelling, `scratch` otherwise (the host's own start then fails on it, or `heldLockIsAllowed` checks what it
    /// took). The Mac: the strings compared, as always.
    public static func lock(_ lockPath: String, usersLock: String) -> Lock {
        guard !Platform.CodeIdentity.isAvailable else { return lockPath == usersLock ? .users : .scratch }
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            if errno == ELOOP { return .link }
            var named = stat(), users = stat()
            let sameEntry = lstat(lockPath, &named) == 0 && lstat(usersLock, &users) == 0
                && named.st_dev == users.st_dev && named.st_ino == users.st_ino
            return sameEntry || lockPath == usersLock ? .users : .scratch
        }
        defer { Sys.close(fd) }
        return Platform.Files.sameFile(fd, usersLock) ? .users : .scratch
    }

    /// Whether a host told to take `lockPath` is the user's (`lock(_:usersLock:)` is `users`). A symbolic link as the
    /// lock: said on stderr, and this process exits (1), before it has taken anything.
    public static func ownsLaunchers(lockPath: String, usersLock: String) -> Bool {
        switch lock(lockPath, usersLock: usersLock) {
        case .users: return true
        case .scratch: return false
        case .link:
            FileHandle.standardError.write(Data("vibeswitcher-host: not started: the lock \(lockPath) is a symbolic link\n".utf8))
            exit(1)
        }
    }

    /// `HostServer.Config.heldLockIsAllowed` for a host that is (`ownsLaunchers`) or isn't the user's: on Linux the
    /// held descriptor decides, both ways: the user's host must hold the user's lock (`usersLock`, by identity), and a
    /// scratch host any lock but it. The Mac: nil.
    public static func heldLockIsAllowed(ownsLaunchers: Bool, usersLock: String) -> ((Int32) -> Bool)? {
        guard !Platform.CodeIdentity.isAvailable else { return nil }
        return { fd in ownsLaunchers == Platform.Files.sameFile(fd, usersLock) }
    }

    // MARK: The test-only flags

    /// Each test-only flag a host may be given, and whether it takes a value (the plan's Global Constraints). Some are
    /// read by later tasks' code; each is refused by the user's host on Linux from now on all the same.
    public static let testFlags: [String: Bool] = [
        TestAppPrincipal.pidFlag: true, TestAppPrincipal.connectorFlag: true,
        "--handover-test-secret": true, "--handover-test-secret-file": true, "--handover-test-traced": false,
        "--install-root": true, "--parser-test-hooks": false, staysDumpableFlag: false,
        "--server-arg": true, "--hold-first-look": false, "--test-user-seal-life": true,
    ]

    /// The test-only flags a scratch host carries across its handovers, so a test's settings survive one.
    public static let carriedTestFlags: Set<String> = ["--server-arg", "--hold-first-look", "--test-user-seal-life"]

    /// A scratch host's own test flag: it makes itself dumpable again once it knows it is a scratch host, so a test can
    /// count its descriptors from outside (`EndedSessionTests`). Not carried across a handover.
    public static let staysDumpableFlag = "--test-stays-dumpable"

    /// Whether a host takes the test-only flags it is given: on Linux only a scratch host; on the Mac any, as always.
    public static func takesTestFlags(ownsLaunchers: Bool) -> Bool { Platform.CodeIdentity.isAvailable || !ownsLaunchers }

    /// The test-only flags in `arguments` (after the executable) a host refuses: on Linux, every one the user's host is
    /// given; none otherwise. In the order given, each once.
    public static func refused(in arguments: [String], ownsLaunchers: Bool) -> [String] {
        guard !takesTestFlags(ownsLaunchers: ownsLaunchers) else { return [] }
        var found: [String] = []
        for argument in arguments where testFlags[argument] != nil && !found.contains(argument) { found.append(argument) }
        return found
    }

    /// `arguments` (what a build this host hands over to is started with) without the test-only flags and their values,
    /// but those a scratch host carries (`carriedTestFlags`). The Mac: as given.
    public static func withoutTestFlags(_ arguments: [String]) -> [String] {
        guard !Platform.CodeIdentity.isAvailable else { return arguments }
        var kept: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if let takesValue = testFlags[argument], !carriedTestFlags.contains(argument) {
                index += takesValue ? 2 : 1
                continue
            }
            kept.append(argument)
            index += 1
        }
        return kept
    }

    /// After the host's config is made: the flags `refused(in:ownsLaunchers:)` names said in its log and on stderr,
    /// and, on Linux, a scratch host given `staysDumpableFlag` made dumpable again.
    public static func afterConfig(arguments: [String], ownsLaunchers: Bool, server: HostServer) {
        let refused = refused(in: arguments, ownsLaunchers: ownsLaunchers)
        if !refused.isEmpty {
            let line = "refused test-only flags (the user's host takes none): \(refused.joined(separator: ", "))"
            server.note("host: " + line)
            FileHandle.standardError.write(Data("vibeswitcher-host: \(line)\n".utf8))
        }
        if !Platform.CodeIdentity.isAvailable, !ownsLaunchers, arguments.contains(staysDumpableFlag) {
            _ = Platform.ProcessSelf.makeDumpable()
        }
    }

    // MARK: Who an unreadable process is

    private struct State {
        var own: Platform.PeerToken?
        weak var server: HostServer?
    }

    private static let state = Locked(State())

    /// The host whose parsers and server child `isOurs` names, and `UnreadableProcesses.isOurs` set to it. Linux only:
    /// on the Mac nothing is set.
    public static func watch(_ server: HostServer) {
        guard !Platform.CodeIdentity.isAvailable else { return }
        state.withLock { $0.server = server }
        UnreadableProcesses.isOurs = { isOurs($0) }
    }

    /// Whether `token` is this host's own process (recorded at `atStart(mode: .host)`), a parser one of its sessions
    /// holds (a child of this process not yet reaped, started when the token says), or its server child (its token
    /// recorded at its spawn). Never true on the Mac, nor in a process that isn't the host.
    public static func isOurs(_ token: Platform.PeerToken) -> Bool {
        let (own, server) = state.withLock { ($0.own, $0.server) }
        if let own, own.sameImage(as: token) { return true }
        guard let server else { return false }
        return server.valueOnQueue {
            if server.serverChild?.token?.sameImage(as: token) == true { return true }
            guard server.sessions.values.contains(where: { $0.parserPIDs.contains(token.pid) }),
                  let link = Platform.Processes.link(token.pid) else { return false }
            return link.parent == getpid() && link.isProcess(of: token)
        }
    }

    /// For tests: forgets what `atStart` and `watch` recorded, and `UnreadableProcesses.isOurs` with it.
    static func forget() {
        state.withLock { $0 = State() }
        UnreadableProcesses.isOurs = nil
    }

    /// For tests: records `token` as this host's own, as `atStart(mode: .host)` does with its own.
    static func recordOwn(_ token: Platform.PeerToken?) { state.withLock { $0.own = token } }
}

extension HostServer {
    /// `body` on the host's queue: at once when already on it, else waited for.
    func valueOnQueue<Value>(_ body: () -> Value) -> Value {
        DispatchQueue.getSpecific(key: Self.queueKey) != nil ? body() : queue.sync(execute: body)
    }
}

/// A value behind a lock.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
