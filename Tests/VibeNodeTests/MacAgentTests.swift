import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost
@testable import VibeNode

/// The Mac's LaunchAgent run for real (`MacAgent`, the node on the Mac's design, "The LaunchAgent: start, stop and
/// status"): a scratch job in this Mac's `gui/<uid>` domain, its label `dev.vibeswitcher.node.test-<random>` (never the
/// node's), its plist folder and data root in a scratch folder (never `~/Library/LaunchAgents`, never
/// `~/.vibeswitcher`), its host a scratch host on hardened copies of the built host, server and command line pinned by a
/// scratch record. What a scratch host can't be is a checked node (`HostImages.isCheckedMacNode` is off and its record
/// isn't a test's to choose), so the real plist's checked command line is tested as data (`NodeAgentTests`), and the
/// job here runs the scratch host's own arguments. Every test boots out what it loaded, failing or not
/// (`ScratchAgent.tearDown`, from `deinit` too).
@Suite(.serialized, .enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's launchd"))
struct MacAgentTests {
    let scratch = Scratch()

    // MARK: (a) start, status, stop

    /// `start` writes and checks the plist, loads the job and its host comes up from the plist's exact arguments, known
    /// by token and code; `status` says so with its build; `stop` unloads it and nothing of it is left: no job, no
    /// process, no socket. Red before: `start` wasn't built.
    @Test func startLoadsTheJobAndStopLeavesNothing() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        let started = await offPool { agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }
        let said = try started.get()
        #expect(said.contains(agent.build.commit), "\(said)")
        let printed = agent.printed()
        let pid = try #require(printed?.pid, "no pid: \(agent.log)")
        agent.loaded.append(pid)
        #expect(Platform.Processes.arguments(pid) == agent.job.programArguments)
        #expect(NodeAgent.check(try Data(contentsOf: URL(fileURLWithPath: agent.place.plistPath)), job: agent.job) == nil)
        let status = try await offPool { agent.agent.status() }.get()
        #expect(status.contains(agent.build.commit) && status.contains("pid \(pid)"), "\(status)")
        let stopped = await offPool { agent.agent.stop() }
        #expect((try? stopped.get()) != nil, "\(stopped)")
        #expect(agent.printed() == nil, "the job is still loaded")
        #expect(kill(pid, 0) != 0 && errno == ESRCH, "the host runs on")
        #expect((try? UnixSocket.connect(path: agent.place.socket)).map { Sys.close($0); return true } == nil, "something listens")
        #expect(!FileManager.default.fileExists(atPath: agent.place.socket), "the socket's file is left")
        if case .failure(let why) = await offPool({ agent.agent.status() }) { #expect(why.exitCode == 69) } else { Issue.record("status says it runs") }
    }

    // MARK: (b) a plist that isn't start's

    /// A plist at the agent's path that differs from the one `start` would write is refused before any load, and left
    /// as it is. Red before: `start` wasn't built (it refused for that).
    @Test func aChangedPlistIsRefusedBeforeAnyLoad() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        var values = NodeAgent.dictionary(agent.job)
        values["KeepAlive"] = true
        let planted = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        try FileManager.default.createDirectory(atPath: agent.place.plistFolder, withIntermediateDirectories: true)
        try planted.write(to: URL(fileURLWithPath: agent.place.plistPath))
        let started = await offPool { agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }
        guard case .failure(let why) = started else { Issue.record("started on a changed plist"); return }
        #expect(why.text.contains("KeepAlive"), "\(why.text)")
        #expect(agent.printed() == nil, "a job was loaded")
        #expect(try Data(contentsOf: URL(fileURLWithPath: agent.place.plistPath)) == planted)
    }

    // MARK: (c) a job of the label running another program

    /// A job of that label already running another program (`/bin/sleep`, loaded from another plist) is refused by
    /// `start` and by `stop`, and left alone: the same pid runs on. Red before: `start` wasn't built.
    @Test func aJobOfTheLabelRunningAnotherProgramIsLeftAlone() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        let other = agent.dir + "/other.plist"
        let values: [String: Any] = ["Label": agent.place.label, "ProgramArguments": ["/bin/sleep", "600"], "RunAtLoad": true, "KeepAlive": false]
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: URL(fileURLWithPath: other))
        #expect(agent.launchctl(["bootstrap", agent.place.domain, other])?.status == 0)
        #expect(await eventually { agent.printed()?.pid != nil })
        let pid = try #require(agent.printed()?.pid)
        agent.loaded.append(pid)
        let started = await offPool { agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }
        guard case .failure(let why) = started else { Issue.record("started over another program"); return }
        #expect(why.text.contains("isn't the node's"), "\(why.text)")
        let stopped = await offPool { agent.agent.stop() }
        guard case .failure(let stopWhy) = stopped else { Issue.record("stopped another program"); return }
        #expect(stopWhy.text.contains("isn't the node's"), "\(stopWhy.text)")
        #expect(agent.printed()?.pid == pid && kill(pid, 0) == 0, "the other program wasn't left alone")
        #expect(!FileManager.default.fileExists(atPath: agent.place.plistPath), "start wrote its plist anyway")
    }

    // MARK: (d) the host known by token and code

    /// The host is known by its connection's audit token and running code: the job's host passes; the same host checked
    /// against a record that pins another host's code doesn't; and a look-alike (`perl` started as `exec -a <the host's
    /// path>`, listening on a socket, its first argument the host's path's text) doesn't. Red before: `see` wasn't built.
    @Test func theHostIsKnownByTokenAndCodeNotByThePathsText() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        _ = try await offPool { agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }.get()
        let pid = try #require(agent.printed()?.pid)
        agent.loaded.append(pid)
        guard case .host(let host) = MacAgent.see(socket: agent.place.socket, pid: pid, builds: [agent.build]) else {
            Issue.record("the job's host wasn't known: \(MacAgent.see(socket: agent.place.socket, pid: pid, builds: [agent.build]))"); return
        }
        #expect(host.commit == agent.build.commit && host.pid == pid)
        var elsewhere = agent.build
        elsewhere.host = agent.build.server
        guard case .other = MacAgent.see(socket: agent.place.socket, pid: pid, builds: [elsewhere]) else {
            Issue.record("a host the record doesn't pin passed"); return
        }
        // The look-alike: the host's path as its first argument, listening.
        let socket = agent.dir + "/l.sock", ready = agent.dir + "/l.ready"
        let listen = "use IO::Socket::UNIX; my $s = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => $ARGV[0], Listen => 5) or die; "
            + "open(my $f, '>', $ARGV[1]); close($f); while (my $c = $s->accept) { sleep 30 }"
        var spawn = Platform.Spawn(executable: "/bin/bash", arguments: ["bash", "-c", "exec -a \"$0\" /usr/bin/perl -e \"$1\" \"$2\" \"$3\"",
                                                                        agent.job.programArguments[0], listen, socket, ready])
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        guard case .success(let lookalike) = spawn.start() else { Issue.record("the look-alike didn't start"); return }
        defer { kill(lookalike, SIGKILL); var status: Int32 = 0; waitpid(lookalike, &status, 0) }
        #expect(await eventually { FileManager.default.fileExists(atPath: ready) })
        #expect(Platform.Processes.arguments(lookalike).first == agent.job.programArguments[0])
        guard case .other(let why) = MacAgent.see(socket: socket, pid: lookalike, builds: [agent.build]) else {
            Issue.record("the look-alike passed"); return
        }
        #expect(why.contains("doesn't run a host the node's record pins"), "\(why)")
    }

    // MARK: (e) a crash

    /// The host killed: launchd doesn't start it again (`KeepAlive` false): once launchd says the job doesn't run, its
    /// run count is still 1 and it has no pid; `status` says it doesn't run, with the signal; `start` again unloads the
    /// dead job and loads it afresh. Red before: `start` wasn't built.
    @Test func aCrashedHostIsNotStartedAgainByLaunchd() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        _ = try await offPool { agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }.get()
        let pid = try #require(agent.printed()?.pid)
        agent.loaded.append(pid)
        #expect(kill(pid, SIGKILL) == 0)
        #expect(await eventually { agent.printed()?.state == "not running" }, "\(String(describing: agent.printed()))")
        let after = try #require(agent.printed())
        #expect(after.pid == nil && after.runs == 1 && after.lastExit?.contains("signal") == true, "\(after)")
        guard case .failure(let why) = await offPool({ agent.agent.status() }) else { Issue.record("status says a killed host runs"); return }
        #expect(why.exitCode == 69 && why.text.contains("signal"), "\(why.text)")
        let again = await offPool { agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }
        #expect((try? again.get()) != nil, "\(again)")
        let second = try #require(agent.printed())
        #expect(second.pid != nil && second.pid != pid && second.runs == 1, "\(second)")
        second.pid.map { agent.loaded.append($0) }
        _ = await offPool { agent.agent.stop() }
    }

    // MARK: Function level

    /// The build the command line is in, by its own code: a code no row's command line is refuses, as does a record
    /// that can't be read; a row's command line gives its row and folder. Red before: not built.
    @Test func theBuildIsTheCommandLinesOwnRow() throws {
        let row = NodePins.Build(commit: String(repeating: "a", count: 40), host: Data(repeating: 1, count: 20), server: Data(repeating: 2, count: 20),
                                 cli: Data(repeating: 3, count: 20))
        let pins = NodePins(uid: getuid(), builds: [row])
        let found = try MacAgent.ownBuild(own: row.cli, pins: .success(pins), prefix: "/b").get()
        #expect(found.build == row && found.folder == "/b/" + row.commit)
        if case .success = MacAgent.ownBuild(own: row.host, pins: .success(pins), prefix: "/b") { Issue.record("a host's code taken for the command line's") }
        if case .success = MacAgent.ownBuild(own: nil, pins: .success(pins), prefix: "/b") { Issue.record("no code taken") }
        if case .success = MacAgent.ownBuild(own: row.cli, pins: .failure(.init("missing")), prefix: "/b") { Issue.record("no record taken") }
    }

    /// `start` refuses a build whose files aren't the record's before it writes or loads anything: no launchctl but
    /// `print` (and `getenv`) is run. Red before: not built.
    @Test func aBuildWhoseFilesAreNotPinnedLoadsNothing() throws {
        let dir = try scratch.shortFolder("vsma")
        let row = NodePins.Build(commit: String(repeating: "b", count: 40), host: Data(repeating: 1, count: 20), server: Data(repeating: 2, count: 20),
                                 cli: Data(repeating: 3, count: 20))
        let place = NodeAgent.Place(label: "dev.vibeswitcher.node.test-fn", plistFolder: dir.path + "/la", dataRoot: dir.path + "/node",
                                    lock: dir.path + "/node/host.lock", uid: getuid(), launchctl: "/bin/launchctl")
        var ran: [[String]] = []
        let steps = MacAgent.Steps(launchctl: { ran.append($0); return MacAgent.Ran(status: 113, output: "") },
                                   pins: { .success(NodePins(uid: getuid(), builds: [row])) },
                                   cdhashOf: { $0.hasSuffix("vibeswitcher-host") ? Data(repeating: 9, count: 20) : row.server },
                                   see: { _, _, _ in .nothing("") }, say: { _ in }, confirm: { _ in .success(()) }, serverStop: { _ in .none("no server answers") },
                                   children: { _ in [] }, alive: { _ in false }, lockFree: { _ in true })
        let job = NodeAgent.Job(label: place.label, programArguments: ["/x/bin/vibeswitcher-host"], environment: [:], standardErrorPath: place.log, atLogin: false)
        let started = MacAgent(place: place, steps: steps).start(job, build: row, folder: "/x")
        guard case .failure(let why) = started else { Issue.record("started a build the record doesn't pin"); return }
        #expect(why.text.contains("record"), "\(why.text)")
        #expect(!ran.contains { $0.first == "bootstrap" || $0.first == "kickstart" }, "\(ran)")
        #expect(!FileManager.default.fileExists(atPath: place.plistPath))
    }

    /// `see`'s reads, each a refusal when it fails: another pid's token, code no row's host, no Hardened Runtime, the
    /// process changed between the reads, no welcome. Red before: not built.
    @Test func seeRefusesEveryReadThatFails() {
        let row = NodePins.Build(commit: String(repeating: "c", count: 40), host: Data(repeating: 1, count: 20), server: Data(repeating: 2, count: 20),
                                 cli: Data(repeating: 3, count: 20))
        let token = ApprovalVoiceTests.token(42)
        let link = Platform.Processes.Link(pid: 42, parent: 1, startTicks: 7, terminal: nil)
        func see(pid: pid_t = 42, runs: Bool = true, hardened: Bool? = true, changes: Bool = false, welcome: MacAgent.Welcome? = .init(pid: 42, startedAt: nil)) -> MacAgent.Seen {
            var reads = 0
            return MacAgent.see(socket: "/s", pid: pid, builds: [row], connect: { _ in 99 }, token: { _ in token },
                                link: { _ in reads += 1; return changes && reads > 1 ? Platform.Processes.Link(pid: 42, parent: 1, startTicks: 8, terminal: nil) : link },
                                runs: { _, cdhash in runs && cdhash == row.host }, hardened: { _ in hardened }, bound: { _, _ in true },
                                welcome: { _ in welcome }, close: { _ in })
        }
        #expect(see() == .host(MacAgent.Host(commit: row.commit, pid: 42, startedAt: nil)))
        for (seen, what) in [(see(pid: 43), "another pid"), (see(runs: false), "no pinned host"), (see(hardened: nil), "not hardened"),
                             (see(changes: true), "changed"), (see(welcome: nil), "no welcome"),
                             (see(welcome: .init(pid: 7, startedAt: nil)), "another pid's welcome")] {
            guard case .other = seen else { Issue.record("\(what) passed: \(seen)"); continue }
        }
        #expect(MacAgent.see(socket: "/s", pid: 42, builds: [row], connect: { _ in nil }, close: { _ in }) == .nothing("nothing takes a connection at /s"))
    }

    /// Stand-ins for `start`, `stop` and `status` at function level (the blind check's findings): a job of the label at
    /// `pid` (or loaded from `path` and not running), `see` passing as `row`'s host, `arguments` its command line.
    struct Stand {
        let row = NodePins.Build(commit: String(repeating: "d", count: 40), host: Data(repeating: 1, count: 20), server: Data(repeating: 2, count: 20),
                                 cli: Data(repeating: 3, count: 20))
        let place: NodeAgent.Place
        var ran: [[String]] = []
        var said: [String] = []

        init(_ dir: String) {
            place = NodeAgent.Place(label: "dev.vibeswitcher.node.test-fn", plistFolder: dir + "/la", dataRoot: dir + "/node",
                                    lock: dir + "/node/host.lock", uid: getuid(), launchctl: "/bin/launchctl")
            // start's own plist at the agent's path, as a job of it loaded from there would have.
            try? FileManager.default.createDirectory(atPath: place.plistFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            try? NodeAgent.plist(job).get().write(to: URL(fileURLWithPath: place.plistPath))
        }

        var job: NodeAgent.Job { NodeAgent.Job(label: place.label, programArguments: ["/bin/sleep", "--node"], environment: [:],
                                               standardErrorPath: place.log, atLogin: false) }

        /// The agent, `launchctl` recording into `log` (print answering `printed`, bootstrap `bootstrap`).
        func agent(log: Recorder, printed: @escaping () -> String?, bootstrap: Int32 = 0, arguments: [String]? = nil, sessions: Int? = nil) -> MacAgent {
            let row = self.row, job = self.job
            let steps = MacAgent.Steps(launchctl: { words in
                                           log.add(words)
                                           if words.first == "print" { return printed().map { MacAgent.Ran(status: 0, output: $0) } ?? MacAgent.Ran(status: 113, output: "") }
                                           if words.first == "bootstrap" { return MacAgent.Ran(status: bootstrap, output: "") }
                                           return MacAgent.Ran(status: words.first == "getenv" ? 1 : 0, output: "")
                                       },
                                       pins: { .success(NodePins(uid: getuid(), builds: [row])) },
                                       cdhashOf: { $0.hasSuffix("vibeswitcher-host") ? row.host : row.server },
                                       see: { _, pid, _ in .host(MacAgent.Host(commit: row.commit, pid: pid, startedAt: nil)) },
                                       say: { log.say($0) }, confirm: { log.say($0); return .failure(StartRefusal("not typed")) },
                                       serverStop: { what in log.say(what); return sessions == nil ? .none("no server answers") : .refused(StartRefusal("not typed")) },
                                       children: { _ in [] }, alive: { _ in false }, lockFree: { _ in true }, patience: 2,
                                       arguments: { _ in arguments ?? job.programArguments }, job: { $0 == row ? job : nil },
                                       server: { sessions.map { .answered(sessions: $0) } ?? .none("no server answers") })
            var stepped = steps
            stepped.executable = { _ in job.programArguments[0] }
            return MacAgent(place: place, steps: stepped)
        }
    }

    final class Recorder: @unchecked Sendable {
        var calls: [[String]] = []
        var lines: [String] = []
        func add(_ words: [String]) { calls.append(words) }
        func say(_ line: String) { lines.append(line) }
        var bootouts: Int { calls.filter { $0.first == "bootout" }.count }
    }

    /// A bootstrap that fails loaded nothing of this start's: what is there is left alone (no bootout). The blind
    /// check's finding 2: two starts at once, the second booting out the first's job.
    @Test func aFailedBootstrapBootsOutNothing() throws {
        let stand = Stand(try scratch.shortFolder("vsmb").path)
        let log = Recorder()
        let started = stand.agent(log: log, printed: { nil }, bootstrap: 5).start(stand.job, build: stand.row, folder: "/x")
        guard case .failure(let why) = started else { Issue.record("started"); return }
        #expect(why.text.contains("bootstrap"), "\(why.text)")
        #expect(log.bootouts == 0, "\(log.calls)")
    }

    /// A job of the label loaded and not running from another file than the agent's is refused by `start` and `stop`
    /// and left loaded; one from the agent's own file is unloaded.
    @Test func aStoppedJobFromAnotherPlistIsLeftAlone() throws {
        let stand = Stand(try scratch.shortFolder("vsmo").path)
        // launchd's word (this Mac's print, cut) for the agent's job loaded from another file.
        let other = MacAgentTests.printed(stand.job, place: stand.place, pid: nil)
            .replacingOccurrences(of: "\tpath = \(MacAgent.canonicalPlistPath(stand.place))", with: "\tpath = /elsewhere/x.plist")
        let log = Recorder()
        guard case .failure(let why) = stand.agent(log: log, printed: { other }).start(stand.job, build: stand.row, folder: "/x") else {
            Issue.record("started over another plist's job"); return
        }
        #expect(why.text.contains("/elsewhere/x.plist") && log.bootouts == 0, "\(why.text) \(log.calls)")
        guard case .failure = stand.agent(log: log, printed: { other }).stop() else { Issue.record("stopped another plist's job"); return }
        #expect(log.bootouts == 0, "\(log.calls)")
        let ours = MacAgentTests.printed(stand.job, place: stand.place, pid: nil)
        var loaded = true
        let unloads = Recorder()
        _ = stand.agent(log: unloads, printed: { defer { if unloads.bootouts > 0 { loaded = false } }; return loaded ? ours : nil }).stop()
        #expect(unloads.bootouts == 1, "\(unloads.calls)")
    }

    /// The job's process must run the job's command line, not only the pinned host's code (the blind check's finding
    /// 3: a plist swapped before launchd read it, the pinned host with `--socket` and `--lock` of its own): `start`
    /// refuses and unloads it, `status` and `stop` refuse it; after a switch the keeper's two flags may follow.
    @Test func theJobsProcessMustRunTheJobsCommandLine() throws {
        let stand = Stand(try scratch.shortFolder("vsmc").path)
        let running = MacAgentTests.printed(stand.job, place: stand.place, pid: 4242)
        let swapped = ["/x/bin/vibeswitcher-host", "--socket", stand.place.socket, "--lock", "/elsewhere/h.lock"]
        let log = Recorder()
        // The job appears once start has loaded it.
        let agent = stand.agent(log: log, printed: { log.calls.contains { $0.first == "bootstrap" } ? running : nil }, arguments: swapped)
        guard case .failure(let why) = agent.start(stand.job, build: stand.row, folder: "/x") else {
            Issue.record("a job running other arguments was taken for the node"); return
        }
        #expect(why.text.contains("not the job's command line") && log.bootouts >= 1, "\(why.text) \(log.calls)")
        let fresh = Recorder()
        if case .success = stand.agent(log: fresh, printed: { running }, arguments: swapped).status() { Issue.record("status took it for the node") }
        if case .success = stand.agent(log: fresh, printed: { running }, arguments: swapped).stop() { Issue.record("stop took it for the node") }
        #expect(fresh.bootouts == 0)
        let switched = stand.job.programArguments + [NodeAgent.keeperFlags.channel, "5", NodeAgent.keeperFlags.pid, "77"]
        #expect((try? stand.agent(log: fresh, printed: { running }, arguments: switched).status().get()) != nil, "a switched node refused")
        // The flags are the keeper's own.
        #expect(NodeAgent.keeperFlags.channel == MacHandoverKeeper.channelFlag && NodeAgent.keeperFlags.pid == MacHandoverKeeper.pidFlag)
    }

    /// `stop` says how many sessions end from the server's count (the blind check's finding 1: the host's welcome
    /// lists none of them to the command line), or, with no server, how they end (the bootout, the hangup).
    @Test func stopSaysTheServersSessionCount() throws {
        let stand = Stand(try scratch.shortFolder("vsms").path)
        let running = MacAgentTests.printed(stand.job, place: stand.place, pid: 4242)
        let counted = Recorder()
        _ = stand.agent(log: counted, printed: { running }, sessions: 5).stop()
        #expect(counted.lines.contains { $0.contains("its 5 sessions") }, "\(counted.lines)")
        let none = Recorder()
        _ = stand.agent(log: none, printed: { running }).stop()
        #expect(none.lines.contains { $0.contains("by launchd's bootout") && $0.contains("hangup") }, "\(none.lines)")
    }
}

