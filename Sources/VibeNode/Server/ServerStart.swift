import Foundation
import VibeCore

/// `vibeswitcher-server`'s start after its first statements (the engine plan's E1; its `main.swift` makes those, in
/// their canonical order: the inherited image closed, hardened, a traced server's exit 75, the connector marked
/// close-on-exec, SIGPIPE settled). Then: the root (EN-D3); exit 78 unless `--host-socket` is the root's host socket;
/// exit 69 without a git only root can change (stage 2's Task 10c); the connector registered for the host's socket, so
/// every `VibeCore` call that reaches the host goes through it; `HostLink` on `ConnectorDialer`; `NodeSessions`; the
/// server's socket; `dispatchMain()`. The host gone (its end of the connector closed, or the link gone) ends the
/// server with a log line. It never closes or shuts down its connector itself: it exits with it open (the host
/// SIGKILLs a server whose connector closed while it ran). It never execs (`ServerLintTests.theServerNeverExecs`).
public enum ServerStart {
    /// Whether something traces this process (`TracerPid` isn't 0, or can't be read), on Linux; never on the Mac,
    /// which has no server child.
    public static var isTraced: Bool {
        !Platform.CodeIdentity.isAvailable && Platform.ProcessSelf.tracer() != 0
    }

    /// The connector named in `arguments` made close-on-exec: it arrives kept, so inheritable, and no child of the
    /// server may hold it.
    public static func markConnector(_ arguments: [String]) {
        guard let connector = ServerArguments.connector(in: arguments) else { return }
        _ = fcntl(connector, F_SETFD, fcntl(connector, F_GETFD) | FD_CLOEXEC)
    }

    /// What the user's server (`--node`) sets `VIBESWITCHER_HOME` to, the account's home `accountHome` from the user
    /// database: nil (unset, the root then `<HOME>/.vibeswitcher`) where the node's root is the account's own folder
    /// (Linux), else the node's root (the Mac's `~/.vibeswitcher/v2/node`). Never the environment's.
    public static func nodeRootVariable(accountHome: String) -> String? {
        Platform.Service.nodeRootIsTheAccountRoot ? nil : NodeFolders.nodeRoot(accountHome: accountHome)
    }

    /// A line on the server's stderr, which the host's stderr is (the unit sends it to the journal).
    public static func say(_ line: String) {
        FileHandle.standardError.write(Data("vibeswitcher-server: \(line)\n".utf8))
    }

