import Foundation
import Testing
import VibeCore
import VibeNode

/// A scratch node started as processes, for the server's and the command line's tests (the engine plan's E1): a
/// scratch session host started as stage 2's `TestHosts.authorize` starts one (the test process its app too, through
/// a connector given as `--test-app-pid`/`--test-app-connector`), with the built `vibeswitcher-server` as its server
/// child, on a short scratch root of its own (a socket's path fits in `sun_path`).
///
/// - `VIBESWITCHER_HOME` is the root, and `<home>/.vibeswitcher` a link to it (the sessions' HOME is `<home>`); the host listens on `<root>/host.sock`, locks `<root>/scratch-host.lock`, and
///   takes `--node-root <root>/build`, whose `bin/` holds links to the built products and whose `build-info` records
///   each one's SHA-256 (stage 2's `BuildInfo`), so the host's start check (Task 9b) passes and stays exercised.
/// - `<root>/v2/test/` holds the stand-ins of the Global Constraints: a recording journal socket (`journal.sock`,
///   each datagram recorded with its sender's credentials as journald stamps them, in `journal.jsonl`; without a
///   cgroup, as for a writer that ended first, while `recorder.writersEnded`), a stand-in
///   `journalctl` (that record) and `systemctl` (how the unit last ended from `unit-state` when a test writes it, E8),
///   `claude` linked to `FakeClaude`'s launcher (EN-D13), and
///   `user-scopes`, the test's scopes for the command line's journal check.
/// - `userScopes` (by default this process's own cgroup, `ownScope`) goes to the server as `--server-arg
///   --test-user-scopes=…`; nil leaves the server on the weaker rule. When this process runs inside the user's systemd
///   manager (`cgroupRoot`: a run a session of the node started, as its merge gate does), the server and the journal's
///   stand-in read every cgroup from this process's own (`--server-arg --test-cgroup-root=…`), where `ownScope` is `/`.
///   When it runs under a branch code runner (`runnerAbove`: a merge's or an audit's run of the tests), the server
///   doesn't count the runners above itself as a sender's (`--server-arg --test-runner-above`). `housekeeping`: `--server-arg --test-housekeeping=…`. `testChild`:
///   `--server-arg --test-child=…`. `path`: the host's PATH. `holdFirstLook`: `--hold-first-look`, and
///   `--server-arg --test-first-look` so the server's engine knows (E4; `serverKnowsFirstLook: false` leaves that out, for
///   a case that shows the vault's own hold with the engine's gate away, E8). `socketName`: the
///   host's socket in the root (another than `host.sock` isn't the root's: its server refuses it). `waitForServer`:
///   returns once the server answers, its link to the host welcomed.
///
/// `owner`: the process the host ends with (`--exit-with`; this test process by default), sessions and server and all,
/// however it goes: a runner killed or crashed leaves no node running (a host with a live session is never idle, so its
/// `--idle-exit` never comes, and `ScratchNodes`' end at exit never runs then).
///
/// `build`: an installed build folder (`<prefix>/<commit>`, the start plan's S4c) to run instead of `<root>/build`, as
/// `--node-root` and the `--server` and host it names. `hostArguments`: more of the host's arguments (its test flags).
/// `installRoot`: the install folder `build.switch` switches in (S8b): the server's `--server-arg --test-install-root=`,
/// and the host's `--install-root`, so the host checks each handover's target as the node's host does
/// (`HandoverTarget`); builds go there with `ScratchBuilds.install(commit:into:)`. `claudeProgram`: the name the fake
/// Claude runs by (`FakeClaude.install(in:program:)`).
///
/// `reusing`: the root of a node stopped before (its host ended), for a host restart (E8): its files are kept (its
/// `engine.json`, its snapshot, its journal's record, its repositories), its links and stand-ins made again where missing.
///
/// Ended, with its server, sessions and files, by `stop()` or when it goes; with every process whose environment names
/// a path in its root too, the ones that left the host's tree included (`stop()`).
final class ScratchNode: @unchecked Sendable {
    let root: URL
    let home: URL
    let nodeRoot: URL
    let socket: String
    let lock: String
    let output: String
    let testFolder: URL
    /// The host, started with `Platform.Spawn` (not Foundation's `Process`: one of those whose child closes the
    /// descriptor Foundation watches for its exit, as a handover's new image does, holds Foundation's one thread for
    /// children's exits in a `waitpid` until it ends, and no other child's exit is seen meanwhile, E8).
    private(set) var process = SpawnedHost(pid: 0)
    let recorder: JournalRecorder?
    /// The fake Claude its `claude` link names (EN-D13): a lead the server starts runs it.
    let fake: FakeClaude.Install
    private var testEnd: Int32 = -1
    private var stopped = false
    private let lockForStop = NSLock()

    /// This process's own cgroup path as the machine has it (the unified hierarchy's, or systemd's v1 line's).
    static let ownCgroup: String? = Platform.Processes.cgroup(getpid()).flatMap { PeerFacts.unifiedPath($0) ?? PeerFacts.systemdPath($0) }

    /// The root a scratch node of this run reads cgroups from (`ServerArguments.testCgroupRoot`): this process's own
    /// cgroup when the run is inside the user's systemd manager or the node's unit, where the voice rule refuses every
    /// path whatever scopes a test gives (`VoiceRule.cgroupRefusal`), so the test process could never speak as the
    /// user. That is a run a session of the node started: its tool server's merge gate, a worker's shell. nil
    /// everywhere else (a terminal's `/init.scope`, a CI runner, the Mac): there the real paths are read, as ever.
    static let cgroupRoot: String? = cgroupRoot(own: ownCgroup, uid: getuid())

    /// `cgroupRoot` for a process in `own`.
    static func cgroupRoot(own: String?, uid: uid_t) -> String? {
        guard let own, PeerFacts.isCgroupRoot(own) else { return nil }
        let components = own.split(separator: "/").map(String.init)
        return components.contains("user@\(uid).service") || components.contains(VoiceRule.nodeUnit) ? own : nil
    }

