import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The command line's check of the server it reached (the engine plan's EN-D8, the security architecture document's
/// S3), run as built.
@Suite(NodeTraits.linuxOnly)
struct ServerCheckTests {
    private let scratch = Scratch()

    /// A root of a test's own with its `v2/` folder, and the command line's environment on it.
    private func root(_ prefix: String) throws -> (root: URL, environment: [String: String]) {
        let root = try scratch.shortFolder(prefix)
        try VibePaths.ensurePrivate(root.appendingPathComponent("v2"))
        var environment = scratchEnvironment(root)
        environment["VIBESWITCHER_HOME"] = root.path
        return (root, environment)
    }

    @Test func theCommandLineRefusesADumpableListener() async throws {
        let (root, environment) = try self.root("vsd")
        // A plain socket this test process (dumpable) listens on, at the server's path.
        let listener = try UnixSocket.listen(path: root.appendingPathComponent("v2/server.sock").path)
        defer { Sys.close(listener) }
        let ran = try await run(commandLine, ["status"], environment: environment)
        #expect(ran.status == 77, "\(ran.errors)")
        #expect(ran.errors.contains("is dumpable: not the node's server"), "\(ran.errors)")
    }

    @Test func theCommandLineRefusesAServerThatIsntTheHostsChild() async throws {
        let (root, environment) = try self.root("vsf")
        // A hardened listener: the built server, started by this test, not by the process holding the scratch lock.
        let lock = root.appendingPathComponent(NodeCheck.scratchLock).path
        FileManager.default.createFile(atPath: lock, contents: nil)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/flock")
        // `-o`: the lock stays flock's own, not its command's, so it goes with flock.
        holder.arguments = ["-o", lock, "sleep", "600"]
        holder.standardInput = FileHandle.nullDevice
        try holder.run()
        defer {
            for child in Platform.Processes.children(holder.processIdentifier) { kill(child, SIGKILL) }
            kill(holder.processIdentifier, SIGKILL)
        }
        try #require(await eventually(timeout: 30) { Platform.Processes.lockHolder(path: lock) == holder.processIdentifier })
        guard let (serverEnd, testEnd) = Platform.Sockets.pair(type: Platform.Sockets.seqpacket) else { throw CancellationError() }
        defer { Sys.close(testEnd) }
        let server = Process()
        server.executableURL = builtProducts.appendingPathComponent("vibeswitcher-server")
        server.arguments = ["--host-connector", "0", "--host-socket", root.appendingPathComponent("host.sock").path, "--root", root.path]
        server.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path]
        server.standardInput = FileHandle(fileDescriptor: serverEnd, closeOnDealloc: false)
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        Sys.close(serverEnd)
        defer { kill(server.processIdentifier, SIGKILL) }
        try #require(await eventually(timeout: 60) { FileManager.default.fileExists(atPath: root.appendingPathComponent("v2/server.sock").path) })
        #expect(Platform.Processes.isDumpable(server.processIdentifier) == false)
        let ran = try await run(commandLine, ["status"], environment: environment)
        #expect(ran.status == 77, "\(ran.errors)")
        #expect(ran.errors.contains("isn't a child of the node's host (pid \(holder.processIdentifier))"), "\(ran.errors)")
        // With no one holding the lock, it can't be checked at all: refused too.
        for child in Platform.Processes.children(holder.processIdentifier) { kill(child, SIGKILL) }
        kill(holder.processIdentifier, SIGKILL)
        _ = await exited(holder, within: 30)
        try #require(await eventually(timeout: 30) { Platform.Processes.lockHolder(path: lock) == nil })
        let unheld = try await run(commandLine, ["status"], environment: environment)
        #expect(unheld.status == 77 && unheld.errors.contains("no process holds the scratch node's lock"), "\(unheld.errors)")
    }

    /// S3: a child of the node's host that is non-dumpable but in a session of its own is refused: what a session's
    /// program is (the host starts each with `setsid`), however it made itself non-dumpable (`PR_SET_DUMPABLE`, after
    /// a worker ptraced it or replaced its binary). Here the host is the scratch lock's holder and the listener the
    /// built server, started under it by `setsid`.
    @Test func theCommandLineRefusesAHostsChildInASessionOfItsOwn() async throws {
        let (root, environment) = try self.root("vss")
        let lock = root.appendingPathComponent(NodeCheck.scratchLock).path
        FileManager.default.createFile(atPath: lock, contents: nil)
        guard let (serverEnd, testEnd) = Platform.Sockets.pair(type: Platform.Sockets.seqpacket) else { throw CancellationError() }
        defer { Sys.close(testEnd) }
        // `-o`: the lock stays flock's own; its child, `setsid`'s server, is in a session of its own (flock's child
        // leads no group, so `setsid` execs it in place: a child of the lock's holder). Started with `Platform.Spawn`
        // (no descriptor of this process but the three given) and collected by its pid.
        let flock = "/usr/bin/flock"
        var spawn = Platform.Spawn(executable: flock, arguments: [flock, "-o", lock, "/usr/bin/setsid",
                                                                  builtProducts.appendingPathComponent("vibeswitcher-server").path,
                                                                  "--host-connector", "0", "--host-socket", root.appendingPathComponent("host.sock").path,
                                                                  "--root", root.path])
        spawn.environment = ["PATH=/usr/bin:/bin", "HOME=\(root.path)"]
        spawn.stdin = .descriptor(serverEnd)
        spawn.stdout = .path("/dev/null", flags: O_WRONLY)
        spawn.stderr = .path("/dev/null", flags: O_WRONLY)
        let holder: pid_t
        do { holder = try await startRetrying(spawn) } catch {
            Sys.close(serverEnd)
            throw error
        }
        Sys.close(serverEnd)
        defer {
            for child in Platform.Processes.children(holder) { kill(child, SIGKILL) }
            kill(holder, SIGKILL)
            _ = collected(holder, by: MacTime.real.awake() + 10)
        }
        try #require(await eventually(timeout: 30) { Platform.Processes.lockHolder(path: lock) == holder })
        try #require(await eventually(timeout: 60) { FileManager.default.fileExists(atPath: root.appendingPathComponent("v2/server.sock").path) })
        let server = try #require(Platform.Processes.children(holder).first)
        #expect(Platform.Processes.isDumpable(server) == false)
        #expect(getsid(server) == server && getsid(server) != getsid(holder))
        let ran = try await run(commandLine, ["status"], environment: environment)
        #expect(ran.status == 77, "\(ran.output)\(ran.errors)")
        #expect(ran.errors.contains("isn't in the node's host's session"), "\(ran.errors)")
    }

    @Test func theCommandLineWithNoNodeSaysSoNotConnectionRefused() async throws {
        let (root, environment) = try self.root("vsx")
        for arguments in [["status"], ["stop"], ["start", "--interop-is-on"]] {
            let ran = try await run(commandLine, arguments, environment: environment)
            #expect(ran.status == 69, "\(arguments): \(ran.errors)")
            #expect(ran.errors.contains("the node isn't running"), "\(arguments): \(ran.errors)")
            #expect(!ran.errors.contains("Connection refused") && !ran.errors.contains("connect:"), "\(ran.errors)")
        }
        let status = try await run(commandLine, ["status"], environment: environment)
        #expect(status.errors.contains("status --probe"), "\(status.errors)")
        // A socket file no one listens on (a server's that died): the same. Bound and never listening, so every
        // connect is refused whoever holds a copy (`held`, as another test's spawn in flight would). Not a listener
        // closed here: it lives on while any descriptor table holds it, and the connection would be taken.
        let path = root.appendingPathComponent("v2/server.sock").path
        let bound = Platform.Sockets.makeSocket(type: Platform.Sockets.stream)
        try #require(bound >= 0)
        defer { Sys.close(bound) }
        let address = try #require(Platform.Sockets.unixAddress(path))
        try #require(Platform.Sockets.bindOwnerOnly(bound, to: address, path: path, mode: 0o600) == nil)
        let held = dup(bound)
        try #require(held >= 0)
        defer { Sys.close(held) }
        let stale = try await run(commandLine, ["status"], environment: environment)
        #expect(stale.status == 69 && stale.errors.contains("the node isn't running"), "\(stale.errors)")
    }

    @Test func aScratchNodeIsNamedOnStderr() async throws {
        let node = try await ScratchNode(scratch)
        for arguments in [["status"], ["status", "--json"]] {
            let ran = try await node.run(arguments)
            #expect(ran.status == 0, "\(ran.errors)")
            #expect(ran.errors.contains("scratch node at \(node.root.standardizedFileURL.path)"), "\(arguments): \(ran.errors)")
            #expect(!ran.output.contains("scratch node at"))
        }
    }

    /// The step 8 sweep: the user's node's root (its socket, its record) is the account's, from the user database,
    /// whatever `HOME` or `CFFIXED_USER_HOME` move `VibePaths.root` to: its host listens there. Only a scratch node's
    /// is the environment's. On the Mac the account's node root is `~/.vibeswitcher/v2/node`, beside the app's folder
    /// (the node on the Mac's step 2).
    @Test func theUsersNodeRootIsTheAccountsWhateverHomeSays() {
        let account = "/home/someone"
        let moved = "/scratch/elsewhere/.vibeswitcher"
        let own = Platform.CodeIdentity.isAvailable ? "/home/someone/.vibeswitcher/v2/node" : "/home/someone/.vibeswitcher"
        #expect(NodeFolders.nodeRoot(accountHome: account) == own)
        #expect(NodeCheck.root(of: .node, environmentRoot: moved, accountHome: account) == own)
        #expect(NodeCheck.root(of: .detached(record: nil), environmentRoot: moved, accountHome: account) == own)
        #expect(NodeCheck.root(of: .detached(record: NodeRecord(pid: 4, startTicks: 5)), environmentRoot: moved, accountHome: account)
            == NodeFolders.nodeRoot(accountHome: account))
        #expect(NodeCheck.root(of: .scratch(root: "/srv/vsn-1"), environmentRoot: "/srv/vsn-1", accountHome: account) == "/srv/vsn-1")
        // The mode itself never looks at HOME: VIBESWITCHER_HOME unset is the user's node.
        let mode = NodeCheck.mode(vibeswitcherHome: nil, accountHome: account)
        #expect(NodeCheck.root(of: mode, environmentRoot: moved, accountHome: account) == own)
    }

    @Test func aScratchHomeThatIsTheAccountsOwnGetsTheNodesCheck() {
        let account = "/home/someone"
        #expect(NodeCheck.mode(vibeswitcherHome: "/home/someone/.vibeswitcher", accountHome: account) == .node)
        #expect(NodeCheck.mode(vibeswitcherHome: "/home/someone/./.vibeswitcher/", accountHome: account) == .node)
        #expect(NodeCheck.mode(vibeswitcherHome: "/home/someone/x/../.vibeswitcher", accountHome: account) == .node)
        #expect(NodeCheck.mode(vibeswitcherHome: nil, accountHome: account) == .node)
        #expect(NodeCheck.mode(vibeswitcherHome: "relative/root", accountHome: account) == .node)
        #expect(NodeCheck.mode(vibeswitcherHome: "/srv/vsn-1", accountHome: account) == .scratch(root: "/srv/vsn-1"))
        #expect(NodeCheck.mode(vibeswitcherHome: "/home/someone/.build/scratchhome", accountHome: account) == .scratch(root: "/home/someone/.build/scratchhome"))
        // The node's check: non-dumpable, in the node's unit, a child of the unit's main process.
        let unit = ["0::/user.slice/user-1000.slice/user@1000.service/app.slice/vibeswitcher-node.service"]
        let good = NodeCheck.Listener(pid: 50, dumpable: false, parent: 40, cgroup: unit, session: 40)
        #expect(NodeCheck.refusal(good, mode: .node, expectedParent: 40, parentSession: 40) == nil)
        #expect(NodeCheck.refusal(good, mode: .node, expectedParent: 41, parentSession: 41) != nil)
        #expect(NodeCheck.refusal(good, mode: .node, expectedParent: nil, parentSession: nil) != nil)
        var outside = good
        outside.cgroup = ["0::/init.scope"]
        #expect(NodeCheck.refusal(outside, mode: .node, expectedParent: 40, parentSession: 40)?.contains("isn't in vibeswitcher-node.service") == true)
        // A scratch node doesn't ask the cgroup; both ask dumpable and the parent.
        #expect(NodeCheck.refusal(outside, mode: .scratch(root: "/srv/x"), expectedParent: 40, parentSession: 40) == nil)
        var dumpable = good
        dumpable.dumpable = true
        #expect(NodeCheck.refusal(dumpable, mode: .scratch(root: "/srv/x"), expectedParent: 40, parentSession: 40) != nil)
        dumpable.dumpable = nil
        #expect(NodeCheck.refusal(dumpable, mode: .node, expectedParent: 40, parentSession: 40) != nil)
        // A child of the host in a session of its own (a session's program, non-dumpable by its own prctl), or whose
        // session or the host's can't be read: refused, on both.
        var session = good
        session.session = 50
        for mode in [NodeCheck.Mode.node, .scratch(root: "/srv/x")] {
            #expect(NodeCheck.refusal(session, mode: mode, expectedParent: 40, parentSession: 40)?.contains("isn't in the node's host's session") == true)
            #expect(NodeCheck.refusal(good, mode: mode, expectedParent: 40, parentSession: nil) != nil)
        }
        session.session = nil
        #expect(NodeCheck.refusal(session, mode: .node, expectedParent: 40, parentSession: 40) != nil)
    }

    @Test func aListenersCgroupIsPrintedInert() {
        // Any process of the user's can make a cgroup under its manager named as it likes and move into it: the name
        // the refusal prints is the listener's, so it acts on no terminal.
        let named = "/user.slice/user-1000.slice/user@1000.service/app.slice/\u{1B}]0;owned\u{07}\u{1B}[2J\u{202E}x.scope"
        let listener = NodeCheck.Listener(pid: 50, dumpable: false, parent: 40, cgroup: ["0::" + named], session: 40)
        let refusal = NodeCheck.refusal(listener, mode: .node, expectedParent: 40, parentSession: 40)
        #expect(refusal?.contains("isn't in vibeswitcher-node.service") == true, "\(String(describing: refusal))")
        #expect(refusal?.unicodeScalars.contains { $0 == "\u{1B}" || $0 == "\u{07}" || $0 == "\u{202E}" } == false,
                "\(String(describing: refusal?.debugDescription))")
        #expect(refusal?.contains(ConfigSeal.inert(named, limit: .max)) == true)
    }

    /// S3: a node started detached is checked by its record (ST-D6): the listener a non-dumpable child of the host the
    /// record names, in its session, honoured only while what the record names is that host; no cgroup line is read.
    @Test func theCommandLineChecksADetachedNodeByItsRecord() async throws {
        // The rules, on stand-ins for the reads.
        let record = NodeRecord(pid: 40, startTicks: 777)
        let host = NodeUnit.execStart(prefix: "/home/u/.vibeswitcher/v2/builds", commit: "0123456789abcdef0123456789abcdef01234567")
        let isHost: ([String]) -> Bool = { NodeCheck.isInstalledHost($0, prefix: "/home/u/.vibeswitcher/v2/builds") }
        func recorded(_ record: NodeRecord?, ticks: UInt64? = 777, words: [String] = host, dumpable: Bool? = false, holder: pid_t? = 40) -> NodeCheck.Recorded {
            NodeCheck.recordedHost(record, isHost: isHost, lock: "/home/u/.vibeswitcher/host.lock", startTicks: { _ in ticks }, arguments: { _ in words },
                                   dumpable: { _ in dumpable }, holder: { $0 == "/home/u/.vibeswitcher/host.lock" ? holder : nil })
        }
        #expect(recorded(record) == .host(40))
        guard case .other(let restarted) = recorded(record, ticks: 778) else { Issue.record("a pid whose start changed was taken"); return }
        #expect(restarted.contains("now names another process"), "\(restarted)")
        guard case .other(let sleeping) = recorded(record, words: ["/bin/sleep", "600"]) else { Issue.record("another command line was taken"); return }
        #expect(sleeping.contains("/bin/sleep 600"), "\(sleeping)")
        guard case .other(let dumpable) = recorded(record, dumpable: true) else { Issue.record("a dumpable host was taken"); return }
        #expect(dumpable.contains("dumpable"), "\(dumpable)")
        if case .host = recorded(record, dumpable: nil) { Issue.record("a host whose dumpability can't be told was taken") }
        // The step 8 sweep: the right tick, the installed host's command line and non-dumpable are each the process's
        // own to set (`exec -a`, `PR_SET_DUMPABLE`); a process that doesn't hold the host's lock isn't the host.
        guard case .other(let unlocked) = recorded(record, holder: 41) else { Issue.record("a process not holding the host's lock was taken"); return }
        #expect(unlocked.contains("doesn't hold the host's lock") && unlocked.contains("/home/u/.vibeswitcher/host.lock"), "\(unlocked)")
        if case .host = recorded(record, holder: nil) { Issue.record("a host with no lock held was taken") }
        if case .host = recorded(record, ticks: nil) { Issue.record("an ended host was taken") }
        if case .host = recorded(nil) { Issue.record("no record was taken") }

        let mode = NodeCheck.Mode.detached(record: record)
        // The real child: accepted, with no cgroup line read (nil here).
        let child = NodeCheck.Listener(pid: 50, dumpable: false, parent: 40, cgroup: nil, session: 40)
        #expect(NodeCheck.refusal(child, mode: mode, expectedParent: 40, parentSession: 40) == nil)
        var outside = child
        outside.cgroup = ["0::/init.scope"]
        #expect(NodeCheck.refusal(outside, mode: mode, expectedParent: 40, parentSession: 40) == nil)
        // Not the recorded host's child; in a session of its own; dumpable; no host to check against.
        var stranger = child
        stranger.parent = 41
        #expect(NodeCheck.refusal(stranger, mode: mode, expectedParent: 40, parentSession: 40)?.contains("isn't a child of the node's host (pid 40)") == true)
        var session = child
        session.session = 50
        #expect(NodeCheck.refusal(session, mode: mode, expectedParent: 40, parentSession: 40)?.contains("isn't in the node's host's session") == true)
        var open = child
        open.dumpable = true
        #expect(NodeCheck.refusal(open, mode: mode, expectedParent: 40, parentSession: 40)?.contains("is dumpable") == true)
        #expect(NodeCheck.refusal(child, mode: mode, expectedParent: nil, parentSession: nil)?.contains("record names no host") == true)

        // On the system's reads: a scratch host started detached, its record, and its server.
        let detached = try DetachedScratch(scratch)
        let written = try detached.start().get()
        defer { DetachedScratch.end(written.pid) }
        try #require(await eventually(timeout: 120) {
            DetachedScratch.server(of: written.pid).map { Platform.Processes.isDumpable($0) == false } == true
        }, "the detached host's server never came: \((try? String(contentsOf: detached.log, encoding: .utf8)) ?? "")")
        let server = try #require(DetachedScratch.server(of: written.pid))
        let read = try #require(NodeRecord.read(root: detached.root.path))
        #expect(NodeCheck.recordedHost(read, isHost: { $0 == detached.command }, lock: detached.lock) == .host(written.pid))
        let listener = NodeCheck.listener(pid: server)
        #expect(listener.parent == written.pid && listener.session == written.pid && listener.dumpable == false, "\(listener)")
        #expect(NodeCheck.refusal(listener, mode: .detached(record: read), expectedParent: written.pid, parentSession: getsid(written.pid)) == nil)
        // The same host, but not of the installed host's form: not the node's.
        guard case .other = NodeCheck.recordedHost(read, isHost: isHost, lock: detached.lock) else { Issue.record("a scratch host was taken for the installed one"); return }
        // A recorded pid whose start changed: not the host.
        guard case .other = NodeCheck.recordedHost(NodeRecord(pid: written.pid, startTicks: written.startTicks + 1), isHost: { $0 == detached.command },
                                                   lock: detached.lock) else {
            Issue.record("a record whose start changed was honoured"); return
        }
    }
}

