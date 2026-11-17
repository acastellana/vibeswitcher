import Foundation
import VibeCore

/// Starts the node as the user's systemd unit (the start plan's S2; the bootstrap path's "Who starts the node"): the
/// unit's state read (a running unit isn't started again), the unit written whole, `daemon-reload`, what the manager
/// then shows of it checked against what was written (ST-D2), the manager's environment read again, the caller's
/// journal entry, `enable` only for `start --at-login`, `start`, then a wait for the node's server to answer. Every tool and folder is a parameter (`Tools`, ST-D1), and so are the probe and the clock: the installed
/// command line passes `node(accountHome:uid:)`, tests a scratch folder and a recording `systemctl`.
///
/// Each `systemctl` runs by its absolute path through `Platform.Spawn`, waited for with a bound (`run`), never
/// Foundation's `Process`, and with an environment of its own: `PATH=/usr/bin:/bin` and the manager's runtime folder,
/// so no `XDG_RUNTIME_DIR` or `DBUS_SESSION_BUS_ADDRESS` of this process's picks the manager it talks to.
public struct NodeStarter {
    /// The tools and folders the start uses.
    public struct Tools: Equatable, Sendable {
        public var systemctl: String
        /// Where the unit file goes (`NodeFolders.unitFolder`).
        public var unitFolder: String
        /// The user's runtime folder (`NodeFolders.runtimeFolder`): the manager's socket is `systemd/private` in it.
        public var runtimeFolder: String

        public init(systemctl: String, unitFolder: String, runtimeFolder: String) {
            self.systemctl = systemctl
            self.unitFolder = unitFolder
            self.runtimeFolder = runtimeFolder
        }
    }

    /// The installed command line's: `/usr/bin/systemctl`, `<home>/.config/systemd/user` and `/run/user/<uid>`, the
    /// home from `getpwuid`. No environment variable changes any of them.
    public static func node(accountHome: String, uid: uid_t) -> Tools {
        Tools(systemctl: "/usr/bin/systemctl", unitFolder: NodeFolders.unitFolder(accountHome: accountHome), runtimeFolder: NodeFolders.runtimeFolder(uid: uid))
    }

    /// The environment every `systemctl` runs with: nothing of this process's.
    public static func environment(runtimeFolder: String) -> [String] {
        ["PATH=/usr/bin:/bin", "XDG_RUNTIME_DIR=\(runtimeFolder)"]
    }

    /// The unit's name as `systemctl` is given it.
    public static let unitName = "vibeswitcher-node"

    /// What the probe found, once.
    public enum Probe: Equatable, Sendable {
        /// The node's server answers and passes `ServerCheck`.
        case listening
        /// Nothing answers yet, and the unit still runs.
        case notYet
        /// What listens fails `ServerCheck`, and why: not the node starting (waited past, never taken).
        case refusedByCheck(String)
        /// The unit ended (`ActiveState` `failed` or `inactive`), with its `Result`.
        case unitEnded(result: String)
        /// The host started detached ended (S3), and how, said.
        case hostEnded(String)
    }

    /// A start that went: the commit, and whether the unit is enabled at login.
    public struct Started: Equatable, Sendable {
        public var commit: String
        public var enabledAtLogin: Bool

        public init(commit: String, enabledAtLogin: Bool) {
            self.commit = commit
            self.enabledAtLogin = enabledAtLogin
        }
    }

    /// How long the server is waited for: the app's `HostClient.hostStartLimit`.
    public static let listenLimit: TimeInterval = 180
    /// How long between two probes.
    public static let probeInterval: TimeInterval = 0.25
    /// How long one `systemctl` is given.
    public static let toolLimit: TimeInterval = 120

    public let tools: Tools
    private let listen: () -> Probe
    private let now: () -> TimeInterval
    private let pause: (TimeInterval) -> Void

