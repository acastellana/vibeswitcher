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

    // MARK: Function level

    /// Two rows and their jobs, a plist on disk of either, launchd's word for either, and the process at the socket
    /// running either build's host with or without the keeper's flags: what `status`, `stop` and `switched` take.
    struct Pair {
        let a = NodePins.Build(commit: String(repeating: "a", count: 40), host: Data(repeating: 1, count: 20), server: Data(repeating: 2, count: 20),
                               cli: Data(repeating: 3, count: 20))
        let b = NodePins.Build(commit: String(repeating: "b", count: 40), host: Data(repeating: 4, count: 20), server: Data(repeating: 5, count: 20),
                               cli: Data(repeating: 6, count: 20))
        let place: NodeAgent.Place

        init(_ dir: String) {
            place = NodeAgent.Place(label: "dev.vibeswitcher.node.test-fn", plistFolder: dir + "/la", dataRoot: dir + "/node",
                                    lock: dir + "/node/host.lock", uid: getuid(), launchctl: "/bin/launchctl")
            try? FileManager.default.createDirectory(atPath: place.plistFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        }

        func job(_ build: NodePins.Build) -> NodeAgent.Job {
            NodeAgent.Job(label: place.label, programArguments: ["/bin/sleep", "--node-" + build.commit.prefix(1)], environment: [:],
                          standardErrorPath: place.log, atLogin: false)
        }

        func write(_ build: NodePins.Build) throws { try NodeAgent.plist(job(build)).get().write(to: URL(fileURLWithPath: place.plistPath)) }
        var onDisk: Data? { try? Data(contentsOf: URL(fileURLWithPath: place.plistPath)) }
        func bytes(_ build: NodePins.Build) -> Data? { try? NodeAgent.plist(job(build)).get() }

        /// The agent: launchd's word `printed()` (nil: not loaded), the host at the socket `runs`'s, its command line
        /// that build's job's, with the keeper's flags when `switched`.
        func agent(log: MacAgentTests.Recorder, printed: @escaping () -> String?, runs: NodePins.Build, switched: Bool) -> MacAgent {
            let (a, b) = (a, b)
            let jobs = [a.commit: job(a), b.commit: job(b)]
            let arguments = jobs[runs.commit]!.programArguments + (switched ? [NodeAgent.keeperFlags.channel, "5", NodeAgent.keeperFlags.pid, "77"] : [])
            var steps = MacAgent.Steps(launchctl: { words in
                                           log.add(words)
                                           if words.first == "print" { return printed().map { MacAgent.Ran(status: 0, output: $0) } ?? MacAgent.Ran(status: 113, output: "") }
                                           return MacAgent.Ran(status: words.first == "getenv" ? 1 : 0, output: "")
                                       },
                                       pins: { .success(NodePins(uid: getuid(), builds: [a, b])) },
                                       cdhashOf: { path in
                                           let row = path.contains("/" + b.commit + "/") ? b : a
                                           return path.hasSuffix(BuildInfo.host) ? row.host : row.server
                                       },
                                       see: { _, pid, _ in .host(MacAgent.Host(commit: runs.commit, pid: pid, startedAt: nil)) },
                                       say: { log.say($0) }, confirm: { log.say($0); return .failure(StartRefusal("not typed")) },
                                       serverStop: { _ in .none("no server answers") },
                                       children: { _ in [] }, alive: { _ in false }, lockFree: { _ in true }, patience: 2,
                                       arguments: { _ in arguments }, job: { jobs[$0.commit] })
            steps.executable = { _ in "/bin/sleep" }
            return MacAgent(place: place, steps: steps)
        }

        func print(_ build: NodePins.Build) -> String { MacAgentTests.printed(job(build), place: place, pid: 4242) }
    }

    /// After a switch A → B: launchd's job A's, the plist B's, the host B's switched in place: `status` passes naming B.
    /// The same without the keeper's flags (B started otherwise under A's job), or with the host still A (a plist
    /// rewritten without a switch), is refused; with the plist still A's (a switch not followed up) `status` refuses,
    /// saying how to finish it, and `stop` takes the host (it is refused only at its prompt here). A rollback's B → A:
    /// the host A switched in place under A's job with B's plist is rewritten back. Red with the change reverted (the
    /// judge took only the plist's job, and any pinned build's host under it).
    @Test func statusFollowsThePlistTheSwitchRewrote() throws {
        let pair = Pair(try scratch.shortFolder("vsfa").path)
        try pair.write(pair.b)
        let log = MacAgentTests.Recorder()
        let passed = pair.agent(log: log, printed: { pair.print(pair.a) }, runs: pair.b, switched: true).status()
        #expect((try? passed.get())?.contains("build \(pair.b.commit)") == true, "\(passed)")
        guard case .failure(let fresh) = pair.agent(log: log, printed: { pair.print(pair.a) }, runs: pair.b, switched: false).status() else {
            Issue.record("B without the keeper's flags under A's job passed"); return
        }
        #expect(fresh.text.contains("keeper's flags"), "\(fresh.text)")
        guard case .failure(let unswitched) = pair.agent(log: log, printed: { pair.print(pair.a) }, runs: pair.a, switched: false).status() else {
            Issue.record("the host A under B's plist passed"); return
        }
        #expect(unswitched.text.contains("runs build \(pair.a.commit) while the agent's plist is build \(pair.b.commit)'s"), "\(unswitched.text)")
        try pair.write(pair.a)
        guard case .failure(let stale) = pair.agent(log: log, printed: { pair.print(pair.a) }, runs: pair.b, switched: true).status() else {
            Issue.record("a switch not followed up passed status"); return
        }
        #expect(stale.text.contains("vibeswitcher switch \(pair.b.commit)"), "\(stale.text)")
        guard case .failure(let stopped) = pair.agent(log: log, printed: { pair.print(pair.a) }, runs: pair.b, switched: true).stop() else {
            Issue.record("stop went on past its prompt"); return
        }
        #expect(stopped.text == "not typed", "stop refused the switched host: \(stopped.text)")
        #expect(log.bootouts == 0)
        // A rollback B → A whose plist is B's: rewritten back to A's.
        try pair.write(pair.b)
        let back = pair.agent(log: log, printed: { pair.print(pair.a) }, runs: pair.a, switched: true).switched(to: pair.a, folder: "/x/" + pair.a.commit)
        #expect((try? back.get()) != nil, "\(back)")
        #expect(pair.onDisk == pair.bytes(pair.a))
    }

    /// A second switch (or a rollback) before its follow-up: launchd's job A's, the plist B's from the first switch's
    /// rewrite, the host switched in place again (back to A, keeper's flags). The command line's server check
    /// (`runningHost(afterASwitch:)`) and `stop` still take the node, or the switch's own checks and its follow-up
    /// couldn't run; `status` refuses naming the remedy. Without the keeper's flags all three refuse.
    @Test func aSecondSwitchBeforeItsFollowUpIsStillTheNodeToTheServerCheckAndStop() throws {
        let pair = Pair(try scratch.shortFolder("vsfd").path)
        try pair.write(pair.b)
        let log = MacAgentTests.Recorder()
        let switchedBack = pair.agent(log: log, printed: { pair.print(pair.a) }, runs: pair.a, switched: true)
        #expect((try? switchedBack.runningHost(afterASwitch: true).get())?.commit == pair.a.commit, "\(switchedBack.runningHost(afterASwitch: true))")
        guard case .failure(let stopped) = switchedBack.stop() else { Issue.record("stop went on past its prompt"); return }
        #expect(stopped.text == "not typed", "stop refused the switched host: \(stopped.text)")
        guard case .failure(let status) = switchedBack.status() else { Issue.record("status passed with the plist B's while A runs"); return }
        #expect(status.text.contains("vibeswitcher switch \(pair.a.commit)"), "\(status.text)")
        let unswitched = pair.agent(log: log, printed: { pair.print(pair.a) }, runs: pair.a, switched: false)
        if case .success = unswitched.runningHost(afterASwitch: true) { Issue.record("A without the keeper's flags under B's plist taken by the server check") }
        if case .success = unswitched.status() { Issue.record("status took A without the keeper's flags under B's plist") }
        guard case .failure(let notStopped) = unswitched.stop() else { Issue.record("stop took A without the keeper's flags"); return }
        #expect(notStopped.text.contains("isn't the node's host"), "\(notStopped.text)")
        #expect(log.bootouts == 0)
    }

    /// `switched` rewrites nothing unless the job's process is the target's host: the host still A (no handover) leaves
    /// the plist A's; nothing is loaded or unloaded either way.
    @Test func aRewriteIsRefusedUnlessTheHostRunsTheTarget() throws {
        let pair = Pair(try scratch.shortFolder("vsfb").path)
        try pair.write(pair.a)
        let log = MacAgentTests.Recorder()
        guard case .failure(let why) = pair.agent(log: log, printed: { pair.print(pair.a) }, runs: pair.a, switched: false).switched(to: pair.b, folder: "/x/" + pair.b.commit) else {
            Issue.record("rewritten for B while A runs"); return
        }
        #expect(why.text.contains("runs build \(pair.a.commit), not \(pair.b.commit)") && why.text.contains("left as build \(pair.a.commit)'s"), "\(why.text)")
        #expect(pair.onDisk == pair.bytes(pair.a))
        #expect(!log.calls.contains { ["bootout", "bootstrap", "kickstart"].contains($0.first ?? "") }, "\(log.calls)")
    }

    /// A rewrite that fails partway: the new file can't be made (the plist's folder not writable): the old plist whole,
    /// said; the new one written but launchd's word no longer the job's (looked at again after the rename): the old
    /// bytes put back, said. Neither loads or unloads anything.
    @Test func aRewriteThatFailsPartwayLeavesTheOldPlistAndJobWhole() throws {
        let pair = Pair(try scratch.shortFolder("vsfc").path)
        try pair.write(pair.a)
        let log = MacAgentTests.Recorder()
        chmod(pair.place.plistFolder, 0o555)
        let unwritable = pair.agent(log: log, printed: { pair.print(pair.a) }, runs: pair.b, switched: true).switched(to: pair.b, folder: "/x/" + pair.b.commit)
        chmod(pair.place.plistFolder, 0o755)
        guard case .failure(let why) = unwritable else { Issue.record("rewritten in a folder it can't write"); return }
        #expect(why.text.contains("left as build \(pair.a.commit)'s") && why.text.contains("runs on untouched"), "\(why.text)")
        #expect(pair.onDisk == pair.bytes(pair.a))
        // launchd's word changes once B's plist is there (another job's print).
        let other = MacAgentTests.printed(NodeAgent.Job(label: pair.place.label, programArguments: ["/bin/zsh"], environment: [:],
                                                        standardErrorPath: pair.place.log, atLogin: false), place: pair.place, pid: 4242)
        let changed = pair.agent(log: log, printed: { pair.onDisk == pair.bytes(pair.b) ? other : pair.print(pair.a) }, runs: pair.b, switched: true)
            .switched(to: pair.b, folder: "/x/" + pair.b.commit)
        guard case .failure(let after) = changed else { Issue.record("rewritten though launchd's word changed"); return }
        #expect(after.text.contains("put back as build \(pair.a.commit)'s"), "\(after.text)")
        #expect(pair.onDisk == pair.bytes(pair.a))
        #expect(!log.calls.contains { ["bootout", "bootstrap", "kickstart"].contains($0.first ?? "") }, "\(log.calls)")
        let left = try FileManager.default.contentsOfDirectory(atPath: pair.place.plistFolder)
        #expect(left == [pair.place.label + ".plist"], "\(left)")
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