/// The Mac's form of the command line's server check (`NodeCheck.refusal`'s `codeIdentity`, the review of 2026-11-21):
/// the listener's code (the installed build's server, by its audit token, with the Hardened Runtime) in place of its
/// dumpable state the Mac can't tell, no cgroup, and still the host's child in the host's session. Both systems: pure.
struct MacServerCheckTests {
    @Test func theMacsCheckAsksTheListenersCodeNotItsDumpableState() {
        let good = NodeCheck.Listener(pid: 50, dumpable: nil, parent: 40, cgroup: nil, session: 40, code: true)
        #expect(NodeCheck.refusal(good, mode: .node, expectedParent: 40, parentSession: 40, codeIdentity: true) == nil)
        // The same facts under Linux's form: its dumpable state can't be told, so refused.
        #expect(NodeCheck.refusal(good, mode: .node, expectedParent: 40, parentSession: 40) != nil)
        var other = good
        other.code = false
        #expect(NodeCheck.refusal(other, mode: .node, expectedParent: 40, parentSession: 40, codeIdentity: true)?.contains("doesn't run the installed build's server code") == true)
        other.code = nil
        #expect(NodeCheck.refusal(other, mode: .node, expectedParent: 40, parentSession: 40, codeIdentity: true)?.contains("can't be told") == true)
        // Not the job's child, or in another session, or no job to check against: refused, whatever its code.
        #expect(NodeCheck.refusal(good, mode: .node, expectedParent: 41, parentSession: 41, codeIdentity: true) != nil)
        var detached = good
        detached.session = 50
        #expect(NodeCheck.refusal(detached, mode: .node, expectedParent: 40, parentSession: 40, codeIdentity: true) != nil)
        #expect(NodeCheck.refusal(good, mode: .node, expectedParent: nil, parentSession: nil, codeIdentity: true) != nil)
    }