extension MacAgentTests {
    /// `launchctl print`'s text for a job of `job` loaded from `place`'s plist, cut from this Mac's captures (macOS 27.2:
    /// `PrintFixtures`) with the job's own values put in: running at `pid`, or `fixture` (`.loaded`, `.killed`) when not.
    static func printed(_ job: NodeAgent.Job, place: NodeAgent.Place, pid: pid_t?, fixture: String? = nil) -> String {
        let arguments = job.programArguments.map { "\t\t\($0)\n" }.joined()
        let environment = (["\t\tOSLogRateLimit => 64\n"] + job.environment.sorted { $0.key < $1.key }.map { "\t\t\($0.key) => \($0.value)\n" }
                           + ["\t\tXPC_SERVICE_NAME => \(job.label)\n"]).joined()
        var text = (fixture ?? (pid == nil ? PrintFixtures.loaded : PrintFixtures.running))
            .replacingOccurrences(of: "{TARGET}", with: place.target)
            .replacingOccurrences(of: "{PLIST}", with: MacAgent.canonicalPlistPath(place))
            .replacingOccurrences(of: "{PROGRAM}", with: job.programArguments[0])
            .replacingOccurrences(of: "{ARGUMENTS}", with: arguments)
            .replacingOccurrences(of: "{STDERR}", with: job.standardErrorPath)
            .replacingOccurrences(of: "{ENVIRONMENT}", with: environment)
            .replacingOccurrences(of: "{PID}", with: pid.map(String.init) ?? "")
            .replacingOccurrences(of: "{UID}", with: String(place.uid))
            .replacingOccurrences(of: "{LABEL}", with: job.label)
        if job.atLogin {
            text = text.replacingOccurrences(of: "\tproperties = inferred program", with: "\tproperties = runatload | inferred program")
                .replacingOccurrences(of: "immediate reason = non-ipc demand", with: "immediate reason = speculative")
        }
        return text + "\n"
    }
}

