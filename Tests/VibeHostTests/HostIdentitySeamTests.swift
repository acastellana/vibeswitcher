import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// Who the host takes a peer for, now that its reads go through the platform (the stage 2 plan's Task 4b1): on the
/// Mac the app is still the app's code (`Platform.CodeIdentity`'s cdhash check, moved) that proves its key; on Linux,
/// where an orphan is given to the subreaper above the host and not to pid 1, the orphan sweep looks at that parent's
/// children too (`HostProcesses.orphanParents`), and never at a tool server whose agent still runs.
///
/// And (Task 4b2) the app on Linux: the connections the host makes through an app connector, for the process it
/// expects (a helper here, `AppConnectorHelper`; the server child from Task 8a), never one made through the
/// socket's path; and who may spawn where only leads may (`Config.spawnNeedsLead`).
@Suite(hostTestLimit) struct HostIdentitySeamTests {
    let temp = Scratch()

    /// A stand-in for the tool server in `folder`: `sleep`'s program under the tool server's name, so it waits as a
    /// tool server does and ends on SIGTERM.
    static func toolServerStandIn(in folder: String) throws -> String {
        let path = folder + "/vibeswitcher-mcp"
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: path)
        return path
    }

    /// Starts `executable 600` with its starter (a shell) ended at once, as a tool server is once its agent ends: its
    /// pid. Its parent is then whatever the kernel gives an orphan of this process.
    static func orphan(_ executable: String) async throws -> pid_t {
        let starter = Process()
        starter.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Its output elsewhere: the pipe ends with the shell.
        starter.arguments = ["-c", "\"$0\" 600 < /dev/null > /dev/null 2>&1 & echo $!", executable]
        let pipe = Pipe()
        starter.standardOutput = pipe
        try starter.run()
        let output = await offPool { pipe.fileHandleForReading.readDataToEndOfFile() }
        _ = await offPool { waitForEnd(starter) }
        return try #require(pid_t(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    static func parent(of pid: pid_t) -> pid_t? {
        guard case .brief(let brief) = Platform.Processes.brief(pid) else { return nil }
        return brief.ppid
    }

    /// A folder of its own, short (a scratch host's socket is under it).
    static func folder() throws -> String {
        let dir = "\(shortScratchRoot)/vsid-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A `Config` with only `appExecutable` set, as before the platform: the app's code answering the challenge with
    /// the key is the app; another process answering it with the same key is refused.
    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's cdhash check; Linux has no code identity"))
    func theMacsAppIsStillTheCdhashCheck() async throws {
        let calls = LeadVaultHostTests()
        // nc's code is the app's here; this test's runner is another program.
        let host = try TestHost(appExecutable: "/usr/bin/nc")
        let proven = try await calls.viaNC(host.socket, proof: host.appKey, [.screen(id: UUID())])
        #expect(proven[0] == .ok, "\(proven)")

        let other = try TestClient(socket: host.socket)
        var challenge: Data?
        #expect(await eventually {
            other.with { client in
                for case .challenge(let sent, _) in client.allEvents { challenge = sent }
            }
            return challenge != nil
        })
        let seq = other.send(.proveApp(answer: AppProof.answer(try #require(challenge), key: host.appKey)))
        #expect(await eventually { other.reply(to: seq) != nil })
        guard case .error(let reason)? = other.reply(to: seq) else {
            Issue.record("another program proved it's the app: \(String(describing: other.reply(to: seq)))")
            return
        }
        #expect(reason.contains("isn't VibeSwitcher's"), "\(reason)")
    }

    /// The subreaper is kept as its token, not its pid: asked again, it's the one found while that process runs (no
    /// new probe); once it has ended, or its pid is another process's (another token), it's found again, so a later
    /// process given that pid isn't taken for it (its children aren't orphans). pid 1 is never checked, and a probe
    /// that found none isn't run again. Tokens here are numbers.
    @Test func aSubreaperThatEndedIsFoundAgain() {
        var tokens: [pid_t: Int] = [4242: 1, 5151: 7]
        var answers: [pid_t?] = [4242, 5151, 1, nil]
        var probes = 0
        var asked: [pid_t] = []
        let parent = HostProcesses.OrphanParent<Int>(probe: {
            probes += 1
            return answers.removeFirst()
        }, token: { pid in
            asked.append(pid)
            return tokens[pid]
        }, same: { $0 == $1 })

        #expect(parent.current() == 4242 && probes == 1)
        #expect(parent.current() == 4242 && probes == 1)
        // It ended and its pid went to another process: found again.
        tokens[4242] = 2
        #expect(parent.current() == 5151 && probes == 2)
        // It ended: found again, now pid 1, whose token isn't read.
        tokens[5151] = nil
        asked = []
        #expect(parent.current() == 1 && probes == 3)
        #expect(parent.current() == 1 && probes == 3)
        #expect(asked == [5151])
        // A probe that finds none stays so.
        let none = HostProcesses.OrphanParent<Int>(probe: { probes += 1; return answers.removeFirst() }, token: { tokens[$0] }, same: { $0 == $1 })
        #expect(none.current() == nil && probes == 4)
        #expect(none.current() == nil && probes == 4)
    }

    /// The same with real tokens (`Platform.Processes.token`): a process found as the subreaper is kept while it runs
    /// and dropped for a new probe once it has ended.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's subreaper; the Mac's orphans are launchd's"))
    func aSubreaperIsKeptAsItsTokenOnLinux() async throws {
        let stand = Process()
        stand.executableURL = URL(fileURLWithPath: "/bin/sleep")
        stand.arguments = ["600"]
        try stand.run()
        defer { if stand.isRunning { kill(stand.processIdentifier, SIGKILL) } }
        var probes = 0
        let found = stand.processIdentifier
        let parent = HostProcesses.OrphanParent<Platform.PeerToken>.live { probes += 1; return probes == 1 ? found : nil }

        #expect(parent.current() == found && probes == 1)
        #expect(parent.current() == found && probes == 1)
        kill(found, SIGKILL)
        _ = await offPool { waitForEnd(stand) }
        #expect(parent.current() == nil && probes == 2)
    }

    /// A tool server whose agent ended is the child of the parent an orphan of this process gets (the user's
    /// systemd here, pid 1 elsewhere): the sweep lists it, and that parent is among `orphanParents`. Asserted so, not
    /// by naming the parent: the subreaper depends on where the tests run.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's subreaper; the Mac's orphans are launchd's"))
    func anOrphanedToolServerIsFoundOnLinux() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let toolServer = try Self.toolServerStandIn(in: dir)
        let orphaned = try await Self.orphan(toolServer)
        defer { kill(orphaned, SIGKILL) }

        #expect(await eventually { HostProcesses.orphans(running: toolServer).contains(orphaned) },
                "parent \(String(describing: Self.parent(of: orphaned))), orphans' parents \(HostProcesses.orphanParents)")
        let parent = try #require(Self.parent(of: orphaned))
        #expect(HostProcesses.orphanParents.contains(parent), "parent \(parent), orphans' parents \(HostProcesses.orphanParents)")
        #expect(HostProcesses.orphans(running: toolServer) == [orphaned])
    }

    /// A tool server whose agent (this test) runs is its agent's child, and this test is among the scratch host's
    /// ancestors: a host that ends orphaned tool servers leaves it, while it ends one beside it whose agent ended.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's subreaper; the Mac's orphans are launchd's"))
    func aLiveToolServerWhoseParentIsTheTestIsNotAnOrphan() async throws {
        let host = try await ScratchHostProcess(arguments: ["--housekeeping", "0.5", "--end-orphaned-tool-servers"])
        defer { host.stop() }
        #expect(ProcessTable.ancestry(of: host.pid)?.contains { $0.pid == getpid() } == true)
        // The tool server beside the scratch host's binary is the one it sweeps for.
        let toolServer = try Self.toolServerStandIn(in: host.dir + "/old")
        let served = Process()
        served.executableURL = URL(fileURLWithPath: toolServer)
        served.arguments = ["600"]
        served.standardInput = FileHandle.nullDevice
        served.standardOutput = FileHandle.nullDevice
        served.standardError = FileHandle.nullDevice
        try served.run()
        defer { if served.isRunning { kill(served.processIdentifier, SIGKILL) } }
        // One whose agent ended: once the host has ended it, it has swept with the test's child there.
        let orphaned = try await Self.orphan(toolServer)
        defer { kill(orphaned, SIGKILL) }

        let notes = { (try? String(contentsOfFile: host.sessionLog, encoding: .utf8)) ?? "" }
        #expect(await eventually(timeout: 60) { notes().contains("ended tool server pid \(orphaned), whose agent ended") }, "\(notes())")
        #expect(served.isRunning && Self.parent(of: served.processIdentifier) == getpid())
        #expect(!notes().contains("pid \(served.processIdentifier)"), "\(notes())")
        #expect(!HostProcesses.orphans(running: toolServer).contains(served.processIdentifier))
    }

    // MARK: The app's connector (Task 4b2)

    /// A host for the connector's tests: a vault, a log, and the test runner as its `appExecutable` (as `TestHost`
    /// sets it), with no connector but the test's own (Task 5a's stand-in, when it comes, is left out of these).
    func connectorHost() throws -> (host: TestHost, log: String, dir: String) {
        let dir = try Self.folder()
        let log = dir + "/host.log"
        return (try TestHost(vault: LeadVault.Book(), log: log), log, dir)
    }

    static func said(_ log: String) -> String { (try? String(contentsOfFile: log, encoding: .utf8)) ?? "" }

    /// A helper the host expects asks for a connection, says hello and asks what only the app may: its first event is
    /// the welcome, not a challenge, and both requests are answered.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's connector; the Mac's app proves itself by its code"))
    func aConnectorConnectionIsTheAppWithNoChallenge() throws {
        let (host, _, dir) = try connectorHost()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let connector = try #require(host.server.openAppConnector(expecting: nil, requireNonDumpable: false, onDumpable: nil))
        defer {
            host.server.closeAppConnector(connector)
            Sys.close(connector)
        }
        let helper = try AppConnectorHelper.Running.start(connector: connector)
        defer { helper.end() }
        let token = try #require(Platform.Processes.token(helper.pid))
        host.server.setAppConnectorSender(token, for: connector)

        #expect(try helper.ask("ask") == "connected")
        try helper.send(1, .hello(protocolVersion: HostProtocol.version, app: "test"))
        let first = try helper.event()
        guard case .welcome = first.event, first.replyTo == 1 else {
            Issue.record("its first event: \(first)")
            return
        }
        try helper.send(2, .census)
        let census = try helper.reply(to: 2)
        guard case .census = census else {
            Issue.record("the census: \(census)")
            return
        }
        try helper.send(3, .vault(.issue(role: .lead, root: dir + "/repo", task: nil, auditing: nil)))
        let issued = try helper.reply(to: 3)
        guard case .vault(.grant) = issued else {
            Issue.record("a lead's grant: \(issued)")
            return
        }
    }

    /// On a host with a connector open, a client by the socket's path that answers the challenge with the host's app
    /// key, from the test runner (the host's `appExecutable`), is refused every request only the app may make: Linux
    /// has no code identity, so nothing by path is the app.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's rule; the Mac's app proves itself by its code"))
    func noConnectionByPathIsTheAppOnLinux() async throws {
        let (host, _, dir) = try connectorHost()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let connector = try #require(host.server.openAppConnector(expecting: Platform.Processes.token(getpid()), requireNonDumpable: false,
                                                                  onDumpable: nil))
        defer {
            host.server.closeAppConnector(connector)
            Sys.close(connector)
        }
        let byPath = try TestClient(socket: host.socket, appKey: host.appKey, viaConnector: false)
        let requests: [HostRequest] = [
            .census,
            .spawn(SpawnRequest(cwd: dir, command: keepRunning, env: [:], cols: 80, rows: 24, keepShell: false, label: "Test", agent: nil)),
            .vault(.issue(role: .lead, root: dir + "/repo", task: nil, auditing: nil)),
            .handover(executable: HostServer.executable(of: getpid()) ?? "/bin/sh"),
            .shutdown,
        ]
        let seqs = requests.map { byPath.send($0) }
        #expect(await eventually { seqs.allSatisfy { byPath.reply(to: $0) != nil } })
        for (request, seq) in zip(requests, seqs) {
            switch byPath.reply(to: seq) {
            case .error(let reason)?: #expect(reason == HostProtocol.unauthorized, "\(request): \(reason)")
            case .vault(.refused)?: break
            case let other: Issue.record("\(request) by path: \(String(describing: other))")
            }
        }
    }

    /// A child of the helper the host expects writes the byte: no connection comes back, and the host's log says
    /// why; the helper's own request is still answered after it.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's connector; the Mac has none"))
    func aConnectorRequestFromAnotherSenderMakesNoConnection() async throws {
        let (host, log, dir) = try connectorHost()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let connector = try #require(host.server.openAppConnector(expecting: nil, requireNonDumpable: false, onDumpable: nil))
        defer {
            host.server.closeAppConnector(connector)
            Sys.close(connector)
        }
        let helper = try AppConnectorHelper.Running.start(connector: connector)
        defer { helper.end() }
        let token = try #require(Platform.Processes.token(helper.pid))
        host.server.setAppConnectorSender(token, for: connector)

        #expect(try helper.ask("child-ask") == "sent 0")
        // The child named, or (ended and reaped before the host read its byte) no one: refused either way.
        let refusal = "refused an app connection through connector \(connector): a request from "
        #expect(await eventually { Self.said(log).contains(refusal) }, "\(Self.said(log))")
        #expect(Self.said(log).contains("not pid \(helper.pid)"), "\(Self.said(log))")
        #expect(try helper.ask("pending") == "none")
        #expect(!Self.said(log).contains("app connection made"), "\(Self.said(log))")
        // Its own request, after: answered.
        #expect(try helper.ask("ask") == "connected")
        #expect(await eventually { Self.said(log).contains("app connection made through connector \(connector) for pid \(helper.pid)") })
    }

    /// An empty message from the helper the host expects is refused and the connector goes on; once the helper shuts
    /// its end for writing (it still holds it: no hang-up, and every read is empty), the host closes the connector,
    /// said once in its log, rather than refuse an empty request without end.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's connector; the Mac has none"))
    func aConnectorShutForWritingIsClosed() async throws {
        let (host, log, dir) = try connectorHost()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let connector = try #require(host.server.openAppConnector(expecting: nil, requireNonDumpable: false, onDumpable: nil))
        defer {
            host.server.closeAppConnector(connector)
            Sys.close(connector)
        }
        let helper = try AppConnectorHelper.Running.start(connector: connector)
        defer { helper.end() }
        let token = try #require(Platform.Processes.token(helper.pid))
        host.server.setAppConnectorSender(token, for: connector)

        let empty = "refused an app connection through connector \(connector): an empty request"
        #expect(try helper.ask("empty") == "sent")
        #expect(await eventually { Self.said(log).contains(empty) }, "\(Self.said(log))")
        #expect(try helper.ask("ask") == "connected")

        #expect(try helper.ask("shut") == "shut")
        let closed = "app connector \(connector) closed: its other end has closed"
        #expect(await eventually { Self.said(log).contains(closed) }, "\(Self.said(log))")
        // The closing is the read after the shut: the empty request of before was refused once only, and nothing reads
        // the connector after it closed.
        #expect(Self.said(log).components(separatedBy: empty).count == 2, "\(Self.said(log))")
        #expect(Self.said(log).components(separatedBy: closed).count == 2, "\(Self.said(log))")
    }

    /// Where the host asks for a non-dumpable sender, a dumpable one (this test binary, as the helper) is refused, said
    /// in the log, and handed to `onDumpable` (the server child's end, Task 8a): no connection is made.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's connector; the Mac has none"))
    func aDumpableSenderGetsNoConnection() async throws {
        let (host, log, dir) = try connectorHost()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = NSLock()
        var dumpable: [pid_t] = []
        func ended() -> [pid_t] {
            lock.lock()
            defer { lock.unlock() }
            return dumpable
        }
        let connector = try #require(host.server.openAppConnector(expecting: nil, requireNonDumpable: true) { pid in
            lock.lock()
            dumpable.append(pid)
            lock.unlock()
        })
        defer {
            host.server.closeAppConnector(connector)
            Sys.close(connector)
        }
        let helper = try AppConnectorHelper.Running.start(connector: connector)
        defer { helper.end(killing: true) }
        let token = try #require(Platform.Processes.token(helper.pid))
        host.server.setAppConnectorSender(token, for: connector)

        // No answer comes to it: the helper waits in its request until it is ended.
        try helper.tell("ask")
        #expect(await eventually { ended() == [helper.pid] }, "\(ended())")
        #expect(Self.said(log).contains("pid \(helper.pid) is dumpable"), "\(Self.said(log))")
        #expect(!Self.said(log).contains("app connection made"), "\(Self.said(log))")
    }

    /// Through a connector (this process's own, registered for the host's socket), with the app's key given and no
    /// hello sent, a request only the app may make is answered: nothing is held for a proof the host never asks.
    /// (The plan names a `sessions` request; there is none: `census` is the app-only request that answers at once.)
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's connector; the Mac has none"))
    func aConnectorConnectionHoldsNoRequestForAProof() async throws {
        let host = try TestHost()
        let connector = try #require(host.server.openAppConnector(expecting: Platform.Processes.token(getpid()), requireNonDumpable: false,
                                                                  onDumpable: nil))
        HostConnection.register(connector: connector, for: host.socket)
        defer {
            HostConnection.unregister(path: host.socket)
            host.server.closeAppConnector(connector)
            Sys.close(connector)
        }
        let app = try TestClient(socket: host.socket, appKey: host.appKey)
        let seq = app.send(.census)
        #expect(await eventually { app.reply(to: seq) != nil })
        guard case .census? = app.reply(to: seq) else {
            Issue.record("the census: \(String(describing: app.reply(to: seq)))")
            return
        }
        #expect(!app.hasEvent { if case .challenge = $0 { return true } else { return false } })
    }

    // MARK: Who may spawn (Task 4b2)

    let spawnRoot = "/Users/you/dev/spawn-rule-repo"

    /// A scratch folder for sessions to start in.
    func spawnFolder() throws -> String {
        let dir = temp.url("spawn").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Where only leads may spawn, a session's process holding no role is refused.
    @Test func aSessionWithoutTheLeadRoleCantSpawnWhereOnlyLeadsMay() async throws {
        let host = try TestHost(vault: LeadVault.Book(), spawnNeedsLead: true)
        let app = try TestClient(host)
        let cwd = try spawnFolder()
        let courier = try Courier(temp.url("courier").path, socket: host.socket)
        let session = try await app.spawn(courier.command, cwd: cwd)
        defer { _ = app.send(.kill(id: session.id)) }

        let answers = try await courier.send([.spawn(SpawnRequest(cwd: cwd, command: keepRunning, env: [:], cols: 80, rows: 24,
                                                                  keepShell: false, label: "Test", agent: nil))])
        #expect(answers[2] == .error(HostProtocol.unauthorized), "\(answers)")
    }

    /// Where only leads may spawn, the session the vault binds to the lead role starts a session; one it binds to a
    /// worker's role there can't.
    @Test func aLeadCanSpawnWhereOnlyLeadsMay() async throws {
        let book = LeadVault.Book()
        let host = try TestHost(vault: book, spawnNeedsLead: true)
        let app = try TestClient(host)
        let cwd = try spawnFolder()
        let leadCourier = try Courier(temp.url("lead").path, socket: host.socket)
        let workerCourier = try Courier(temp.url("worker").path, socket: host.socket)
        let lead = try await app.spawn(leadCourier.command, cwd: cwd)
        var started: [UUID] = [lead.id]
        defer { for id in started { _ = app.send(.kill(id: id)) } }
        guard case .grant(let grant) = book.answer(.issue(role: .lead, root: spawnRoot, task: nil, auditing: nil), from: .app) else {
            throw CancellationError()
        }
        #expect(book.answer(.bind(grant: grant, root: spawnRoot, session: lead.id.uuidString), from: .app) == .ok)

        let worker = try await leadCourier.spawn(workerCourier.command, cwd: cwd)
        started.append(worker.id)
        let asLead = LeadVault.Caller.session(lead.id.uuidString)
        guard case .grant(let workerGrant) = book.answer(.issue(role: .worker, root: spawnRoot, task: "t", auditing: nil), from: asLead) else {
            throw CancellationError()
        }
        #expect(book.answer(.bind(grant: workerGrant, root: spawnRoot, session: worker.id.uuidString), from: asLead) == .ok)
        let answers = try await workerCourier.send([.spawn(SpawnRequest(cwd: cwd, command: keepRunning, env: [:], cols: 80, rows: 24,
                                                                        keepShell: false, label: "Test", agent: nil))])
        #expect(answers[2] == .error(HostProtocol.unauthorized), "\(answers)")
    }

    /// Without the rule (every host but the user's on Linux), a session's process with no role starts a session, as
    /// always.
    @Test func aHostWithoutTheRuleSpawnsAsToday() async throws {
        let host = try TestHost(vault: LeadVault.Book())
        let app = try TestClient(host)
        let cwd = try spawnFolder()
        let courier = try Courier(temp.url("courier").path, socket: host.socket)
        let session = try await app.spawn(courier.command, cwd: cwd)
        var started: [UUID] = [session.id]
        defer { for id in started { _ = app.send(.kill(id: id)) } }

        let child = try await courier.spawn(keepRunning, cwd: cwd)
        started.append(child.id)
        #expect(child.isLive)
    }
}