    /// The server checked is the one beside the job's host, only for an installed build's host.
    @Test func theServerCheckedIsTheInstalledBuildsBesideItsHost() {
        let prefix = "/Users/u/.vibeswitcher/v2/builds"
        #expect(NodeCheck.installedServer(host: "\(prefix)/abc123/bin/vibeswitcher-host", prefix: prefix) == "\(prefix)/abc123/bin/vibeswitcher-server")
        for host in ["/Users/u/elsewhere/abc/bin/vibeswitcher-host", "\(prefix)/abc/bin/other", "\(prefix)/abc/x/bin/vibeswitcher-host",
                     "\(prefix)/bin/vibeswitcher-host", "\(prefix)/../abc/bin/vibeswitcher-host", "\(prefix)/current/bin/vibeswitcher-host",
                     "\(prefix)//bin/vibeswitcher-host", "\(prefix)x/abc/bin/vibeswitcher-host"] {
            #expect(NodeCheck.installedServer(host: host, prefix: prefix) == nil, "\(host)")
        }
    }

    /// Every fact of the Mac's listener bound to the socket's one token (the review of 2026-11-21's MEDIUM): its pid
    /// the socket's peer, the link read before and after the session and the code, the same process both times and
    /// still the token's; else parent, session and code unread, and the check refuses.
    @Test func theMacsListenerIsBoundToTheSocketsToken() throws {
        let (one, other) = try #require(Platform.Sockets.pair(type: Platform.Sockets.stream))
        defer { close(one); close(other) }
        let token = try #require(Platform.Sockets.peerToken(one))
        let pid = token.pid
        let link = Platform.Processes.Link(pid: pid, parent: 40, startTicks: 7, terminal: nil)
        let good = NodeCheck.macListener(pid: pid, token: token, link: { _ in link }, session: { _ in 40 }, code: { _ in true }, bound: { _, _ in true })
        #expect(good.parent == 40 && good.session == 40 && good.code == true)
        #expect(NodeCheck.refusal(good, mode: .node, expectedParent: 40, parentSession: 40, codeIdentity: true) == nil)
        var unread: [NodeCheck.Listener] = []
        unread.append(NodeCheck.macListener(pid: pid, token: nil, link: { _ in link }, session: { _ in 40 }, code: { _ in true }, bound: { _, _ in true }))
        unread.append(NodeCheck.macListener(pid: pid + 1, token: token, link: { _ in link }, session: { _ in 40 }, code: { _ in true }, bound: { _, _ in true }))
        unread.append(NodeCheck.macListener(pid: pid, token: token, link: { _ in link }, session: { _ in 40 }, code: { _ in true }, bound: { _, _ in false }))
        var reads = 0
        unread.append(NodeCheck.macListener(pid: pid, token: token, link: { _ in
            reads += 1
            return reads == 1 ? link : Platform.Processes.Link(pid: pid, parent: 40, startTicks: 8, terminal: nil)
        }, session: { _ in 40 }, code: { _ in true }, bound: { _, _ in true }))
        unread.append(NodeCheck.macListener(pid: pid, token: token, link: { _ in nil }, session: { _ in 40 }, code: { _ in true }, bound: { _, _ in true }))
        for (index, listener) in unread.enumerated() {
            #expect(listener.parent == nil && listener.session == nil && listener.code == nil, "case \(index)")
            #expect(NodeCheck.refusal(listener, mode: .node, expectedParent: 40, parentSession: 40, codeIdentity: true) != nil, "case \(index)")
        }
    }
}
/// The listener's dumpable state read patiently (`NodeCheck.dumpable`, the CI flake of 2026-11-22: one unreadable look on
/// a loaded runner refused `settings --find`): read again while it can't be told and the process lives, until told or
/// out of patience; a process that has gone isn't waited for. Both systems: the reads and the clock are the test's.
struct DumpablePatienceTests {
    @Test func anUnreadableLookIsReadAgainUntilToldOrOutOfPatience() {
        var reads = 0
        var clock = Date(timeIntervalSince1970: 0)
        let told = NodeCheck.dumpable(getpid(), patience: 3, read: { _ in reads += 1; return reads < 3 ? nil : false },
                                      now: { clock }, wait: { clock.addTimeInterval(0.05) })
        #expect(told == false && reads == 3)
        reads = 0
        let never = NodeCheck.dumpable(getpid(), patience: 1, read: { _ in reads += 1; return nil }, now: { clock }, wait: { clock.addTimeInterval(0.25) })
        #expect(never == nil && reads == 5)
        // A pid no process has: one look, no wait.
        reads = 0
        let gone = NodeCheck.dumpable(999_999_999, patience: 3, read: { _ in reads += 1; return nil }, now: { clock }, wait: { Issue.record("waited for a process that's gone") })
        #expect(gone == nil && reads == 1)
    }
}