/// A scratch agent: a scratch label, plist folder and data root, a build folder of hardened copies of the built host,
/// server and command line, and a scratch record pinning them; `MacAgent` with this Mac's readers but that record.
/// `tearDown` boots out the scratch label and ends what the test loaded, whatever happened.
final class ScratchAgent: @unchecked Sendable {
    let dir: String
    let place: NodeAgent.Place
    let folder: String
    let build: NodePins.Build
    let job: NodeAgent.Job
    let agent: MacAgent
    /// The pids of what the test loaded, ended at the tear-down if still there.
    var loaded: [pid_t] = []
    private var tornDown = false

    init(_ scratch: Scratch) throws {
        let dir = try scratch.shortFolder("vsag").path
        self.dir = dir
        let label = "dev.vibeswitcher.node.test-" + UUID().uuidString.prefix(8).lowercased()
        // Never the node's own label, folder or root.
        precondition(label.hasPrefix("dev.vibeswitcher.node.test-") && label != NodeAgent.label)
        let data = dir + "/node"
        let place = NodeAgent.Place(label: label, plistFolder: dir + "/LaunchAgents", dataRoot: data, lock: data + "/scratch-host.lock",
                                    uid: getuid(), launchctl: "/bin/launchctl")
        self.place = place
        let commit = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(32)) + "00000000"
        let builds = dir + "/builds/" + commit
        folder = builds
        let files = FileManager.default
        for made in [builds + "/bin", dir + "/home", dir + "/t", data] { try files.createDirectory(atPath: made, withIntermediateDirectories: true) }
        func copied(_ product: String, as name: String, _ identifier: String) throws -> Data {
            let path = builds + "/bin/" + name
            try Self.run("/bin/cp", [builtProducts.appendingPathComponent(product).path, path])
            try Self.run("/usr/bin/codesign", ["--force", "-s", "-", "-o", "runtime", "-i", identifier, path])
            return try #require(Platform.CodeIdentity.cdhash(atPath: path))
        }
        let build = NodePins.Build(commit: commit, host: try copied("vibeswitcher-host", as: BuildInfo.host, "dev.vibeswitcher.test.agent.host"),
                               server: try copied("vibeswitcher-server", as: BuildInfo.server, "dev.vibeswitcher.test.agent.server"),
                               cli: try copied("vibeswitcher-cli", as: "vibeswitcher", "dev.vibeswitcher.test.agent.cli"))
        self.build = build
        let pins = NodePins(uid: getuid(), builds: [build])
        job = NodeAgent.Job(label: label, programArguments: [builds + "/bin/" + BuildInfo.host, "--socket", place.socket, "--lock", place.lock,
                                                             "--idle-exit", "600", "--log", data + "/session.log"],
                            environment: ["HOME": dir + "/home", "CFFIXED_USER_HOME": dir + "/home", "VIBESWITCHER_HOME": data,
                                          "TMPDIR": dir + "/t/", "SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"],
                            standardErrorPath: place.log, atLogin: false)
        let theJob = job
        agent = MacAgent(place: place, steps: MacAgent.Steps.system(place: place, pins: { .success(pins) }, say: { _ in },
                                                                     confirm: { _ in .success(()) }, serverStop: { _ in .none("no server answers") },
                                                                     job: { $0 == build ? theJob : nil }))
    }

    static func run(_ program: String, _ arguments: [String]) throws {
        var spawn = Platform.Spawn(executable: program, arguments: [program] + arguments)
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        guard case .success(let pid) = spawn.start() else { throw CocoaError(.fileWriteUnknown) }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        try #require(status == 0, "\(program) \(arguments) exited \(status)")
    }

    func launchctl(_ arguments: [String]) -> MacAgent.Ran? { NodeStarter.run(place.launchctl, arguments, environment: ["PATH=/usr/bin:/bin"], timeout: 30).map { MacAgent.Ran(status: $0.status, output: $0.output) } }

    /// What launchd says of the scratch job; nil while none is loaded.
    func printed() -> NodeAgent.Printed? {
        guard let ran = launchctl(["print", place.target]), ran.status == 0 else { return nil }
        return NodeAgent.printed(ran.output)
    }

    var log: String { (try? String(contentsOfFile: place.log, encoding: .utf8)) ?? "(no log)" }

    /// The scratch job booted out and every process the test loaded ended.
    func tearDown() {
        guard !tornDown else { return }
        tornDown = true
        precondition(place.label.hasPrefix("dev.vibeswitcher.node.test-"))
        if let pid = printed()?.pid { loaded.append(pid) }
        _ = launchctl(["bootout", place.target])
        for pid in loaded where kill(pid, 0) == 0 && Platform.Processes.arguments(pid).first.map({ $0.hasPrefix(dir) || $0 == "/bin/sleep" }) == true {
            kill(pid, SIGKILL)
        }
    }

    deinit { tearDown() }
}