    /// Whether this process runs under a branch code runner (`BranchCode.wrapper`), as it does when the lead's tool
    /// server runs the tests for a merge or an audit, or a verifier's shell does: every sender of this run is then
    /// under that runner, which the voice rule refuses, so the test process could never speak as the user. A scratch
    /// node of such a run tells its server (`ServerArguments.testRunnerAbove`), which then leaves out the runners
    /// above itself and no other. Not from a terminal, a worker's shell, CI or the Mac: there every runner counts.
    static let runnerAbove = !PeerFacts.runners(above: getpid()).isEmpty

    /// This process's own cgroup as a scratch node of this run reads it: `/` from `cgroupRoot`, else the machine's path.
    static let ownScope: String? = cgroupRoot == nil ? ownCgroup : "/"

    /// `lines` as a scratch node of this run reads them: from `cgroupRoot`, when there is one.
    static func scratchCgroup(_ lines: [String]) -> [String] { cgroupRoot.map { PeerFacts.rerooted(lines, at: $0) } ?? lines }

    init(_ scratch: Scratch, userScopes: [String]? = ScratchNode.ownScope.map { [$0] }, housekeeping: Int? = nil,
         path: String = "/usr/bin:/bin", holdFirstLook: Bool = false, serverKnowsFirstLook: Bool = true, testChild: String? = nil,
         socketName: String = "host.sock", sealLife: Int? = nil, owner: pid_t = getpid(), reusing: URL? = nil, waitForServer: Bool = true,
         build: URL? = nil, hostArguments: [String] = [], installRoot: URL? = nil, claudeProgram: String = "claude",
         hostPrefix: [String] = [], hostBacktrace: Bool = false, noInotify: Bool = false, listsUnhosted: Bool = false) async throws {
        root = try reusing ?? scratch.shortFolder("vsn")
        home = root.appendingPathComponent("home", isDirectory: true)
        nodeRoot = build ?? root.appendingPathComponent("build", isDirectory: true)
        socket = root.appendingPathComponent(socketName).path
        lock = root.appendingPathComponent(NodeCheck.scratchLock).path
        output = root.appendingPathComponent("host.out").path
        testFolder = root.appendingPathComponent("v2/test", isDirectory: true)
        let files = FileManager.default
        for folder in [home, root.appendingPathComponent("build/bin"), testFolder, root.appendingPathComponent("tmp"),
                       testFolder.appendingPathComponent("xdg-runtime"), testFolder.appendingPathComponent("xdg-config")] {
            try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // As on the user's node, a session finds the node's root through its HOME (`<home>/.vibeswitcher`): the lead is
        // given `VIBESWITCHER_HOME` (`LeadEngine.environment`), but the workers and verifiers its tool server starts
        // aren't, and their tool servers and hooks reach this node's host and inboxes only so (E9).
        let homeRoot = home.appendingPathComponent(".vibeswitcher")
        if (try? files.destinationOfSymbolicLink(atPath: homeRoot.path)) == nil {
            try files.createSymbolicLink(atPath: homeRoot.path, withDestinationPath: root.path)
        }
        let fakeFolder = testFolder.appendingPathComponent("fake-claude", isDirectory: true)
        if reusing == nil {
            if build == nil { try Self.install(into: nodeRoot) }
            try Self.standIns(in: testFolder, scopes: userScopes)
            // The node's `claude` (EN-D13): a link a test puts there, to the fake's launcher.
            fake = try FakeClaude.install(in: fakeFolder, program: claudeProgram)
            try files.createSymbolicLink(atPath: testFolder.appendingPathComponent("claude").path, withDestinationPath: fake.launcher.path)
        } else {
            // A host restart on the same root: what the node before made stays (the journal's record too).
            fake = FakeClaude.Install(launcher: fakeFolder.appendingPathComponent("fake-bin/claude"), folder: fakeFolder.appendingPathComponent("fake"))
            try? files.removeItem(at: testFolder.appendingPathComponent("journal.sock"))
        }
        recorder = try JournalRecorder(folder: testFolder)
        files.createFile(atPath: output, contents: nil)

        var arguments = ["--socket", socket, "--lock", lock, "--idle-exit", "600", "--log", root.appendingPathComponent("host.log").path,
                         "--server", nodeRoot.appendingPathComponent("bin/vibeswitcher-server").path, "--node-root", nodeRoot.path,
                         "--exit-with", String(owner)]
        if let userScopes { arguments += ["--server-arg", ServerArguments.testUserScopesFlag + userScopes.joined(separator: ",")] }
        // Inside the user's manager only: elsewhere the server reads each sender's cgroup as the machine has it.
        if let root = Self.cgroupRoot { arguments += ["--server-arg", ServerArguments.testCgroupRootFlag + root] }
        // Under a branch code runner only: elsewhere the server counts every runner in a sender's ancestry.
        if Self.runnerAbove { arguments += ["--server-arg", ServerArguments.testRunnerAboveFlag] }
        if let housekeeping { arguments += ["--server-arg", ServerArguments.testHousekeepingFlag + String(housekeeping)] }
        if let testChild { arguments += ["--server-arg", ServerArguments.testChildFlag + testChild] }
        // The vault holds its first look, and the server knows it (its engine refuses `lead` until the accepts, S7).
        if holdFirstLook { arguments += ["--hold-first-look"] + (serverKnowsFirstLook ? ["--server-arg", ServerArguments.testFirstLookFlag] : []) }
        // How long the vault's `.user` seals verify (the engine plan's EN-D11), for a test that waits one out.
        if let sealLife { arguments += ["--test-user-seal-life", String(sealLife)] }
        if let installRoot {
            arguments += ["--server-arg", ServerArguments.testInstallRootFlag + installRoot.path, "--install-root", installRoot.path]
        }
        // `noInotify`: the host and server make no inotify instance, as when the user has none left (their watches all
        // unmade). The census (`VIBESWITCHER_TEST_INOTIFY_CENSUS`, a folder, in the tests' environment): each writes a
        // file named by its pid there when it makes its instance, for a count of a mix's instances.
        if noInotify || ProcessInfo.processInfo.environment["VIBESWITCHER_TEST_NO_INOTIFY"] == "1" {
            arguments += ["--test-no-inotify", "--server-arg", ServerArguments.testNoInotifyFlag]
        }
        if let census = ProcessInfo.processInfo.environment["VIBESWITCHER_TEST_INOTIFY_CENSUS"], census.hasPrefix("/") {
            arguments += ["--test-inotify-census", census, "--server-arg", ServerArguments.testInotifyCensusFlag + census]
        }
        // `listsUnhosted`: the server lists the sessions its host didn't start too, as the user's node does.
        if listsUnhosted { arguments += ["--server-arg", ServerArguments.testListsUnhostedFlag] }
        arguments += hostArguments
        let executable = nodeRoot.appendingPathComponent("bin/vibeswitcher-host").path
        // The test process as the host's app too (stage 2's `TestHosts.connectAsApp`): one end of a pair as the host's
        // stdin, the other registered for its socket, so this process can start sessions on it.
        guard let (hostEnd, testEnd) = Platform.Sockets.pair(type: Platform.Sockets.seqpacket) else { throw CancellationError() }
        Platform.Sockets.enableCredentials(hostEnd)
        // `hostPrefix`: a program that execs the host after setting something up (util-linux's prlimit, say).
        var spawn = Platform.Spawn(executable: hostPrefix.first ?? executable,
                                   arguments: hostPrefix + [executable] + arguments + ["--test-app-pid", String(getpid()), "--test-app-connector", "0"])
        spawn.environment = ["HOME=\(home.path)", "CFFIXED_USER_HOME=\(home.path)", "VIBESWITCHER_HOME=\(root.path)", "SHELL=/bin/sh",
                             "PATH=\(path)", "TMPDIR=\(root.appendingPathComponent("tmp").path)/",
                             // As the node's unit gives its host (ST-D4): the host's start line says it (S5). The
                             // host-probe nightly's (`hostBacktrace`) asks the trace of a crash on its stderr.
                             hostBacktrace ? "SWIFT_BACKTRACE=enable=yes,interactive=no,output-to=stderr,symbolicate=full" : "SWIFT_BACKTRACE=enable=no"]
        spawn.stdin = .descriptor(hostEnd)
        spawn.stdout = .path(output, flags: O_WRONLY | O_APPEND)
        spawn.stderr = .path(output, flags: O_WRONLY | O_APPEND)
        self.testEnd = testEnd
        HostConnection.register(connector: testEnd, for: socket)
        defer { Sys.close(hostEnd) }
        switch spawn.start() {
        case .failure(let error): throw HostCall.Failure(description: "the scratch host didn't start (errno \(error.code))")
        case .success(let pid): process = SpawnedHost(pid: pid)
        }
        ScratchNodes.started(process.processIdentifier)
        if waitForServer {
            // Its link welcomed (the hello carries the host's start): before, a state change is answered `not-yet`.
            var last = "no attempt"
            let up = await eventually(timeout: 120) { [self] in
                switch WireClient.attempt(self) {
                case .success(let client): if client.hello.host.startedAt != nil { return true }; last = "a hello with no host start"
                case .failure(let why): last = why.description
                }
                return false
            }
            // Before the stop: what was running and how full this user's limits were while it waited.
            let state = up ? "" : upState(last: last)
            if !up { stop() }
            try #require(up, "the scratch node's server never answered: \(state)")
        }
    }

    deinit { stop() }

    /// The host's and its server's stderr and stdout so far.
    var said: String { (try? String(contentsOfFile: output, encoding: .utf8)) ?? "" }

    /// Why the server didn't come up, for the failure's message: the last attempt's failure (the connect's errno, no
    /// line, a first line that isn't a hello), whether the host and its server run, what they said (their output and
    /// the host's log), and this user's per-user counts against their limits (processes, terminals, inotify instances)
    /// and the machine's load.
    func upState(last: String) -> String {
        let host = kill(hostPID, 0) == 0 ? "running" : "gone (errno \(errno))"
        let server = serverPID.map { "pid \($0)" } ?? "none"
        let log = ((try? String(contentsOfFile: root.appendingPathComponent("host.log").path, encoding: .utf8)) ?? "unread")
            .split(separator: "\n").suffix(30).joined(separator: "\n")
        return "last attempt: \(last); host pid \(hostPID) \(host), server \(server), socket \(FileManager.default.fileExists(atPath: serverSocket) ? "there" : "missing"); "
            + "\(ScratchNodes.limits())\nhost.out:\n\(said.split(separator: "\n").suffix(30).joined(separator: "\n"))\nhost.log:\n\(log)"
    }

    var hostPID: pid_t { process.processIdentifier }

    /// The server's socket.
    var serverSocket: String { root.appendingPathComponent("v2/server.sock").path }

    /// The server running now (the host's child named so), when there is one.
    var serverPID: pid_t? {
        // Started from a sealed copy (`/proc/self/fd/N`), its name is the descriptor's number: known by its argv[0].
        Platform.Processes.children(hostPID).first { Platform.Processes.arguments($0).first == "vibeswitcher-server" }
    }

    /// The environment the command line runs with on this node: its root, a home of its own, `XDG_RUNTIME_DIR` and
    /// `XDG_CONFIG_HOME` in scratch folders and no `DBUS_SESSION_BUS_ADDRESS` (defence in depth: the command line reads
    /// none of them in node mode, the start plan's ST-D2), and `extra`.
    func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in ["CLAUDE_CONFIG_DIR", "CODEX_HOME", PeerFacts.sessionMarkerName, "DBUS_SESSION_BUS_ADDRESS"] { environment[key] = nil }
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["VIBESWITCHER_HOME"] = root.path
        environment["TMPDIR"] = root.appendingPathComponent("tmp").path + "/"
        environment["XDG_RUNTIME_DIR"] = testFolder.appendingPathComponent("xdg-runtime").path
        environment["XDG_CONFIG_HOME"] = testFolder.appendingPathComponent("xdg-config").path
        return environment.merging(extra) { $1 }
    }

