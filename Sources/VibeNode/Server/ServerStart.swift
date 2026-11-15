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
        if parsed.node {
            guard let home = getpwuid(getuid()).map({ String(cString: $0.pointee.pw_dir) }), home.hasPrefix("/") else {
                say("not started: the account has no home in the user database")
                exit(78)
            }
            setenv("HOME", home, 1)
            unsetenv("VIBESWITCHER_HOME")
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
        let sessions = NodeSessions(root: root, home: VibePaths.home, queue: queue, link: link, clock: clock, note: say)
        let rule = VoiceRule.at(start: Platform.Processes.cgroup(getpid()), testScopes: parsed.testUserScopes)
        say("voice rule: \(rule.says)")
        let commit = parsed.nodeRoot.flatMap { folder -> String? in
            if case .success(let info) = BuildInfo.read(buildFolder: folder) { return info.commit } else { return nil }
        } ?? "unknown"
        let requests = Requests(link: link, sessions: sessions, rule: rule, root: root, hostSocket: parsed.hostSocket,
                                commit: commit, note: say)
        var options = LeadEngine.Options()
        options.firstLook = parsed.node || parsed.testFirstLook
        let engine = LeadEngine(root: root, nodeRoot: parsed.nodeRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }, link: link,
                                clock: clock, sessions: sessions, options: options, note: say)
        requests.engine = engine
        let server = NodeServer(root: root, requests: requests, housekeeping: parsed.testHousekeeping ?? ServerArguments.housekeeping,
                                clock: clock, note: say)
        link.onWelcome = { _, _ in
            requests.refreshNotes()
            engine.welcomed()
        }
        link.start()
        sessions.start()
        do {
            try server.start()
        } catch {
            say("not started: its socket \(server.socketPath) couldn't be made: \(error)")
            exit(1)
        }
        say("started, pid \(getpid()), root \(root.path), socket \(server.socketPath)")
        Retained.keep([link, sessions, requests, server, clock, engine])
        dispatchMain()
    }

    /// The host's end of the connector closed (the host gone): the server exits, saying so. Watched on a thread of its
    /// own with `poll` asking for no event, so a hang-up or an error is all that wakes it and nothing on the connector
    /// is read here (`HostConnector.connect` reads its replies).
    static func watchConnector(_ connector: Int32) {
        let thread = Thread {
            while true {
                var watched = pollfd(fd: connector, events: 0, revents: 0)
                let ready = poll(&watched, 1, -1)
                if ready < 0, errno == EINTR { continue }
                if ready > 0, watched.revents & Int16(POLLNVAL) != 0 { return }
                if ready > 0 || ready < 0 {
                    say("the session host is gone (its connector closed): exiting")
                    exit(0)
                }
            }
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