    /// `listen`: the probe (the command line's: `NodeClient.connect` and `ServerCheck`, then the unit's state). `now`:
    /// seconds on a monotonic clock (the system's awake time by default, as `NodeClock`'s). `pause`: how a pause between
    /// probes passes (a sleep by default; a test moves its clock).
    public init(tools: Tools, listen: @escaping () -> Probe, now: (() -> TimeInterval)? = nil, pause: ((TimeInterval) -> Void)? = nil) {
        self.tools = tools
        self.listen = listen
        self.now = now ?? { MacTime.real.awake() }
        self.pause = pause ?? { Thread.sleep(forTimeInterval: $0) }
    }

    /// The unit file: `<unitFolder>/vibeswitcher-node.service`.
    public var unitFile: String { NodeFolders.join(tools.unitFolder, NodeUnit.fileName) }

    /// The unit's `ActiveState`s from which `start` goes on: anything else (`active`, `activating`, `reloading`,
    /// `deactivating`, `refreshing`) runs a host whose server didn't answer, and `systemctl start` on it does nothing
    /// (the review of S2).
    public static let stoppedStates: Set<String> = ["inactive", "failed"]

    /// Reads the unit's `ActiveState` and refuses unless it is stopped (`stoppedStates`); writes the unit for `unit`,
    /// then `daemon-reload`, the show check (`NodeUnit.showMismatch`, `NodeUnit.defaultsMismatch`), the manager's
    /// environment again, `beforeStart` (the command line's journal entry for the start: written only once every check
    /// passed, so a refused start leaves no entry that explains a later job, the review of S2), `enable` (only
    /// `atLogin`), `start`, and the wait (`awaitListening`). Each refusal names what failed; nothing after it is asked.
    /// A refusal after `enable` says that the unit stays enabled, and one at the wait's limit that it may still run.
    public func startUnit(_ unit: NodeUnit.Inputs, atLogin: Bool, beforeStart: () -> StartRefusal? = { nil }) -> Result<Started, StartRefusal> {
        let text: String
        switch NodeUnit.text(unit) {
        case .failure(let refused): return .failure(refused)
        case .success(let made): text = made
        }
        let state = ask(["--user", "show", "-p", "ActiveState", Self.unitName])
        if let refused = state.refusal { return .failure(refused) }
        let active = NodeUnit.values(state.output)["ActiveState"]?.last ?? ""
        guard Self.stoppedStates.contains(active) else {
            return .failure(StartRefusal("the unit \(Self.unitName) is \(ConfigSeal.inert(active.isEmpty ? "of a state the manager didn't say" : active, limit: 64)) but its server didn't answer: `systemctl start` would leave what runs as it is, and start won't say it started a build. `systemctl --user stop \(Self.unitName)` stops it (every session in it ends with it), then run start again; see journalctl --user -u \(Self.unitName)", exitCode: 1))
        }
        if let refused = write(text) { return .failure(refused) }
        if let refused = ask(["--user", "daemon-reload"]).refusal { return .failure(refused) }
        let shown = ask(["--user", "show", Self.unitName, "-p", NodeUnit.showProperties.joined(separator: ",")])
        if let refused = shown.refusal { return .failure(refused) }
        if let mismatch = NodeUnit.showMismatch(shown.output, expected: NodeUnit.expectedShow(unit, unitFile: unitFile))
            ?? NodeUnit.defaultsMismatch(shown.output, home: unit.home) {
            return .failure(StartRefusal("the manager doesn't run the unit start wrote: \(mismatch). A drop-in (in \(ConfigSeal.inert(unitFile, limit: .max)).d/, a service.d/ folder, ~/.local/share/systemd/user, ~/.config/systemd/user.control or /run/user/<uid>/systemd/), a link in a vibeswitcher-node.service.wants/, .requires/ or .upholds/ folder, another unit file of the same name, or a unit file put in place of start's before the reload changes it; remove it, and nothing was started"))
        }
        // A `daemon-reload` applies `user.conf`'s `DefaultEnvironment=` and the `environment.d` generators: a name
        // written after the facts were read shows only now (the review of S1).
        let environment = ask(["--user", "show-environment"])
        if let refused = environment.refusal { return .failure(refused) }
        if let refused = NodeFolders.managerRefusal(showEnvironment: environment.output) { return .failure(refused) }
        if let refused = beforeStart() { return .failure(refused) }
        if atLogin, let refused = ask(["--user", "enable", Self.unitName]).refusal { return .failure(refused) }
        // Past `enable`, a refusal says the unit stays enabled: the next login starts it, with no start check.
        func enabled(_ refused: StartRefusal) -> StartRefusal {
            guard atLogin else { return refused }
            return StartRefusal("\(refused.text). The unit stays enabled at login: `systemctl --user disable \(Self.unitName)` undoes that", exitCode: refused.exitCode)
        }
        if let refused = ask(["--user", "start", Self.unitName]).refusal {
            return .failure(enabled(StartRefusal("\(refused.text); see journalctl --user -u \(Self.unitName)", exitCode: 1)))
        }
        if let refused = awaitListening() { return .failure(enabled(refused)) }
        return .success(Started(commit: unit.commit, enabledAtLogin: isEnabled))
    }

    /// Waits for the node's server (`listen`), `listenLimit` at most: nil once it answers and passes the check; a
    /// refusal when the unit ends first ("the node didn't start (<result>)", at once) or at the limit (naming the
    /// check's reason when what listened failed it). A listener that fails the check is waited past, never taken.
    ///
    /// `detachedLog`: the host was started detached (S3), its output in that file: the refusals name it and `stop`,
    /// not the unit's journal and `systemctl`.
    public func awaitListening(detachedLog: String? = nil) -> StartRefusal? {
        let deadline = now() + Self.listenLimit
        var check: String?
        while true {
            switch listen() {
            case .listening: return nil
            case .unitEnded(let result):
                return StartRefusal("the node didn't start (\(ConfigSeal.inert(result, limit: 64))); see journalctl --user -u \(Self.unitName)", exitCode: 1)
            case .hostEnded(let how):
                return StartRefusal("the node's host ended before its server answered (\(ConfigSeal.inert(how, limit: 128))); see \(ConfigSeal.inert(detachedLog ?? "its log", limit: .max))", exitCode: 1)
            case .refusedByCheck(let why): check = why
            case .notYet: break
            }
            guard now() < deadline else {
                let limit = Int(Self.listenLimit)
                // The unit ended would have been seen: at the limit it may still run (a host still starting, or one
                // whose socket another process holds), and start doesn't stop it (the review of S2).
                let still = detachedLog.map { "; the host may still run: `vibeswitcher stop` ends it; see \(ConfigSeal.inert($0, limit: .max))" }
                    ?? "; the unit may still run: `systemctl --user stop \(Self.unitName)` stops it; see journalctl --user -u \(Self.unitName)"
                if let check {
                    return StartRefusal("the node's server didn't answer within \(limit) s: what listens on its socket fails the server check (\(ConfigSeal.inert(check, limit: .max)))\(still)", exitCode: 1)
                }
                return StartRefusal("the node's server didn't answer within \(limit) s\(still)", exitCode: 1)
            }
            pause(Self.probeInterval)
        }
    }

    /// Whether the unit is enabled at login: a link to it in any `.wants`, `.requires` or `.upholds` folder of the unit
    /// folder (`enabledBy`), a read, no call.
    public var isEnabled: Bool { !Self.enabledBy(unitFolder: tools.unitFolder).isEmpty }

    /// The folders of `unitFolder` that start the unit when their unit starts (`default.target.wants`, and any other
    /// `*.wants`, `*.requires` or `*.upholds`): each that holds an entry named `vibeswitcher-node.service`, sorted. A
    /// plain start says them before its code (ST-D4's "says when the unit is found enabled", the review of S2). Another
    /// unit file's own `Wants=` isn't read.
    public static func enabledBy(unitFolder: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: unitFolder) else { return [] }
        return names.filter { name in
            [".wants", ".requires", ".upholds"].contains { name.hasSuffix($0) }
                && NodeFolders.fileStatus(NodeFolders.join(NodeFolders.join(unitFolder, name), NodeUnit.fileName)) != nil
        }.sorted()
    }

    // MARK: - The detached start (S3)

    /// The environment of a host started detached (ST-D6): exactly `HOME`, the unit's `PATH` and
    /// `SWIFT_BACKTRACE=enable=no`; nothing of the command line's own (an `LD_PRELOAD` an edited `.bashrc` set included).
    public static func detachedEnvironment(home: String, path: String) -> [String] {
        ["HOME=\(home)", "PATH=\(path)", "SWIFT_BACKTRACE=enable=no"]
    }

    /// The lock a detached start holds from the record's check to its settle: `<root>/v2/node.pid.lock` (0600).
    public static func detachedLock(root: String) -> String { NodeFolders.join(root, "v2/node.pid.lock") }

    /// Where a detached host's stdout and stderr go: `<root>/v2/host.log`.
    public static func hostLog(root: String) -> String { NodeFolders.join(root, "v2/host.log") }

    /// How long `startDetached` watches the host it started for an exit at once.
    public static let detachedSettle: TimeInterval = 1

    /// Why a detached start refuses this process's umask (`mask`, which the host inherits through `posix_spawn`), or
    /// nil: as the unit's `UMask` (`NodeUnit.defaultsMismatch`), it must mask other users' write, or every file the host
    /// makes without a mode of its own (its sessions', worktrees') would be writable by other users. nil `mask`: it
    /// couldn't be read, which refuses too (the step 8 sweep, 2026-11-17).
    public static func umaskRefusal(_ mask: mode_t?) -> StartRefusal? {
        guard let mask else {
            return StartRefusal("this shell's umask can't be read: start won't start the host without knowing the mode of the files it makes", exitCode: 1)
        }
        guard mask & 0o002 == 0 else { return nil }
        return StartRefusal("this shell's umask is \(String(format: "%04o", mask)): the host would inherit it, and files it makes would be writable by other users; run `umask 022` (or `umask 077`), then start again", exitCode: 1)
    }

    /// This process's umask: Linux's `/proc/self/status` (`Umask:`), which reads it without changing it; else (no such
    /// line) `umask` set and set back, nil when that fails.
    public static func processUmask(status: String = "/proc/self/status") -> mode_t? {
        if let text = try? String(contentsOfFile: status, encoding: .utf8),
           let line = text.split(separator: "\n").first(where: { $0.hasPrefix("Umask:") }) {
            return mode_t(line.dropFirst("Umask:".count).trimmingCharacters(in: .whitespaces), radix: 8)
        }
        let old = umask(0o077)
        umask(old)
        return old
    }

    /// Starts `host` (its argv, by its absolute path; the installed command line passes `NodeUnit.execStart`) detached,
    /// on a machine without systemd (ST-D6): with `Platform.Spawn` in a session of its own (`posix_spawn`'s `SETSID`,
    /// not a double fork: the command line is multithreaded), keeping no descriptor of the command line's, in `home`,
    /// with `detachedEnvironment` only, stdin `/dev/null` and stdout and stderr appended to `hostLog` (0600, opened
    /// with `O_NOFOLLOW`). The host is this process's child until it exits, then init's.
    ///
    /// The whole start holds `detachedLock(root:)` (an exclusive `flock`), from the record's check through the record's
    /// write and the settle: another start meanwhile is refused before anything ("another start of the node is under
    /// way"), so two starts at once can't both pass the check and leave the record naming a host that failed on the
    /// first one's lock while the first runs unrecorded (the review of S3).
    ///
    /// Refused before anything when this process's umask (`mask`) lets other users write (`umaskRefusal`), as the
    /// unit's start refuses the manager's `UMask`.
    ///
    /// Refused before anything is started while `root`'s record names a process that still runs (its start ticks) with
    /// the host's command line (`isHost`: the installed command line passes `NodeCheck.isInstalledHost`): its server
    /// didn't answer, and a second host would only fail on the first one's lock. A record naming any other process
    /// (one given the number since, or any process a worker wrote in) is replaced, and that process left alone (the
    /// review of S3: stop refuses such a record, so it mustn't keep a start from running either). Then the record
    /// (`NodeRecord`: its pid and start) is written; a host that ends within `settle` is collected, its record removed,
    /// and refused: "the host ended at once (pid, status); see <log>".
    public static func startDetached(host: [String], home: String, path: String, root: String, isHost: ([String]) -> Bool,
                                     settle: TimeInterval = detachedSettle, umask mask: mode_t? = processUmask()) -> Result<NodeRecord, StartRefusal> {
        guard let program = host.first, program.hasPrefix("/") else {
            return .failure(StartRefusal("the host's command isn't an absolute path: \(ConfigSeal.inert(host.joined(separator: " "), limit: .max))", exitCode: 1))
        }
        if let refused = umaskRefusal(mask) { return .failure(refused) }
        let log = hostLog(root: root)
        do {
            try VibePaths.ensurePrivate(URL(fileURLWithPath: NodeFolders.join(root, "v2"), isDirectory: true))
        } catch {
            return .failure(StartRefusal("\(ConfigSeal.inert(NodeFolders.join(root, "v2"), limit: .max)) can't be made: \(error.localizedDescription)", exitCode: 1))
        }
        let lockPath = detachedLock(root: root)
        let lock = Sys.open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC, 0o600)
        guard lock >= 0 else {
            return .failure(StartRefusal("the start's lock \(ConfigSeal.inert(lockPath, limit: .max)) can't be opened: \(String(cString: strerror(errno)))", exitCode: 1))
        }
        defer { Sys.close(lock) }
        var lockInfo = stat()
        guard fstat(lock, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG, fchmod(lock, 0o600) == 0 else {
            return .failure(StartRefusal("the start's lock \(ConfigSeal.inert(lockPath, limit: .max)) isn't a regular file of yours", exitCode: 1))
        }
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            return .failure(StartRefusal("another start of the node is under way (it holds \(ConfigSeal.inert(lockPath, limit: .max))): nothing was started", exitCode: 1))
        }
        if let old = NodeRecord.read(root: root), old.isLive(), isHost(Platform.Processes.arguments(old.pid)) {
            return .failure(StartRefusal("the recorded host (pid \(old.pid), \(ConfigSeal.inert(NodeRecord.path(root: root), limit: .max))) still runs, but its server didn't answer: `vibeswitcher stop` ends it, then run start again", exitCode: 1))
        }
        let fd = Sys.open(log, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NOCTTY | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            return .failure(StartRefusal("the host's log \(ConfigSeal.inert(log, limit: .max)) can't be opened: \(String(cString: strerror(errno)))", exitCode: 1))
        }
        defer { Sys.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, fchmod(fd, 0o600) == 0 else {
            return .failure(StartRefusal("the host's log \(ConfigSeal.inert(log, limit: .max)) isn't a regular file of yours", exitCode: 1))
        }

        var spawn = Platform.Spawn(executable: program, arguments: host)
        spawn.environment = detachedEnvironment(home: home, path: path)
        spawn.directory = home
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.stdout = .descriptor(fd)
        spawn.stderr = .descriptor(fd)
        spawn.group = .ownSession
        spawn.keep = []
        let pid: pid_t
        switch spawn.start() {
        case .failure(let error):
            return .failure(StartRefusal("the host \(ConfigSeal.inert(program, limit: .max)) couldn't be started (errno \(error.code))", exitCode: 1))
        case .success(let started): pid = started
        }
        // Its start, read while it is this process's child (an ended child stays a zombie until collected below, so
        // the number can't be another's yet).
        guard let ticks = Platform.Processes.link(pid)?.startTicks else {
            _ = endChild(pid)
            return .failure(StartRefusal("the host's start (pid \(pid)) couldn't be read; it was ended", exitCode: 1))
        }
        let record = NodeRecord(pid: pid, startTicks: ticks)
        do {
            try record.write(root: root)
        } catch {
            _ = endChild(pid)
            return .failure(StartRefusal("the node's record \(ConfigSeal.inert(NodeRecord.path(root: root), limit: .max)) can't be written (\(error)); the host was ended", exitCode: 1))
        }
        let clock = MacTime.real
        let deadline = clock.awake() + settle
        var status: Int32 = 0
        while clock.awake() < deadline {
            let reaped = waitpid(pid, &status, WNOHANG)
            if reaped == pid {
                NodeRecord.remove(root: root, ifStill: record)
                let signal = status & 0x7f
                let how = signal == 0 ? "exit status \((status >> 8) & 0xff)" : "signal \(signal)"
                return .failure(StartRefusal("the host ended at once (pid \(pid), \(how)); see \(ConfigSeal.inert(log, limit: .max))", exitCode: 1))
            }
            if reaped < 0, errno != EINTR { break }
            usleep(5_000)
        }
        return .success(record)
    }

    /// Kills this process's child `pid` and collects it, 10 s at most: whether it was collected.
    static func endChild(_ pid: pid_t) -> Bool {
        Sys.kill(pid, SIGKILL)
        let deadline = MacTime.real.awake() + 10
        var status: Int32 = 0
        while MacTime.real.awake() < deadline {
            let reaped = waitpid(pid, &status, WNOHANG)
            if reaped == pid { return true }
            if reaped < 0, errno != EINTR { return false }
            usleep(2_000)
        }
        return false
    }

    // MARK: - The unit file and systemctl

    /// Writes `text` to a temporary file in the unit folder (made 0755 if absent), 0644, then renames it over the
    /// unit file; nil, or why not. `SwitchFollowUp` writes the switched unit with it too (S8a).
    func write(_ text: String) -> StartRefusal? {
        let folder = tools.unitFolder
        if NodeFolders.fileStatus(folder) == nil {
            do {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            } catch {
                return StartRefusal("the unit folder \(ConfigSeal.inert(folder, limit: .max)) can't be made: \(error.localizedDescription)", exitCode: 1)
            }
        }
        let temporary = NodeFolders.join(folder, ".\(NodeUnit.fileName).\(getpid()).\(UUID().uuidString.prefix(8)).tmp")
        let fd = Sys.open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            return StartRefusal("the unit can't be written in \(ConfigSeal.inert(folder, limit: .max)): \(String(cString: strerror(errno)))", exitCode: 1)
        }
        let bytes = Array(text.utf8)
        var done = 0
        var failed: Int32 = 0
        if fchmod(fd, 0o644) != 0 { failed = errno }
        while failed == 0, done < bytes.count {
            let wrote = bytes.withUnsafeBytes { Sys.write(fd, $0.baseAddress! + done, bytes.count - done) }
            if wrote < 0, errno == EINTR { continue }
            guard wrote > 0 else { failed = wrote < 0 ? errno : EIO; break }
            done += wrote
        }
        if failed == 0, fsync(fd) != 0 { failed = errno }
        Sys.close(fd)
        if failed == 0, rename(temporary, unitFile) != 0 { failed = errno }
        guard failed == 0 else {
            unlink(temporary)
            return StartRefusal("the unit can't be written to \(ConfigSeal.inert(unitFile, limit: .max)): \(String(cString: strerror(failed)))", exitCode: 1)
        }
        return nil
    }