    /// The built command line on this node, stdin /dev/null.
    func run(_ arguments: [String], _ extra: [String: String] = [:]) async throws -> CommandRun {
        try await VibeNodeTests.run(commandLine, arguments, environment: environment(extra))
    }

    /// The built command line, on a pty of its own (`runOnTerminal`, the code shown typed) when `tty`, else with stdin
    /// /dev/null (`run(_:_:)`): the plan's form.
    func run(_ arguments: [String], tty: Bool) async throws -> CommandRun {
        tty ? try await runOnTerminal(arguments) : try await run(arguments)
    }

    /// The built command line on a pty of its own (`script`), answering a typed word with `answer` (the code shown, by
    /// default, or nil for none): its status and what the terminal showed.
    func runOnTerminal(_ arguments: [String], answer: @escaping @Sendable (String) -> String? = { $0 }) async throws -> CommandRun {
        try await ScratchNodes.onTerminal(commandLine.path, arguments, environment: environment(), answer: answer)
    }

    /// Ends the host (SIGTERM, then SIGKILL), waits for its server to go, ends what is left of it, and removes the
    /// registration. Once.
    ///
    /// What was under the host before its SIGTERM is waited for, then killed; then every process still naming a path in
    /// the root in its environment (`endStrays`): one that was never in the host's tree when it was listed (started
    /// meanwhile, as a lead's fake starts tool servers while a stop runs, or with the host gone before this), or one
    /// that left it (an orphaned tool server whose keeper was killed) would write into the root once it is removed.
    func stop() {
        let first = lockForStop.withLock { () -> Bool in
            defer { stopped = true }
            return !stopped
        }
        guard first else { return }
        let server = serverPID
        let host = hostPID
        // Every process under the host now (its server, the sessions' shells and agents, their tool servers and hooks),
        // each known by its start too: once the host is gone they're init's, and one still ending writes into the root
        // while the scratch is removed (the E8 review's leftover `vsn-` root under load).
        let under = host > 0 ? Self.descendants(of: host) : []
        if host > 0, process.isRunning {
            kill(host, SIGTERM)
            let deadline = MacTime.real.awake() + 10
            while process.isRunning, MacTime.real.awake() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(host, SIGKILL) }
            let killed = MacTime.real.awake() + 30
            while process.isRunning, MacTime.real.awake() < killed { Thread.sleep(forTimeInterval: 0.02) }
        }
        if let server {
            let deadline = MacTime.real.awake() + 10
            while kill(server, 0) == 0, MacTime.real.awake() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if kill(server, 0) == 0 { kill(server, SIGKILL) }
        }
        Self.waitForEnd(under)
        Self.endStrays(of: root.path)
        ScratchNodes.ended(host)
        recorder?.stop()
        if HostConnection.connector(for: socket) == testEnd { HostConnection.unregister(path: socket) }
        if testEnd >= 0 { Sys.close(testEnd) }
    }

    /// The processes under `pid` (children, theirs, and so on), each with its start (`Platform.Processes.link`). Each
    /// is read after its parent's listing, so only one whose link still names that parent counts: a child that ended
    /// meanwhile and whose pid went to another process isn't taken for it (that one has another parent), and one whose
    /// parent ended meanwhile is left to `endStrays`. `children` and `link`: the system's, or a test's.
    static func descendants(of pid: pid_t, children: (pid_t) -> [pid_t] = Platform.Processes.children,
                            link: (pid_t) -> Platform.Processes.Link? = Platform.Processes.link) -> [Platform.Processes.Link] {
        var found: [Platform.Processes.Link] = []
        var next = children(pid).map { (pid: $0, parent: pid) }
        while let (child, parent) = next.popLast() {
            guard let link = link(child), link.parent == parent, !found.contains(where: { $0.pid == child }) else { continue }
            found.append(link)
            next += children(child).map { (pid: $0, parent: child) }
        }
        return found
    }

    /// Whether the process `link` names still runs: its pid with the same start (not a later process given the number),
    /// and not a zombie.
    static func runs(_ link: Platform.Processes.Link) -> Bool {
        guard Platform.Processes.link(link.pid)?.startTicks == link.startTicks else { return false }
        return Platform.Processes.kernelRecord(link.pid)?.state != .zombie
    }

    /// Waits for each of `processes` to end, 10 s (they had their hangup with the host's terminals), then ends those
    /// still running (SIGKILL, each checked by its start first) and waits 10 s more.
    static func waitForEnd(_ processes: [Platform.Processes.Link]) {
        var running = processes
        for (index, wait) in [10.0, 10.0].enumerated() {
            let deadline = MacTime.real.awake() + wait
            while true {
                running = running.filter(runs)
                if running.isEmpty || MacTime.real.awake() >= deadline { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
            guard index == 0 else { break }
            for link in running where runs(link) { kill(link.pid, SIGKILL) }
        }
    }

    /// This user's processes (this one aside) whose environment names `root` or a path in it (HOME, VIBESWITCHER_HOME,
    /// TMPDIR, PWD: every process of a node's has some), each with its start.
    static func strays(of root: String) -> [Platform.Processes.Link] {
        let me = getpid(), inside = root + "/"
        return (Platform.Processes.allPids() ?? []).compactMap { pid in
            guard pid != me, let environment = Platform.Processes.environment(pid) else { return nil }
            let names = environment.contains { entry in
                guard let equals = entry.firstIndex(of: "=") else { return false }
                let value = entry[entry.index(after: equals)...]
                return value == root || value.hasPrefix(inside)
            }
            return names ? Platform.Processes.link(pid) : nil
        }.filter(runs)
    }

    /// Kills `root`'s strays (SIGKILL, each checked by its start first) and waits for them to end, again until a look
    /// finds none (one may start another meanwhile), for 30 s at most: each wait after the kills ends at that deadline
    /// too, not 10 s past it.
    static func endStrays(of root: String) {
        let deadline = MacTime.real.awake() + 30
        while MacTime.real.awake() < deadline {
            var found = strays(of: root)
            if found.isEmpty { return }
            for link in found where runs(link) { kill(link.pid, SIGKILL) }
            let killed = min(MacTime.real.awake() + 10, deadline)
            while !found.isEmpty, MacTime.real.awake() < killed {
                Thread.sleep(forTimeInterval: 0.02)
                found = found.filter(runs)
            }
        }
    }

    /// Starts `command` (a shell line) in a new session of this node's host, as its app, and returns it. `agent`: the
    /// agent the host records it was started as (`HostedAgents`: a session started as none is no agent's, whatever its
    /// program is named).
    func spawn(_ command: String, cwd: String? = nil, label: String = "Test", agent: String? = nil) async throws -> HostSession {
        let request = SpawnRequest(cwd: cwd ?? home.path, command: command, env: [:], cols: 100, rows: 30, keepShell: false,
                                   label: label, agent: agent)
        let reply = try await offPool { [socket] in try HostCall.request(.spawn(request), socket: socket, appKey: nil, timeout: 60) }
        guard case .spawned(let session) = reply else { throw HostCall.Failure(description: "the scratch host didn't start the session: \(reply)") }
        return session
    }

    /// The host's sessions now.
    func sessions() throws -> [HostSession] { try HostCall.sessions(socket: socket, appKey: nil) }

    /// The machine's limits under the node's root (`mac-limits.json`, which the leads' tool servers and the room watch
    /// read at each call): `maxSessions` team sessions at most, and no load or memory hold. A case that starts a
    /// worker or a verifier and isn't about the machine's room sets it: the test machine's own load isn't the case's
    /// (a CI runner's 4 cores under the suite run past twice their count, and `start_worker` refuses there).
    func noLoadHold(maxSessions: Int = MacLimits.defaultMaxSessions) throws {
        try MacLimits(maxSessions: maxSessions, loadThreshold: 1_000_000, memoryPressure: "off", swapOutRate: 0)
            .save(to: root.appendingPathComponent("mac-limits.json"))
    }

    // MARK: The build folder and the stand-ins

    /// The built products this node's `bin/` links to.
    /// The commit the scratch build's `build-info` records: what the host's start line and its notes name (S5).
    static let commit = String(repeating: "0", count: 40)

    static let products = ["vibeswitcher-host", "vibeswitcher-server", "vibeswitcher-mcp", "vibeswitcher-hook", "vibeswitcher-cli"]

    /// Each product's SHA-256, read once per run.
    private static let hashes: [String: String] = {
        var hashes: [String: String] = [:]
        for name in products {
            if let data = FileManager.default.contents(atPath: builtProducts.appendingPathComponent(name).path) {
                hashes[name] = BuildInfo.sha256(of: data)
            }
        }
        return hashes
    }()

    /// `<folder>/bin/<product>` linked to each built product, and `<folder>/build-info` recording them.
    static func install(into folder: URL) throws {
        for name in products {
            try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("bin/" + name).path,
                                                       withDestinationPath: builtProducts.appendingPathComponent(name).path)
        }
        let info = BuildInfo(commit: commit, binaries: hashes, swift: "test", resolved: String(repeating: "0", count: 64))
        try info.encoded.write(to: folder.appendingPathComponent(BuildInfo.fileName))
    }

    /// The stand-ins in `<root>/v2/test/`.
    static func standIns(in folder: URL, scopes: [String]?) throws {
        let record = folder.appendingPathComponent("journal.jsonl").path
        FileManager.default.createFile(atPath: record, contents: nil)
        try script("#!/bin/sh\ncat '\(record)'\nexit 0\n", at: folder.appendingPathComponent("journalctl"))
        try script("""
            #!/bin/sh
            case "$*" in
              *show-environment*) printf 'HOME=/home/test\\nLANG=C.UTF-8\\nPATH=/usr/bin:/bin\\nUSER=test\\nXDG_RUNTIME_DIR=/run/user/1000\\n' ;;
              *ExecMainStartTimestamp*) if [ -f '\(folder.path)/unit-state' ]; then cat '\(folder.path)/unit-state'; else printf 'Result=success\\nExecMainStatus=0\\nExecMainStartTimestamp=\\n'; fi ;;
            esac
            exit 0

            """, at: folder.appendingPathComponent("systemctl"))
        if let scopes { try (scopes.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("user-scopes"), atomically: true, encoding: .utf8) }
        // The binfmt_misc entries and mounts the command line reads on this node: interop off (both of WSL's entries,
        // as a machine with systemd has them), unless a test says otherwise.
        let binfmt = folder.appendingPathComponent("binfmt_misc", isDirectory: true)
        try FileManager.default.createDirectory(at: binfmt, withIntermediateDirectories: true)
        for (name, text) in ["WSLInterop": "disabled\ninterpreter /init\nflags: PF\n", "WSLInterop-late": "disabled\ninterpreter /init\nflags: P\n",
                             "status": "enabled\n"] {
            try text.write(to: binfmt.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try "".write(to: folder.appendingPathComponent("mounts"), atomically: true, encoding: .utf8)
    }

    /// A script at `url`, executable, written through a copy (no test process holds it open for writing, so no child
    /// started meanwhile makes running it fail with ETXTBSY).
    static func script(_ text: String, at url: URL) throws {
        let source = url.appendingPathExtension("txt")
        try text.write(to: source, atomically: true, encoding: .utf8)
        guard try runToEnd("/bin/cp", [source.path, url.path]) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

/// Installed builds for a scratch node's switches (the start plan's S8b): `<installRoot>/<commit>`, as `install-node.sh`
/// lays one out, but from the built products.
enum ScratchBuilds {
    /// `<installRoot>/<commit>/bin/` holding copies of the built products (real files, not links: the record and the
    /// host's handover check refuse a link), its `build-info` written by `BuildRecord` (the install's own writer), and
    /// `<commit> <ISO time>` appended to `<installRoot>/installs`. The cli keeps its built name, `vibeswitcher-cli`
    /// (`BuildRecord` records whatever regular files `bin/` holds). `replacing`: a product's file taken from another
    /// path (the same name in `bin/`, recorded with its own bytes). The build's folder.
    @discardableResult
    static func install(commit: String, into installRoot: URL, replacing: [String: String] = [:]) throws -> URL {
        let folder = installRoot.appendingPathComponent(commit, isDirectory: true)
        let bin = folder.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        for name in ScratchNode.products {
            try copyClosedOnExec(replacing[name] ?? builtProducts.appendingPathComponent(name).path, to: bin.appendingPathComponent(name).path)
        }
        if case .failure(let refusal) = BuildRecord.write(folder: folder.path, commit: commit, swiftVersionOutput: "test", resolved: Data()) {
            throw HostCall.Failure(description: refusal.text)
        }
        let line = "\(commit) \(ISO8601DateFormatter().string(from: Date()))\n"
        let installs = installRoot.appendingPathComponent("installs")
        if let handle = FileHandle(forWritingAtPath: installs.path) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
        } else {
            try line.write(to: installs, atomically: true, encoding: .utf8)
        }
        return folder
    }
}

/// journald's stand-in on a scratch node: a datagram socket at `<folder>/journal.sock`, each entry (journald's native
/// form, `Platform.Journal.decode`) recorded as one JSON line in `<folder>/journal.jsonl` with the fields journald
/// stamps from the sender's credentials (`_UID`, `_PID`, `_SYSTEMD_CGROUP`, read as the datagram comes) and
/// `__REALTIME_TIMESTAMP`, as `journalctl -o json` writes them. The cgroup is read as the node's server reads one
/// (`ScratchNode.scratchCgroup`: from this run's own cgroup when it is inside the user's manager).
///
/// `writersEnded`: while set, each entry is recorded as journald records one whose writer had ended before it read
/// `/proc/<pid>` (measured on the node, the bootstrap path's M4, 2026-11-17: `logger`'s entry): the credentials'
/// `_PID` and `_UID`, and no `_SYSTEMD_CGROUP`.
final class JournalRecorder: @unchecked Sendable {
    let path: String
    let record: String
    private let fd: Int32
    private let lock = NSLock()
    private var stopping = false
    private var ended = false
    var writersEnded: Bool {
        get { lock.withLock { ended } }
        set { lock.withLock { ended = newValue } }
    }
    private let done = DispatchSemaphore(value: 0)

    init(folder: URL) throws {
        path = folder.appendingPathComponent("journal.sock").path
        record = folder.appendingPathComponent("journal.jsonl").path
        #if canImport(Glibc)
        let datagram = Int32(SOCK_DGRAM.rawValue)
        #else
        let datagram = SOCK_DGRAM
        #endif
        fd = Platform.Sockets.makeSocket(type: datagram)
        guard fd >= 0, let address = Platform.Sockets.unixAddress(path),
              Platform.Sockets.bindOwnerOnly(fd, to: address, path: path, mode: 0o600) == nil else { throw CancellationError() }
        Platform.Sockets.enableCredentials(fd)
        let thread = Thread { [self] in serve() }
        thread.name = "journal-recorder"
        thread.start()
    }

    private func serve() {
        defer { done.signal() }
        var buffer = [UInt8](repeating: 0, count: 70_000)
        while !lock.withLock({ stopping }) {
            var watched = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&watched, 1, 100) > 0 else { continue }
            let (count, sender) = buffer.withUnsafeMutableBytes { Platform.Sockets.receive(fd, into: $0) }
            guard count > 0, let fields = Platform.Journal.decode(Data(buffer[0..<count])) else { continue }
            var entry: [String: String] = [:]
            for (name, value) in fields { entry[name] = value }
            if let sender {
                entry["_PID"] = String(sender.pid)
                if case .record(let record) = Platform.Processes.record(sender.pid), let uid = record.uid { entry["_UID"] = String(uid) }
                if !writersEnded, let lines = Platform.Processes.cgroup(sender.pid).map(ScratchNode.scratchCgroup),
                   let cgroup = PeerFacts.unifiedPath(lines) ?? PeerFacts.systemdPath(lines) {
                    entry["_SYSTEMD_CGROUP"] = cgroup
                }
            }
            entry["__REALTIME_TIMESTAMP"] = String(Int64(Date().timeIntervalSince1970 * 1_000_000))
            append(entry)
        }
    }

    /// One more entry in the record, as given (a test's own unit lines or forged ones).
    func append(_ entry: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        lock.withLock {
            guard let handle = FileHandle(forWritingAtPath: record) else { return }
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        }
    }

    /// The entries recorded so far.
    var entries: [JournalEntry] {
        NodeJournal.entries(json: (try? String(contentsOfFile: record, encoding: .utf8)) ?? "")
    }

    func stop() {
        let first = lock.withLock { () -> Bool in
            defer { stopping = true }
            return !stopping
        }
        guard first else { return }
        done.wait()
        Sys.close(fd)
    }
}

/// A client of a scratch node's server, as the command line is one, for the tests that speak the protocol themselves.
final class WireClient {
    let fd: Int32
    let hello: NodeWire.Hello
    private var lines = NodeWire.Lines()
    private var ready: [Data] = []
    private var counter = 0

    init(_ node: ScratchNode, timeout: TimeInterval = 10) throws {
        fd = try UnixSocket.connect(path: node.serverSocket)
        guard let first = Self.read(fd, &lines, &ready, until: Date().addingTimeInterval(timeout)),
              let hello = NodeWire.decode(NodeWire.Hello.self, first) else {
            Sys.close(fd)
            throw CancellationError()
        }
        self.hello = hello
    }

    deinit { Sys.close(fd) }

    /// Why an attempt failed, for a message.
    struct Failed: Error, CustomStringConvertible { let description: String }

    /// A client, or why none: the connect's failure (its errno), nothing within `timeout`, or a first line that isn't
    /// a hello (the server refusing the connection says so in its first line).
    static func attempt(_ node: ScratchNode, timeout: TimeInterval = 10) -> Result<WireClient, Failed> {
        let fd: Int32
        do { fd = try UnixSocket.connect(path: node.serverSocket) } catch { return .failure(Failed(description: "connect: \(error)")) }
        var lines = NodeWire.Lines(), ready: [Data] = []
        guard let first = read(fd, &lines, &ready, until: Date().addingTimeInterval(timeout)) else {
            Sys.close(fd)
            return .failure(Failed(description: "connected, no line within \(Int(timeout)) s"))
        }
        guard let hello = NodeWire.decode(NodeWire.Hello.self, first) else {
            Sys.close(fd)
            return .failure(Failed(description: "a first line that isn't a hello: \(String(decoding: first.prefix(300), as: UTF8.self))"))
        }
        return .success(WireClient(fd: fd, hello: hello, lines: lines, ready: ready))
    }

    private init(fd: Int32, hello: NodeWire.Hello, lines: NodeWire.Lines, ready: [Data]) {
        self.fd = fd
        self.hello = hello
        self.lines = lines
        self.ready = ready
    }

    /// Writes `line` (a newline added) as it is.
    func write(_ line: String) {
        let data = Data((line + "\n").utf8)
        _ = data.withUnsafeBytes { Platform.Sockets.send(fd, $0.baseAddress, $0.count) }
    }

    /// Sends a request and returns the messages up to its reply (the reply last), or up to a `bye` and the close.
    func request(_ kind: String, args: [String: NodeWire.Value]? = nil, action: String? = UUID().uuidString.lowercased(),
                 must: Bool? = nil, v: Int = NodeWire.version, timeout: TimeInterval = 60) -> [Data] {
        counter += 1
        let id = "t\(counter)"
        let request = NodeWire.Request(v: v, id: id, kind: kind, args: args, action: action, must: must)
        var line = NodeWire.line(request)
        line.removeLast()
        write(String(decoding: line, as: UTF8.self))
        return next(until: { NodeWire.decode(NodeWire.Envelope.self, $0)?.re == id }, timeout: timeout)
    }

    /// The messages that come until one `stop` accepts (it last), a `bye`, the close or `timeout`.
    func next(until stop: (Data) -> Bool = { _ in false }, timeout: TimeInterval = 10) -> [Data] {
        var got: [Data] = []
        let deadline = Date().addingTimeInterval(timeout)
        while let message = Self.read(fd, &lines, &ready, until: deadline) {
            got.append(message)
            if stop(message) || NodeWire.decode(NodeWire.Envelope.self, message)?.kind == "bye" { break }
        }
        return got
    }

    /// Whether the server closed the connection (a read gives its end) within `timeout`.
    func closed(within timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var chunk = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var watched = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&watched, 1, 100) > 0 else { continue }
            let count = Sys.read(fd, &chunk, chunk.count)
            if count == 0 { return true }
            if count < 0, errno != EAGAIN, errno != EINTR { return true }
        }
        return false
    }

    static func read(_ fd: Int32, _ lines: inout NodeWire.Lines, _ ready: inout [Data], until deadline: Date) -> Data? {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while ready.isEmpty {
            guard deadline.timeIntervalSinceNow > 0 else { return nil }
            var watched = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&watched, 1, 100) > 0 else { continue }
            let count = Sys.read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { return nil }
            ready += lines.append(Data(chunk[0..<count]))
        }
        return ready.removeFirst()
    }

    /// A reply among `messages`.
    static func reply(_ messages: [Data]) -> NodeWire.Reply? {
        messages.lazy.compactMap { message -> NodeWire.Reply? in
            guard NodeWire.decode(NodeWire.Envelope.self, message)?.re != nil else { return nil }
            return NodeWire.decode(NodeWire.Reply.self, message)
        }.first
    }

    /// A `bye` among `messages`.
    static func bye(_ messages: [Data]) -> NodeWire.Bye? {
        messages.lazy.compactMap { message -> NodeWire.Bye? in
            guard NodeWire.decode(NodeWire.Envelope.self, message)?.kind == "bye" else { return nil }
            return NodeWire.decode(NodeWire.Bye.self, message)
        }.first
    }
}

