import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost
@testable import VibeNode

/// Row 10 of the measurement record (item 12, and item 15's owed "a switch must rewrite the plist"): the check that a
/// job's host is the node's reads the host's running image by the connection's audit token, never `launchctl print`'s
/// `program`, and keeps passing across a switch, the plist rewritten for the build it goes to (`MacAgent.switched`).
/// The real runs use a scratch label in this Mac's `gui/<uid>` (`dev.vibeswitcher.node.test-<random>`), a plist folder,
/// data root and builds folder in a scratch folder, and a scratch record; every test boots out what it loaded.
@Suite(.serialized, .enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's launchd"))
struct MacAgentSwitchTests {
    let scratch = Scratch()

    // MARK: A switch, for real

    /// A scratch job of build A started; its host handed over in place to build B through a keeper (asked as the app);
    /// then, with the plist still A's, `status` refuses (the next start would start A: a switch whose plist wasn't
    /// rewritten); `switched(to: B)` rewrites it (launchd's job stays A's, loaded, its host B by token and code); `status`
    /// passes naming B; after `stop`, A's command line's `start` is refused (the plist is B's) and nothing is loaded, and
    /// B's starts B from the plist's exact arguments. Red on the seam: a switch rewrote no plist.
    @Test func aSwitchRewritesThePlistAndStatusAndTheNextStartFollowIt() async throws {
        let stand = try ScratchSwitch(scratch)
        defer { stand.tearDown() }
        _ = try await offPool { stand.agent.start(stand.jobA, build: stand.a, folder: stand.folderA) }.get()
        let pid = try #require(stand.printed()?.pid, "no pid: \(stand.log)")
        stand.loaded.append(pid)
        #expect(try stand.agent.status().get().contains(stand.a.commit))

        // The switch: the host's own handover to B, asked as the app.
        let answer = await stand.handOver(to: stand.folderB + "/bin/" + BuildInfo.host)
        #expect(answer == .ok, "\(String(describing: answer)) \(stand.log)")
        #expect(await eventually { stand.hostRuns(stand.b.host) }, "the host never ran B: \(stand.log)")
        #expect(stand.printed()?.pid == pid, "the switch changed the job's pid")

        // The plist still A's: the next start would start A while B runs. Refused, said.
        guard case .failure(let stale) = await offPool({ stand.agent.status() }) else { Issue.record("status passed with the plist A's while B runs"); return }
        #expect(stale.text.contains(stand.b.commit) && stale.text.contains(stand.a.commit) && stale.text.contains("vibeswitcher switch"), "\(stale.text)")

        // The follow-up: the plist rewritten for B.
        let rewritten = await offPool { stand.agent.switched(to: stand.b, folder: stand.folderB) }
        #expect((try? rewritten.get())?.contains(stand.b.commit) == true, "\(rewritten)")
        let onDisk = try Data(contentsOf: URL(fileURLWithPath: stand.place.plistPath))
        #expect(NodeAgent.check(onDisk, job: stand.jobB) == nil, "the plist isn't B's job")
        let status = await offPool { stand.agent.status() }
        #expect((try? status.get())?.contains("build \(stand.b.commit)") == true, "\(status)")
        #expect((try? await offPool({ stand.agent.runningHost() }).get())?.pid == pid)
        // Again: nothing to rewrite.
        #expect((try? await offPool({ stand.agent.switched(to: stand.b, folder: stand.folderB) }).get())?.contains("already") == true)

        let stopped = await offPool { stand.agent.stop() }
        #expect((try? stopped.get()) != nil, "\(stopped)")
        #expect(stand.printed() == nil)

        // The old command line's start: refused, nothing loaded, the plist left as it is.
        guard case .failure(let old) = await offPool({ stand.agent.start(stand.jobA, build: stand.a, folder: stand.folderA) }) else {
            Issue.record("A's start started over B's plist"); return
        }
        #expect(old.text.contains("isn't the one start writes for this build"), "\(old.text)")
        #expect(stand.printed() == nil, "a job was loaded")
        #expect(try Data(contentsOf: URL(fileURLWithPath: stand.place.plistPath)) == onDisk)

        // The new build's start: B from the plist's exact arguments.
        let started = await offPool { stand.agent.start(stand.jobB, build: stand.b, folder: stand.folderB) }
        #expect((try? started.get())?.contains(stand.b.commit) == true, "\(started) \(stand.log)")
        let second = try #require(stand.printed()?.pid)
        stand.loaded.append(second)
        #expect(Platform.Processes.arguments(second) == stand.jobB.programArguments)
        #expect(stand.hostRuns(stand.b.host))
        _ = await offPool { stand.agent.stop() }
    }

    /// The host check reads the running image, never the program's text: the job's plist names A's pinned host, and the
    /// file at that path is another image (renamed over it after A's start was stopped, before launchd started it again).
    /// launchd's `print` names the pinned host's path; the process at the socket runs other code: `status`, `runningHost`
    /// (the command line's server check's pid) and `switched` refuse it, saying so. The kernel's path of its image is
    /// the job's program by device and inode too (`runsTheProgram` passes): only the token tells.
    @Test func aJobWhosePrintNamesThePinnedHostWhileAnotherImageRunsIsRefused() async throws {
        let stand = try ScratchSwitch(scratch)
        defer { stand.tearDown() }
        _ = try await offPool { stand.agent.start(stand.jobA, build: stand.a, folder: stand.folderA) }.get()
        stand.printed()?.pid.map { stand.loaded.append($0) }
        _ = try await offPool { stand.agent.stop() }.get()
        let host = stand.folderA + "/bin/" + BuildInfo.host
        let evil = stand.dir + "/evil-host"
        try ScratchAgent.run("/bin/cp", [builtProducts.appendingPathComponent("vibeswitcher-host").path, evil])
        try ScratchAgent.run("/usr/bin/codesign", ["--force", "-s", "-", "-o", "runtime", "-i", "dev.vibeswitcher.test.switch.evil", evil])
        #expect(rename(evil, host) == 0)
        #expect(stand.launchctl(["bootstrap", stand.place.domain, stand.place.plistPath])?.status == 0)
        #expect(stand.launchctl(["kickstart", stand.place.target])?.status == 0)
        #expect(await eventually { stand.printed()?.pid != nil })
        let pid = try #require(stand.printed()?.pid)
        stand.loaded.append(pid)
        #expect(await eventually { (try? UnixSocket.connect(path: stand.place.socket)).map { Sys.close($0); return true } ?? false })
        #expect(NodeAgent.printed(stand.launchctl(["print", stand.place.target])?.output ?? "").program == host, "print doesn't name the pinned host's path")
        guard case .failure(let why) = await offPool({ stand.agent.status() }) else { Issue.record("status took another image for the pinned host"); return }
        #expect(why.exitCode == 77 && why.text.contains("doesn't run a host the node's record pins"), "\(why.text)")
        if case .success = await offPool({ stand.agent.runningHost() }) { Issue.record("the server check's pid would be taken from it") }
        guard case .failure(let refusedSwitch) = await offPool({ stand.agent.switched(to: stand.a, folder: stand.folderA) }) else {
            Issue.record("switched took it"); return
        }
        #expect(refusedSwitch.text.contains("doesn't run a host the node's record pins") || refusedSwitch.text.contains("no plist"), "\(refusedSwitch.text)")
    }
}

/// Two scratch builds, A and B, each a hardened copy of the built host and server signed under identifiers of their own
/// (so each has its own cdhash) and, as `bin/VibeSwitcher` (the folder's app, on this case-insensitive volume the
/// command line's name too), this test process's own binary: the scratch host's app is then this process, which may
/// ask it to hand over. A job of each: the scratch host's arguments, A's carrying `--handover-test-keeper` with B's host
/// code (the scratch host's stand-in for the record a checked node reads), B's the same with B's host. The agent's
/// steps are this Mac's, but the record and the jobs, and one reader: a scratch host's switched image carries
/// `--handover <state>` a checked node's doesn't (its grammar takes none, `MacHandoverSwitch`), so that pair alone is
/// dropped from the kernel's arguments; every other word is the kernel's.
final class ScratchSwitch: @unchecked Sendable {
    let dir: String
    let place: NodeAgent.Place
    let a: NodePins.Build
    let b: NodePins.Build
    let folderA: String
    let folderB: String
    let jobA: NodeAgent.Job
    let jobB: NodeAgent.Job
    let agent: MacAgent
    var loaded: [pid_t] = []
    private var tornDown = false
    private var connection: HostConnection?
    private let queue = DispatchQueue(label: "scratch-switch")

    init(_ scratch: Scratch) throws {
        let dir = try scratch.shortFolder("vssw").path
        self.dir = dir
        let label = "dev.vibeswitcher.node.test-" + UUID().uuidString.prefix(8).lowercased()
        precondition(label.hasPrefix("dev.vibeswitcher.node.test-") && label != NodeAgent.label)
        let data = dir + "/node"
        let place = NodeAgent.Place(label: label, plistFolder: dir + "/LaunchAgents", dataRoot: data, lock: data + "/scratch-host.lock",
                                    uid: getuid(), launchctl: "/bin/launchctl")
        self.place = place
        func commit(_ letter: Character) -> String { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(32)) + String(repeating: letter, count: 8) }
        let runner = try #require(HostServer.executable(of: getpid()))
        let files = FileManager.default
        for made in [dir + "/home", dir + "/t", data] { try files.createDirectory(atPath: made, withIntermediateDirectories: true) }
        func build(_ commit: String, _ name: String, age: TimeInterval) throws -> (NodePins.Build, String) {
            let folder = dir + "/builds/" + commit
            try files.createDirectory(atPath: folder + "/bin", withIntermediateDirectories: true)
            func signed(_ product: String, as file: String, _ identifier: String) throws -> Data {
                let path = folder + "/bin/" + file
                try ScratchAgent.run("/bin/cp", [builtProducts.appendingPathComponent(product).path, path])
                try ScratchAgent.run("/usr/bin/codesign", ["--force", "-s", "-", "-o", "runtime", "-i", identifier, path])
                try files.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: path)
                return try #require(Platform.CodeIdentity.cdhash(atPath: path))
            }
            let host = try signed("vibeswitcher-host", as: BuildInfo.host, "dev.vibeswitcher.test.switch.\(name).host")
            let server = try signed("vibeswitcher-server", as: BuildInfo.server, "dev.vibeswitcher.test.switch.\(name).server")
            try ScratchAgent.run("/bin/cp", [runner, folder + "/bin/VibeSwitcher"])
            let cli = try #require(Platform.CodeIdentity.cdhash(atPath: folder + "/bin/VibeSwitcher"))
            return (NodePins.Build(commit: commit, host: host, server: server, cli: cli), folder)
        }
        (a, folderA) = try build(commit("a"), "a", age: 2_000)
        (b, folderB) = try build(commit("b"), "b", age: 1_000)
        let rest = ["--socket", place.socket, "--lock", place.lock, "--idle-exit", "600", "--log", data + "/session.log",
                    "--handover-test-keeper", NodePins.hex(b.host)]
        let environment = ["HOME": dir + "/home", "CFFIXED_USER_HOME": dir + "/home", "VIBESWITCHER_HOME": data,
                           "TMPDIR": dir + "/t/", "SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"]
        jobA = NodeAgent.Job(label: label, programArguments: [folderA + "/bin/" + BuildInfo.host] + rest, environment: environment,
                             standardErrorPath: place.log, atLogin: false)
        jobB = NodeAgent.Job(label: label, programArguments: [folderB + "/bin/" + BuildInfo.host] + rest, environment: environment,
                             standardErrorPath: place.log, atLogin: false)
        let pins = NodePins(uid: getuid(), builds: [a, b])
        let (theA, theB, jobOfA, jobOfB) = (a, b, jobA, jobB)
        var steps = MacAgent.Steps.system(place: place, pins: { .success(pins) }, say: { _ in }, confirm: { _ in .success(()) },
                                          serverStop: { _ in .none("no server answers") },
                                          job: { $0 == theA ? jobOfA : $0 == theB ? jobOfB : nil })
        steps.arguments = { pid in
            var words = Platform.Processes.arguments(pid)
            if let at = words.firstIndex(of: "--handover"), at + 1 < words.count { words.removeSubrange(at...(at + 1)) }
            return words
        }
        agent = MacAgent(place: place, steps: steps)
    }

    func launchctl(_ arguments: [String]) -> MacAgent.Ran? {
        NodeStarter.run(place.launchctl, arguments, environment: ["PATH=/usr/bin:/bin"], timeout: 30).map { MacAgent.Ran(status: $0.status, output: $0.output) }
    }

    func printed() -> NodeAgent.Printed? {
        guard let ran = launchctl(["print", place.target]), ran.status == 0 else { return nil }
        return NodeAgent.printed(ran.output)
    }

    var log: String { (try? String(contentsOfFile: place.log, encoding: .utf8)) ?? "(no log)" }

    /// Whether a new connection to the host's socket has a token running `cdhash`.
    func hostRuns(_ cdhash: Data) -> Bool {
        guard let fd = try? UnixSocket.connect(path: place.socket) else { return false }
        defer { Sys.close(fd) }
        return Platform.Sockets.peerToken(fd).map { Platform.CodeIdentity.runs($0, cdhash: cdhash) } ?? false
    }

    /// The host asked, as its app (this process's code, the key enrolled on the first connection), to hand over to
    /// `executable`: its answer.
    func handOver(to executable: String) async -> HostEvent? {
        let answer = Locked<HostEvent?>(nil)
        let sent = Locked<Int?>(nil)
        guard let connection = try? HostConnection(path: place.socket, queue: queue, appKey: SymmetricKey(size: .bits256), patience: 5, viaConnector: false) else {
            return nil
        }
        self.connection = connection
        connection.onEvent = { envelope in
            if let seq = sent.value, envelope.replyTo == seq { answer.value = envelope.event }
        }
        queue.sync { sent.value = try? connection.send(.handover(executable: executable)) }
        _ = await eventually(timeout: 60) { answer.value != nil }
        return answer.value
    }

    func tearDown() {
        guard !tornDown else { return }
        tornDown = true
        connection?.close()
        precondition(place.label.hasPrefix("dev.vibeswitcher.node.test-"))
        if let pid = printed()?.pid { loaded.append(pid) }
        _ = launchctl(["bootout", place.target])
        for pid in loaded where kill(pid, 0) == 0 && Platform.Processes.arguments(pid).first.map({ $0.hasPrefix(dir) }) == true {
            kill(pid, SIGKILL)
        }
    }

    deinit { tearDown() }
}