    /// The rest of the start; never returns.
    public static func run(_ arguments: [String]) -> Never {
        let parsed: ServerArguments
        switch ServerArguments.parse(arguments) {
        case .failure(let usage):
            say("not started: \(usage)")
            exit(64)
        case .success(let given):
            parsed = given
        }
        for flag in parsed.refused { say("refused \(flag): the user's server takes no test flags") }

        // The root, before anything reads VibePaths (EN-D3).
        var accountHome: String?
        if parsed.node {
            guard let home = getpwuid(getuid()).map({ String(cString: $0.pointee.pw_dir) }), home.hasPrefix("/") else {
                say("not started: the account has no home in the user database")
                exit(78)
            }
            accountHome = home
            setenv("HOME", home, 1)
            // The node's root: the account's ~/.vibeswitcher on Linux (VIBESWITCHER_HOME unset), its own folder beside
            // the app's on the Mac (`Platform.Service.nodeRoot`), named so.
            if let own = nodeRootVariable(accountHome: home) { setenv("VIBESWITCHER_HOME", own, 1) } else { unsetenv("VIBESWITCHER_HOME") }
            unsetenv("CFFIXED_USER_HOME")
        } else if let root = parsed.root {
            setenv("VIBESWITCHER_HOME", root, 1)
        }
        let root = VibePaths.root
        guard ServerArguments.isRootsHostSocket(parsed.hostSocket, root: root) else {
            say("not started: --host-socket \(parsed.hostSocket) isn't this root's host socket (\(VibePaths.hostSocket.path))")
            exit(78)
        }
        guard Platform.Tools.git != Platform.Tools.absentGit else {
            say("not started: no git on PATH in a folder owned by root that only root can write")
            exit(69)
        }
        if let child = parsed.testChild { startTestChild(child) }

        HostConnection.register(connector: parsed.connector, for: parsed.hostSocket)
        watchConnector(parsed.connector)

        let queue = DispatchQueue(label: "vibeswitcher-server.engine")
        let clock = NodeClock(queue: queue)
        let link = HostLink(dialer: ConnectorDialer(path: parsed.hostSocket), root: root, queue: queue, clock: clock, note: say)
        link.onGone = { why in
            say("the session host is gone (\(why)): exiting")
            exit(0)
        }
        // A scratch node (a root other than the account's) lists only the sessions its host started.
        let sessions = NodeSessions(root: root, home: VibePaths.home, queue: queue, link: link, clock: clock,
                                    onlyHosted: !NodeFolders.isUsersRoot(root, accountHome: VibePaths.accountHome), note: say)
        sessions.marks = SessionMarks(root: root)
        let rule = VoiceRule.at(start: Platform.Processes.cgroup(getpid()), testScopes: parsed.testUserScopes, usersNode: parsed.node)
        say("voice rule: \(rule.says)")
        if let root = parsed.testCgroupRoot { say("a scratch node's test: each sender's cgroup is read from \(ConfigSeal.inert(root, limit: .max))") }
        // Read once, here, of this process alone: no argument, file or request names a runner.
        let runnersAbove = parsed.testRunnerAbove ? PeerFacts.runners(above: getpid()) : []
        if parsed.testRunnerAbove {
            let pids = runnersAbove.map { String($0.pid) }.joined(separator: ", ")
            say("a scratch node's test: the branch code runners this server itself runs under (\(pids.isEmpty ? "none found" : "pid \(pids)")) aren't counted as a sender's")
        }
        let commit = parsed.nodeRoot.flatMap { folder -> String? in
            if case .success(let info) = BuildInfo.read(buildFolder: folder) { return info.commit } else { return nil }
        } ?? "unknown"
        let requests = Requests(link: link, sessions: sessions, rule: rule, root: root, hostSocket: parsed.hostSocket,
                                commit: commit, note: say)
        var options = LeadEngine.Options()
        options.firstLook = parsed.node || parsed.testFirstLook
        // A held `.user` message is the user's after a restart only when the vault's record holds its action (EN-D9, E6).
        options.userActions = VaultUserActions(client: link.vaultV2)
        // The finished tasks' role sessions end (E7); the user's node's witness reads the machine's test lock, a
        // scratch one's none outside its root.
        options.sweepsRoles = true
        options.lock = parsed.node ? TestLock.standard() : nil
        // The AI summaries' model (Haiku, headless) on the user's node only: a scratch node's engine asks none.
        options.summarize = parsed.node ? NodeSummaries.headless(root: root) : nil
        let engine = LeadEngine(root: root, nodeRoot: parsed.nodeRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }, link: link,
                                clock: clock, sessions: sessions, options: options, note: say)
        requests.engine = engine
        requests.nodeRoot = parsed.nodeRoot
        // Where `build.switch` finds the builds: the account's own install folder on the node, a test's on a scratch node.
        requests.installRoot = accountHome.map { NodeFolders.defaultPrefix(accountHome: $0) } ?? parsed.testInstallRoot
        engine.watchRoom()
        let server = NodeServer(root: root, requests: requests, housekeeping: parsed.testHousekeeping ?? ServerArguments.housekeeping,
                                clock: clock, cgroupRoot: parsed.testCgroupRoot, runnersAbove: runnersAbove, note: say)
        // The live protocol and the web (the live plan's I1): the hub on the stores, the Unix socket's `subscribe`, and
        // the loopback listener, off until `vibeswitcher web` (or a live token at rest) wants it.
        let live = NodeLive(requests: requests, sessions: sessions, engine: engine, clock: clock, port: parsed.testWebPort ?? NodeWeb.port,
                            webRoot: parsed.testWebRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }, terminals: parsed.webTerminal,
                            // The tailnet's page (`web --tailnet`) on the user's node only: a scratch server never binds it.
                            tailnet: parsed.node ? TailnetWeb.Options() : nil, note: say)
        requests.openWebForAnyone = parsed.testWebPair
        server.hub = live.hub
        link.onWelcome = { _, _ in
            requests.refreshNotes()
            requests.restoreHeldSends()
            engine.welcomed()
        }
        link.start()
        sessions.start()
        queue.sync { live.start() }
        do {
            try server.start()
        } catch {
            say("not started: its socket \(server.socketPath) couldn't be made: \(error)")
            exit(1)
        }
        say("started, pid \(getpid()), root \(root.path), socket \(server.socketPath)")
        Retained.keep([link, sessions, requests, server, clock, engine, live])
        dispatchMain()
    }

    /// The host's end of the connector closed (the host gone): the server exits, saying so. Watched on a thread of its
    /// own (`Platform.Sockets.waitUntilPeerHasGone`: on Linux a poll asking for no event, on the Mac a kqueue's end of
    /// file), so a hang-up or an error is all that ends the wait and nothing on the connector is read here
    /// (`HostConnector.connect` reads its replies). A connector that isn't open is watched no more.
    static func watchConnector(_ connector: Int32) {
        let thread = Thread {
            guard Platform.Sockets.waitUntilPeerHasGone(connector) else { return }
            say("the session host is gone (its connector closed): exiting")
            exit(0)
        }
        thread.name = "connector-watch"
        thread.start()
    }

    /// A scratch host's test's program (`--test-child`), started once, keeping every descriptor that isn't
    /// close-on-exec as any child would, its stdio /dev/null; not waited for.
    static func startTestChild(_ path: String) {
        var spawn = Platform.Spawn(executable: path, arguments: [path])
        spawn.keep = nil
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.stdout = .path("/dev/null", flags: O_WRONLY)
        if case .failure(let error) = spawn.start() { say("the test child \(path) didn't start (errno \(error.code))") }
    }

    /// What `run` keeps alive for the process's life.
    private enum Retained {
        nonisolated(unsafe) static var objects: [AnyObject] = []
        static func keep(_ list: [AnyObject]) { objects = list }
    }
}