/// The scratch nodes' hosts started and not yet ended (ended at the runner's exit, as `TestHosts` ends its), and the
/// command line on a terminal.
enum ScratchNodes {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var running: Set<pid_t> = []
    private static let endedAtExit: Void = { atexit { ScratchNodes.killAll() } }()

    static func started(_ pid: pid_t) {
        _ = endedAtExit
        lock.withLock { _ = running.insert(pid) }
    }

    static func ended(_ pid: pid_t) { lock.withLock { _ = running.remove(pid) } }

    /// This user's per-user counts against their limits, and the load, for a failure's message: processes (\"Max processes\"),
    /// terminals (/dev/pts, kernel.pty.nr and .max), inotify instances (each `anon_inode:inotify` descriptor of the
    /// user's processes, against fs.inotify.max_user_instances), this process's descriptors (\"Max open files\"), scratch
    /// hosts running from this process. Where /proc has none of it (the Mac): what it has.
    static func limits() -> String {
        func read(_ path: String) -> String { ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "?").trimmingCharacters(in: .whitespacesAndNewlines) }
        var processes = 0, inotify = 0
        let me = getuid()
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? [] where Int32(entry) != nil {
            guard let owner = (try? FileManager.default.attributesOfItem(atPath: "/proc/\(entry)"))?[.ownerAccountID] as? NSNumber,
                  owner.uint32Value == me else { continue }
            processes += 1
            for fd in (try? FileManager.default.contentsOfDirectory(atPath: "/proc/\(entry)/fd")) ?? [] {
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(entry)/fd/\(fd)")) == "anon_inode:inotify" { inotify += 1 }
            }
        }
        // The soft limits, as /proc/self/limits gives them (no getrlimit: its resource type differs between the C libraries).
        func limit(_ name: String) -> String {
            read("/proc/self/limits").split(separator: "\n").first { $0.hasPrefix(name) }
                .map { $0.dropFirst(name.count).split(separator: " ").first.map(String.init) ?? "?" } ?? "?"
        }
        let own = ((try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")) ?? []).count
        let hosts = lock.withLock { running.count }
        let nofile = limit("Max open files")
        return "processes \(processes) of \(limit("Max processes")), "
            + "ptys \(read("/proc/sys/kernel/pty/nr")) of \(read("/proc/sys/kernel/pty/max")), "
            + "inotify instances \(inotify) of \(read("/proc/sys/fs/inotify/max_user_instances")), "
            + "this process's descriptors \(own) of \(nofile), scratch hosts \(hosts), load \(read("/proc/loadavg"))"
    }

    private static func killAll() { for pid in lock.withLock({ running }) { kill(pid, SIGKILL) } }

    /// `program` with `arguments` on a pty of its own (util-linux `script`), its terminal's output read as it comes;
    /// when it shows "Type CODE and Enter", `answer(CODE)` is typed (nothing when nil). Its status (the signal's number
    /// when one ended it, as Foundation's `terminationStatus`) and what it showed.
    ///
    /// `script` is started by `Platform.Spawn` (close-on-exec pipes as its stdin and output, nothing else of this
    /// process inherited, "Text file busy" tried again) and collected here by its pid with bounded waits off the pool
    /// (`SpawnedHost`, `exited`): not Foundation's `Process` (`run(_:_:environment:)`'s note). Past a guard of 120 s
    /// it is killed, and what it showed is read for 10 s more at most.
    static func onTerminal(_ program: String, _ arguments: [String], environment: [String: String],
                           answer: @escaping @Sendable (String) -> String?) async throws -> CommandRun {
        let line = ([program] + arguments).map(FakeClaude.quoted).joined(separator: " ")
        var input: [Int32] = [-1, -1], output: [Int32] = [-1, -1]
        guard Sys.pipeClosedOnExec(&input) == 0 else { throw Platform.Errno(code: errno) }
        guard Sys.pipeClosedOnExec(&output) == 0 else {
            let code = errno
            input.forEach { Sys.close($0) }
            throw Platform.Errno(code: code)
        }
        var spawn = Platform.Spawn(executable: "/usr/bin/script", arguments: ["/usr/bin/script", "-q", "-e", "-c", line, "/dev/null"])
        spawn.environment = environment.merging(["SHELL": "/bin/sh"]) { $1 }.map { "\($0.key)=\($0.value)" }
        spawn.stdin = .descriptor(input[0])
        spawn.stdout = .descriptor(output[1])
        spawn.stderr = .descriptor(output[1])
        let terminal: SpawnedHost
        do { terminal = SpawnedHost(pid: try await startRetrying(spawn)) } catch {
            (input + output).forEach { Sys.close($0) }
            throw error
        }
        // The child's ends are its own now.
        Sys.close(input[0])
        Sys.close(output[1])
        let (writing, reading) = (input[1], output[0])
        let shown = await offPool { () -> String in
            defer { Sys.close(reading) }
            var seen = Data()
            var answered = false, killed = false
            var deadline = MacTime.real.awake() + 120
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let now = MacTime.real.awake()
                if now >= deadline {
                    guard !killed else { break }
                    Sys.kill(terminal.processIdentifier, SIGKILL)
                    killed = true
                    deadline = now + 10
                }
                var watched = [pollfd(fd: reading, events: Int16(POLLIN), revents: 0)]
                guard poll(&watched, 1, 100) > 0 else { continue }
                let count = Sys.read(reading, &chunk, chunk.count)
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                if count <= 0 { break }
                seen.append(contentsOf: chunk[0..<count])
                let text = String(decoding: seen, as: UTF8.self)
                if !answered, let range = text.range(of: #"Type ([A-Z]{4}) and Enter"#, options: .regularExpression) {
                    answered = true
                    let code = String(text[range].dropFirst(5).prefix(4))
                    if let typed = answer(code) {
                        let bytes = Array((typed + "\r").utf8)
                        var done = 0
                        while done < bytes.count {
                            let wrote = bytes.withUnsafeBytes { Sys.write(writing, $0.baseAddress! + done, bytes.count - done) }
                            if wrote < 0, errno == EINTR { continue }
                            guard wrote > 0 else { break }
                            done += wrote
                        }
                    }
                }
            }
            return String(decoding: seen, as: UTF8.self)
        }
        Sys.close(writing)
        #expect(await exited(terminal, within: 120), "\(arguments.joined(separator: " ")) on a terminal never ended")
        let raw = terminal.waitStatus ?? -1
        let status = raw < 0 ? -1 : raw & 0x7f == 0 ? (raw >> 8) & 0xff : raw & 0x7f
        return CommandRun(status: status, output: shown, errors: "")
    }
}