    /// Runs `systemctl arguments` with `environment(runtimeFolder:)`: its output, and a refusal naming the call when
    /// it couldn't be run, didn't end in time, or didn't exit 0. `SwitchFollowUp`'s `daemon-reload` too (S8a).
    func ask(_ arguments: [String]) -> (output: String, refusal: StartRefusal?) {
        let call = ([tools.systemctl] + arguments).joined(separator: " ")
        guard let ran = Self.run(tools.systemctl, arguments, environment: Self.environment(runtimeFolder: tools.runtimeFolder)) else {
            return ("", StartRefusal("\(ConfigSeal.inert(call, limit: .max)) couldn't be run, or didn't end within \(Int(Self.toolLimit)) s", exitCode: 1))
        }
        guard ran.status == 0 else { return (ran.output, StartRefusal("\(ConfigSeal.inert(call, limit: .max)) exited \(ran.status)", exitCode: 1)) }
        return (ran.output, nil)
    }

    /// Runs `program` (by its absolute path, never looked up) with `arguments` and `environment` (nil: this
    /// process's), stdin `/dev/null` and stderr dropped, in a process group of its own: its exit status (128 and the
    /// signal's number for one a signal ended) and its stdout. Started with `Platform.Spawn` and collected by its pid
    /// with bounded waits (`waitpid` with `WNOHANG`), never Foundation's `waitUntilExit` (the Mac's hang). Past
    /// `timeout` its group is killed and the answer is nil; nil too when it can't be started.
    public static func run(_ program: String, _ arguments: [String], environment: [String]?, timeout: TimeInterval = toolLimit) -> (status: Int32, output: String)? {
        var ends: [Int32] = [-1, -1]
        guard Sys.pipeClosedOnExec(&ends) == 0 else { return nil }
        var spawn = Platform.Spawn(executable: program, arguments: [program] + arguments)
        spawn.environment = environment
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.stdout = .descriptor(ends[1])
        spawn.stderr = .path("/dev/null", flags: O_WRONLY)
        spawn.group = .ownGroup
        let started = spawn.start()
        Sys.close(ends[1])
        defer { Sys.close(ends[0]) }
        guard case .success(let pid) = started else { return nil }

        let clock = MacTime.real
        let deadline = clock.awake() + timeout
        var output: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        var timedOut = false
        while true {
            let left = deadline - clock.awake()
            guard left > 0 else { timedOut = true; break }
            var watched = pollfd(fd: ends[0], events: Int16(POLLIN), revents: 0)
            let woke = poll(&watched, 1, Int32(max(1, min(left * 1_000, 1_000))))
            if woke < 0, errno == EINTR { continue }
            if woke == 0 { continue }
            let got = Sys.read(ends[0], &chunk, chunk.count)
            if got < 0, errno == EINTR || errno == EAGAIN { continue }
            guard got > 0 else { break }
            output.append(contentsOf: chunk[0..<got])
        }
        if timedOut { Sys.kill(-pid, SIGKILL) }
        // Its output has ended (or it was killed): collected by its pid, the wait bounded; past it, killed and
        // collected for 10 s more.
        var status: Int32 = 0
        var collectBy = clock.awake() + (timedOut ? 10 : timeout)
        var killed = timedOut
        while true {
            let reaped = waitpid(pid, &status, WNOHANG)
            if reaped == pid { break }
            if reaped < 0, errno != EINTR { return nil }
            if clock.awake() >= collectBy {
                guard !killed else { return nil }
                Sys.kill(-pid, SIGKILL)
                killed = true
                collectBy = clock.awake() + 10
            }
            usleep(2_000)
        }
        guard !killed else { return nil }
        let signal = status & 0x7f
        return (signal == 0 ? (status >> 8) & 0xff : 128 + signal, String(decoding: output, as: UTF8.self))
    }
}