/// A child started with `Platform.Spawn`, reaped by its own pid (`waitpid` with `WNOHANG`, never a wait for any child):
/// what `Process` gives of one, for a scratch node's host.
final class SpawnedHost: @unchecked Sendable {
    let processIdentifier: pid_t
    private let lock = NSLock()
    private var status: Int32?

    init(pid: pid_t) { processIdentifier = pid }

    /// Whether it still runs (it is reaped here once it ended).
    var isRunning: Bool {
        lock.withLock {
            guard processIdentifier > 0, status == nil else { return false }
            var raw: Int32 = 0
            let reaped = waitpid(processIdentifier, &raw, WNOHANG)
            if reaped == processIdentifier { status = raw } else if reaped < 0, errno == ECHILD { status = -1 }
            return status == nil
        }
    }

    /// Its wait status once it ended (-1: reaped elsewhere), nil while it runs.
    var waitStatus: Int32? {
        _ = isRunning
        return lock.withLock { status }
    }
}

/// Whether `host` ended within `timeout`; SIGKILLed (and waited for, 10 s at most) when it didn't.
func exited(_ host: SpawnedHost, within timeout: TimeInterval = hangGuard) async -> Bool {
    await offPool {
        let deadline = MacTime.real.awake() + timeout
        while host.isRunning, MacTime.real.awake() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard host.isRunning else { return true }
        kill(host.processIdentifier, SIGKILL)
        let killed = MacTime.real.awake() + 10
        while host.isRunning, MacTime.real.awake() < killed { Thread.sleep(forTimeInterval: 0.01) }
        return false
    }
}
