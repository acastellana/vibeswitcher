import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost
@testable import VibeNode

/// The review's round (2026-11-26): the independent reviewer's tests of step 5, taken over as the builder's, and the
/// round's own (the node on the Mac's design, "The review's round"). Every job a scratch label (`ScratchAgent`), every
/// file in a Scratch, every load booted out by `tearDown` failing or not.
@Suite(.serialized, .enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's launchd"))
struct MacAgentRoundTests {
    let scratch = Scratch()

    // MARK: Plists on disk

    /// Each planted plist is refused before any load and left byte for byte as it was.
    @Test func plantedPlistsAreRefusedBeforeAnyLoad() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        let made = try NodeAgent.plist(agent.job).get()
        let values = NodeAgent.dictionary(agent.job)
        func with(_ change: (inout [String: Any]) -> Void) throws -> Data {
            var copy = values
            change(&copy)
            return try PropertyListSerialization.data(fromPropertyList: copy, format: .xml, options: 0)
        }
        var variants: [(String, Data)] = [
            ("one byte (a trailing space)", made + Data(" ".utf8)),
            ("one byte changed in the label", Data(String(decoding: made, as: UTF8.self).replacingOccurrences(of: agent.place.label, with: agent.place.label.dropLast() + "X").utf8)),
            ("key order", Self.xml(values.sorted { $0.key > $1.key })),
            ("binary format", try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)),
            ("an integer for KeepAlive", Data(String(decoding: made, as: UTF8.self).replacingOccurrences(of: "<key>KeepAlive</key>\n\t<false/>", with: "<key>KeepAlive</key>\n\t<integer>0</integer>").utf8)),
            ("EnvironmentVariables + DYLD_INSERT_LIBRARIES", try with { $0["EnvironmentVariables"] = agent.job.environment.merging(["DYLD_INSERT_LIBRARIES": "/x.dylib"]) { $1 } }),
            ("ProgramArguments + one word", try with { $0["ProgramArguments"] = agent.job.programArguments + ["--verbose"] }),
            ("WatchPaths", try with { $0["WatchPaths"] = [agent.dir] }),
            ("Program beside ProgramArguments", try with { $0["Program"] = agent.job.programArguments[0] }),
        ]
        #expect(made != variants[2].1, "the key-order variant is the same bytes")
        variants = variants.filter { $0.1 != made }
        try FileManager.default.createDirectory(atPath: agent.place.plistFolder, withIntermediateDirectories: true)
        for (what, planted) in variants {
            try planted.write(to: URL(fileURLWithPath: agent.place.plistPath))
            let started = await offPool { agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }
            if case .success(let said) = started { Issue.record("\(what): started (\(said))") }
            #expect(agent.printed() == nil, "\(what): a job was loaded")
            #expect((try? Data(contentsOf: URL(fileURLWithPath: agent.place.plistPath))) == planted, "\(what): the file changed")
            #expect(agent.scratchProcesses().isEmpty, "\(what): \(agent.scratchProcesses())")
            try FileManager.default.removeItem(atPath: agent.place.plistPath)
        }
        // A link in place of the file, to a file of exactly start's bytes.
        let target = agent.dir + "/elsewhere.plist"
        try made.write(to: URL(fileURLWithPath: target))
        try FileManager.default.createSymbolicLink(atPath: agent.place.plistPath, withDestinationPath: target)
        let linked = await offPool { agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }
        if case .success = linked { Issue.record("a link was started") }
        #expect(agent.printed() == nil, "a link: a job was loaded")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: agent.place.plistPath)) == target && (try? Data(contentsOf: URL(fileURLWithPath: target))) == made)
    }

    /// A plist folder that is a link to another folder: is it refused? (The design says nothing of the folder.)
    @Test func aPlistFolderThatIsALink() async throws {
        let base = try ScratchAgent(scratch)
        defer { base.tearDown() }
        let real = base.dir + "/RealAgents"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: base.place.plistFolder, withDestinationPath: real)
        let started = await offPool { base.agent.start(base.job, build: base.build, folder: base.folder) }
        if let pid = base.printed()?.pid { base.loaded.append(pid) }
        print("ROUND plist folder a link: start \(started); written through the link: \(FileManager.default.fileExists(atPath: real + "/\(base.place.label).plist"))")
        #expect((try? started.get()) == nil, "a plist folder that is a link was taken")
        _ = await offPool { base.agent.stop() }
    }

    /// A plist of exactly start's bytes but group and world writable (0666): is it refused, by start or by launchd?
    @Test func aWritablePlistOfStartsBytes() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        try FileManager.default.createDirectory(atPath: agent.place.plistFolder, withIntermediateDirectories: true)
        try NodeAgent.plist(agent.job).get().write(to: URL(fileURLWithPath: agent.place.plistPath))
        chmod(agent.place.plistPath, 0o666)
        let started = await offPool { agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }
        if let pid = agent.printed()?.pid { agent.loaded.append(pid) }
        print("ROUND plist 0666: start \(started)")
        #expect((try? started.get()) == nil, "a world-writable plist was loaded")
        _ = await offPool { agent.agent.stop() }
    }

    // MARK: A file swapped between start's read-back and the bootstrap

    /// `launchctl bootstrap` wrapped: the plist renamed over by `swapped` just before launchd reads it. What start says,
    /// what launchd loaded, and whether anything is left.
    func swapAtBootstrap(_ what: String, _ change: (NodeAgent.Job, inout [String: Any]) -> Void, patience: TimeInterval = 20) async throws -> (Result<String, StartRefusal>, loadedAfter: Bool) {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        var values = NodeAgent.dictionary(agent.job)
        change(agent.job, &values)
        let swapped = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        let aside = agent.dir + "/swap.plist"
        try swapped.write(to: URL(fileURLWithPath: aside))
        var steps = agent.agent.steps
        let real = steps.launchctl
        let path = agent.place.plistPath
        steps.launchctl = { words in
            if words.first == "bootstrap" { rename(aside, path) }
            return real(words)
        }
        steps.patience = patience
        let swappedAgent = MacAgent(place: agent.place, steps: steps)
        let started = await offPool { swappedAgent.start(agent.job, build: agent.build, folder: agent.folder) }
        let printed = agent.printed()
        if let pid = printed?.pid { agent.loaded.append(pid) }
        print("ROUND swap at bootstrap, \(what): start \(started); loaded after: \(printed.map { "\($0)" } ?? "none")")
        return (started, printed != nil)
    }

    @Test func aSwapToKeepAliveTrue() async throws {
        let (started, loaded) = try await swapAtBootstrap("KeepAlive true") { _, values in values["KeepAlive"] = true }
        #expect((try? started.get()) == nil, "a job loaded from a swapped plist (KeepAlive true) was taken for the node")
        #expect(!loaded || (try? started.get()) != nil)
    }

    @Test func aSwapToAnExtraVariable() async throws {
        let (started, loaded) = try await swapAtBootstrap("an extra variable") { job, values in
            values["EnvironmentVariables"] = job.environment.merging(["PLANTED_IN_PLIST": "yes"]) { $1 }
        }
        #expect((try? started.get()) == nil, "a job loaded from a swapped plist (an extra variable) was taken for the node")
        #expect(!loaded || (try? started.get()) != nil)
    }

    @Test func aSwapToOtherArguments() async throws {
        let (started, loaded) = try await swapAtBootstrap("other arguments") { job, values in
            values["ProgramArguments"] = job.programArguments.map { $0 == "600" ? "601" : $0 }
        }
        #expect((try? started.get()) == nil, "the pinned host with other arguments was taken")
        #expect(!loaded, "a refused start left its job loaded")
    }

    @Test func aSwapToAnotherProgram() async throws {
        let (started, loaded) = try await swapAtBootstrap("Program /bin/sleep", { job, values in
            values["Program"] = "/bin/sleep"
            values["ProgramArguments"] = [job.programArguments[0], "600"]
        }, patience: 6)
        #expect((try? started.get()) == nil, "another program was taken")
        #expect(!loaded, "a refused start left its job loaded")
    }

    // MARK: Jobs of the label already there

    /// A job of the label loaded from another file and not running: start and stop refuse it and leave it loaded.
    @Test func aStoppedForeignJobIsLeftLoaded() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        let other = try agent.foreign(["Label": agent.place.label, "ProgramArguments": ["/bin/sleep", "600"], "RunAtLoad": false, "KeepAlive": false])
        #expect(agent.printed()?.state == "not running")
        if case .success = await offPool({ agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }) { Issue.record("started over it") }
        if case .success = await offPool({ agent.agent.stop() }) { Issue.record("stopped it") }
        #expect(agent.printed()?.path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == URL(fileURLWithPath: other).resolvingSymlinksInPath().path, "\(String(describing: agent.printed()))")
        #expect(!FileManager.default.fileExists(atPath: agent.place.plistPath))
    }

    /// The pinned host's exact command line run by a job of the label loaded from another file (KeepAlive true, an extra
    /// variable): does start take it as "runs already", and status as "runs"?
    @Test func thePinnedHostFromAnotherPlist() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        var values = NodeAgent.dictionary(agent.job)
        values["KeepAlive"] = true
        values["RunAtLoad"] = true
        values["EnvironmentVariables"] = agent.job.environment.merging(["PLANTED_IN_PLIST": "yes"]) { $1 }
        _ = try agent.foreign(values)
        #expect(await eventually { agent.hostAnswers() }, "\(agent.log)")
        if let pid = agent.printed()?.pid { agent.loaded.append(pid) }
        let started = await offPool { agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }
        let status = await offPool { agent.agent.status() }
        print("ROUND pinned host from another plist: start \(started); status \(status)")
        #expect((try? started.get()) == nil, "start took a job from another plist (KeepAlive true) as the node running already")
        #expect((try? status.get()) == nil, "status said a job from another plist runs")
        let pid = agent.printed()?.pid
        let stopped = await offPool { agent.agent.stop() }
        print("ROUND pinned host from another plist: stop \(stopped); still loaded: \(agent.printed() != nil); pid alive: \(pid.map { kill($0, 0) == 0 } ?? false)")
        #expect((try? stopped.get()) == nil, "stop ended a job from another plist")
        #expect(agent.printed() != nil, "stop unloaded a job it didn't start")
    }

    /// A byte copy of the pinned host at another path (`Program`), its argv the job's exactly: taken as the node?
    @Test func aCopyOfThePinnedHostFromAnotherPath() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        let copy = agent.dir + "/copy/vibeswitcher-host"
        try FileManager.default.createDirectory(atPath: agent.dir + "/copy", withIntermediateDirectories: true)
        try ScratchAgent.run("/bin/cp", [agent.job.programArguments[0], copy])
        #expect(Platform.CodeIdentity.cdhash(atPath: copy) == agent.build.host)
        var values = NodeAgent.dictionary(agent.job)
        values["Program"] = copy
        values["RunAtLoad"] = true
        _ = try agent.foreign(values)
        #expect(await eventually { agent.hostAnswers() }, "\(agent.log)")
        let pid = try #require(agent.printed()?.pid)
        agent.loaded.append(pid)
        #expect(Platform.Processes.executable(pid) == copy || Platform.Processes.executable(pid).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == URL(fileURLWithPath: copy).resolvingSymlinksInPath().path)
        let started = await offPool { agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }
        let status = await offPool { agent.agent.status() }
        print("ROUND copy from another path: start \(started); status \(status); argv \(Platform.Processes.arguments(pid))")
        #expect((try? status.get()) == nil, "a copy at another path passed as the node")
    }

    /// The pinned host with other arguments (a job from another plist): start, status and stop refuse it and it runs on.
    @Test func thePinnedHostWithOtherArgumentsIsLeftAlone() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        var values = NodeAgent.dictionary(agent.job)
        values["ProgramArguments"] = agent.job.programArguments.map { $0 == "600" ? "601" : $0 }
        values["RunAtLoad"] = true
        _ = try agent.foreign(values)
        #expect(await eventually { agent.hostAnswers() }, "\(agent.log)")
        let pid = try #require(agent.printed()?.pid)
        agent.loaded.append(pid)
        if case .success = await offPool({ agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }) { Issue.record("start took it") }
        if case .success = await offPool({ agent.agent.status() }) { Issue.record("status took it") }
        if case .success = await offPool({ agent.agent.stop() }) { Issue.record("stop took it") }
        #expect(agent.printed()?.pid == pid && kill(pid, 0) == 0, "it wasn't left alone")
    }

    // MARK: Recognising the host

    /// launchd's text names the pinned host and its exact arguments (the job's plist is start's own arguments), but the
    /// file at that path was a perl listener when launchd exec'd it (put back after): status, start and stop refuse it.
    @Test func launchctlsTextNamingTheHostIsNotTheHost() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        let host = agent.job.programArguments[0], aside = agent.dir + "/host.aside", ready = agent.dir + "/perl.ready"
        rename(host, aside)
        let source = agent.dir + "/perl.txt"
        try ("#!/usr/bin/perl\nuse IO::Socket::UNIX; my %a = @ARGV; unlink $a{'--socket'}; my $s = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => $a{'--socket'}, Listen => 5) or die; open(my $f, '>', '\(ready)'); close($f); while (my $c = $s->accept) { sleep 30 }\n").write(toFile: source, atomically: true, encoding: .utf8)
        try ScratchAgent.run("/bin/cp", [source, host])
        chmod(host, 0o755)
        var values = NodeAgent.dictionary(agent.job)
        values["RunAtLoad"] = true
        _ = try agent.foreign(values)
        #expect(await eventually { FileManager.default.fileExists(atPath: ready) }, "\(agent.log)")
        unlink(host)
        rename(aside, host)
        #expect(Platform.CodeIdentity.cdhash(atPath: host) == agent.build.host)
        let pid = try #require(agent.printed()?.pid)
        agent.loaded.append(pid)
        #expect(agent.printed()?.program == host, "\(String(describing: agent.printed()))")
        let status = await offPool { agent.agent.status() }
        print("ROUND perl under the host's name: status \(status)")
        if case .success = status { Issue.record("status took perl for the host") }
        if case .success = await offPool({ agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }) { Issue.record("start took it") }
        if case .success = await offPool({ agent.agent.stop() }) { Issue.record("stop took it") }
        #expect(agent.printed()?.pid == pid && kill(pid, 0) == 0)
    }

    /// The pinned host's code at the socket, started by the test (not by launchd under the label): status says not
    /// running; with a job of the label running sleep, status refuses it; start refuses and loads nothing.
    @Test func thePinnedCodeNotStartedByTheJob() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        var spawn = Platform.Spawn(executable: agent.job.programArguments[0], arguments: agent.job.programArguments)
        spawn.environment = agent.job.environment.map { "\($0.key)=\($0.value)" }
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.group = .ownGroup
        guard case .success(let impostor) = spawn.start() else { Issue.record("no impostor"); return }
        defer { kill(impostor, SIGKILL); var status: Int32 = 0; waitpid(impostor, &status, 0) }
        #expect(await eventually { agent.hostAnswers() })
        guard case .failure(let notLoaded) = await offPool({ agent.agent.status() }) else { Issue.record("status said it runs"); return }
        #expect(notLoaded.exitCode == 69)
        _ = try agent.foreign(["Label": agent.place.label, "ProgramArguments": ["/bin/sleep", "600"], "RunAtLoad": true, "KeepAlive": false])
        #expect(await eventually { agent.printed()?.pid != nil })
        agent.printed()?.pid.map { agent.loaded.append($0) }
        if case .success = await offPool({ agent.agent.status() }) { Issue.record("status took a host not the job's") }
        _ = agent.launchctl(["bootout", agent.place.target])
        #expect(await eventually { agent.printed() == nil })
        let started = await offPool { agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }
        print("ROUND pinned code not the job's: start \(started)")
        if case .success = started { Issue.record("start took a host it didn't start") }
        #expect(agent.printed() == nil, "a refused start left its job")
        #expect(kill(impostor, 0) == 0, "the impostor wasn't left alone")
    }

    /// Something listening at the socket's path before the job's host binds it: what start gets.
    @Test func aListenerAtTheSocketBeforeTheHost() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        let ready = agent.dir + "/l.ready"
        let listen = "use IO::Socket::UNIX; my $s = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => $ARGV[0], Listen => 5) or die; open(my $f, '>', $ARGV[1]); close($f); while (my $c = $s->accept) { sleep 30 }"
        var spawn = Platform.Spawn(executable: "/usr/bin/perl", arguments: ["perl", "-e", listen, agent.place.socket, ready])
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        guard case .success(let listener) = spawn.start() else { Issue.record("no listener"); return }
        defer { kill(listener, SIGKILL); var status: Int32 = 0; waitpid(listener, &status, 0) }
        #expect(await eventually { FileManager.default.fileExists(atPath: ready) })
        let started = await offPool { agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }
        print("ROUND listener before the host: start \(started)")
        if case .success = started, let pid = agent.printed()?.pid {
            agent.loaded.append(pid)
            // Whatever start said runs must be the job's own host at the socket now.
            guard case .host(let seen) = MacAgent.see(socket: agent.place.socket, pid: pid, builds: [agent.build]) else { Issue.record("start said runs, the socket says otherwise"); return }
            #expect(seen.pid == pid)
            _ = await offPool { agent.agent.stop() }
        } else {
            #expect(agent.printed() == nil, "a refused start left its job")
        }
    }

    // MARK: stop

    /// stop with no job: 69, and nothing touched; with a job of start's own plist loaded and not running: unloaded.
    @Test func stopWithNoJobAndWithAStoppedOwnJob() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        guard case .failure(let none) = await offPool({ agent.agent.stop() }) else { Issue.record("stopped nothing"); return }
        #expect(none.exitCode == 69)
        try FileManager.default.createDirectory(atPath: agent.place.plistFolder, withIntermediateDirectories: true)
        try NodeAgent.plist(agent.job).get().write(to: URL(fileURLWithPath: agent.place.plistPath))
        #expect(agent.launchctl(["bootstrap", agent.place.domain, agent.place.plistPath])?.status == 0)
        #expect(agent.printed()?.state == "not running")
        let stopped = await offPool { agent.agent.stop() }
        #expect((try? stopped.get()) != nil, "\(stopped)")
        #expect(agent.printed() == nil && agent.scratchProcesses().isEmpty)
    }

    /// stop's wait with real processes (launchd's bootout stood in for by ending the job's process group, as measured):
    /// a child in its own session that ignores SIGTERM and SIGHUP survives; stop names it and fails, and doesn't kill it.
    @Test func stopNamesAChildInItsOwnSessionThatIgnoresTheSignals() async throws {
        let dir = try scratch.shortFolder("vsrv").path
        let ready = dir + "/child.pid"
        let script = "$SIG{TERM}='IGNORE'; $SIG{HUP}='IGNORE'; my $c = fork; if (!$c) { POSIX::setsid(); open(my $f, '>', '\(ready)'); print $f $$; close($f); sleep 600; exit 0 } sleep 600"
        var spawn = Platform.Spawn(executable: "/usr/bin/perl", arguments: ["perl", "-MPOSIX", "-e", script])
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.group = .ownGroup
        guard case .success(let host) = spawn.start() else { Issue.record("no stand-in host"); return }
        #expect(await eventually { ((try? String(contentsOfFile: ready, encoding: .utf8)).flatMap { pid_t($0) }) != nil })
        let child = try #require((try? String(contentsOfFile: ready, encoding: .utf8)).flatMap { pid_t($0) })
        defer { kill(child, SIGKILL); kill(-host, SIGKILL); var s: Int32 = 0; waitpid(host, &s, 0) }
        let place = NodeAgent.Place(label: "dev.vibeswitcher.node.test-fn", plistFolder: dir + "/la", dataRoot: dir + "/node",
                                    lock: dir + "/node/host.lock", uid: getuid(), launchctl: "/bin/launchctl")
        let gone = Locked(false)
        let real = MacAgent.Steps.system(place: place, pins: { .success(NodePins(uid: getuid(), builds: [])) }, say: { _ in }, confirm: { _ in .success(()) },
                                         serverStop: { _ in .none("no server answers") }, jobArguments: { _ in nil })
        var steps = real
        steps.launchctl = { words in
            switch words.first {
            case "print": return gone.value ? MacAgent.Ran(status: 113, output: "") : MacAgent.Ran(status: 0, output: "x = {\n\tstate = running\n\tpid = \(host)\n}")
            case "bootout":
                // launchd's bootout: SIGTERM to the job's group, then SIGKILL (the stand-in ignores TERM).
                kill(-host, SIGKILL); var s: Int32 = 0; waitpid(host, &s, 0); gone.value = true
                return MacAgent.Ran(status: 0, output: "")
            default: return MacAgent.Ran(status: 0, output: "")
            }
        }
        steps.see = { _, pid, _ in .host(MacAgent.Host(commit: "c", pid: pid, startedAt: nil)) }
        steps.pins = { .success(NodePins(uid: getuid(), builds: [NodePins.Build(commit: "c", host: Data(), server: Data(), cli: Data())])) }
        steps.jobArguments = { _ in Platform.Processes.arguments(host) }
        steps.patience = 3
        let stopped = await offPool { MacAgent(place: place, steps: steps).stop() }
        print("ROUND stop, a child in its own session ignoring the signals: \(stopped)")
        guard case .failure(let why) = stopped else { Issue.record("stop said it stopped with pid \(child) running"); return }
        #expect(why.text.contains("pid \(child)"), "\(why.text)")
        #expect(kill(child, 0) == 0, "stop killed it")
    }

    /// A grandchild in its own session (a session's program's own child that left its session, as a daemon does): the
    /// snapshot is the host and its direct children, so does stop say everything ended while it runs?
    @Test func stopAndAGrandchildInItsOwnSession() async throws {
        let dir = try scratch.shortFolder("vsrg").path
        let ready = dir + "/grandchild.pid"
        // host -> child (the session's program, its group) -> grandchild (setsid, ignores TERM and HUP).
        let script = "my $c = fork; if (!$c) { my $g = fork; if (!$g) { POSIX::setsid(); $SIG{TERM}='IGNORE'; $SIG{HUP}='IGNORE'; open(my $f, '>', '\(ready)'); print $f $$; close($f); sleep 600; exit 0 } sleep 600; exit 0 } sleep 600"
        var spawn = Platform.Spawn(executable: "/usr/bin/perl", arguments: ["perl", "-MPOSIX", "-e", script])
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.group = .ownGroup
        guard case .success(let host) = spawn.start() else { Issue.record("no stand-in host"); return }
        #expect(await eventually { ((try? String(contentsOfFile: ready, encoding: .utf8)).flatMap { pid_t($0) }) != nil })
        let grandchild = try #require((try? String(contentsOfFile: ready, encoding: .utf8)).flatMap { pid_t($0) })
        defer { kill(grandchild, SIGKILL); kill(-host, SIGKILL); var s: Int32 = 0; waitpid(host, &s, 0) }
        let place = NodeAgent.Place(label: "dev.vibeswitcher.node.test-fn", plistFolder: dir + "/la", dataRoot: dir + "/node",
                                    lock: dir + "/node/host.lock", uid: getuid(), launchctl: "/bin/launchctl")
        let gone = Locked(false)
        var steps = MacAgent.Steps.system(place: place, pins: { .success(NodePins(uid: getuid(), builds: [NodePins.Build(commit: "c", host: Data(), server: Data(), cli: Data())])) },
                                          say: { _ in }, confirm: { _ in .success(()) }, serverStop: { _ in .none("no server answers") }, jobArguments: { _ in Platform.Processes.arguments(host) })
        steps.launchctl = { words in
            switch words.first {
            case "print": return gone.value ? MacAgent.Ran(status: 113, output: "") : MacAgent.Ran(status: 0, output: "x = {\n\tstate = running\n\tpid = \(host)\n}")
            case "bootout": kill(-host, SIGKILL); var s: Int32 = 0; waitpid(host, &s, 0); gone.value = true; return MacAgent.Ran(status: 0, output: "")
            default: return MacAgent.Ran(status: 0, output: "")
            }
        }
        steps.see = { _, pid, _ in .host(MacAgent.Host(commit: "c", pid: pid, startedAt: nil)) }
        steps.patience = 3
        let stopped = await offPool { MacAgent(place: place, steps: steps).stop() }
        print("ROUND stop, a grandchild in its own session: \(stopped); grandchild alive: \(kill(grandchild, 0) == 0)")
        #expect((try? stopped.get()) == nil || kill(grandchild, 0) != 0, "stop said everything ended while pid \(grandchild) runs")
    }

    /// The stale socket file: removed after stop only when the lock is free; a regular file there never.
    @Test func theStaleSocketIsRemovedOnlyWhenTheLockIsFree() async throws {
        let dir = try scratch.shortFolder("vsrs").path
        try FileManager.default.createDirectory(atPath: dir + "/node", withIntermediateDirectories: true)
        let place = NodeAgent.Place(label: "dev.vibeswitcher.node.test-fn", plistFolder: dir + "/la", dataRoot: dir + "/node",
                                    lock: dir + "/node/host.lock", uid: getuid(), launchctl: "/bin/launchctl")
        func stale() throws { let fd = try UnixSocket.listen(path: place.socket); Sys.close(fd) }
        func run(lockFree: Bool) async -> Result<String, StartRefusal> {
            let gone = Locked(false)
            var steps = MacAgent.Steps.system(place: place, pins: { .success(NodePins(uid: getuid(), builds: [NodePins.Build(commit: "c", host: Data(), server: Data(), cli: Data())])) },
                                              say: { _ in }, confirm: { _ in .success(()) }, serverStop: { _ in .none("no server answers") }, jobArguments: { _ in ["x"] })
            steps.launchctl = { words in
                switch words.first {
                case "print": return gone.value ? MacAgent.Ran(status: 113, output: "") : MacAgent.Ran(status: 0, output: "x = {\n\tstate = running\n\tpid = 999999\n}")
                case "bootout": gone.value = true; return MacAgent.Ran(status: 0, output: "")
                default: return MacAgent.Ran(status: 0, output: "")
                }
            }
            steps.see = { _, pid, _ in .host(MacAgent.Host(commit: "c", pid: pid, startedAt: nil)) }
            steps.arguments = { _ in ["x"] }
            steps.lockFree = { _ in lockFree }
            steps.patience = 2
            return await offPool { MacAgent(place: place, steps: steps).stop() }
        }
        try stale()
        _ = await run(lockFree: false)
        #expect(FileManager.default.fileExists(atPath: place.socket), "removed while the lock was held")
        _ = await run(lockFree: true)
        #expect(!FileManager.default.fileExists(atPath: place.socket), "a stale socket was left with the lock free")
        FileManager.default.createFile(atPath: place.socket, contents: Data("x".utf8))
        _ = await run(lockFree: true)
        #expect(FileManager.default.fileExists(atPath: place.socket), "a regular file was removed")
    }

    // MARK: A crash

    /// The host killed: over launchd's throttle interval (10 s) and more, nothing starts it again and status says it
    /// doesn't run. (A negative over time: a bounded look, not a wait for an event.)
    @Test func aKilledHostStaysDown() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        _ = try await offPool { agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }.get()
        let pid = try #require(agent.printed()?.pid)
        agent.loaded.append(pid)
        #expect(kill(pid, SIGKILL) == 0)
        #expect(await eventually { agent.printed()?.state == "not running" })
        let restarted = await eventually(timeout: 15) { (agent.printed()?.runs ?? 1) > 1 || agent.printed()?.pid != nil }
        #expect(!restarted, "launchd started it again: \(String(describing: agent.printed()))")
        guard case .failure(let why) = await offPool({ agent.agent.status() }) else { Issue.record("status said runs"); return }
        print("ROUND killed host: status \(why.text); print \(String(describing: agent.printed()))")
        #expect(why.exitCode == 69)
        #expect(FileManager.default.fileExists(atPath: agent.place.socket) || true)
        print("ROUND killed host: socket file left: \(FileManager.default.fileExists(atPath: agent.place.socket))")
        let stopped = await offPool { agent.agent.stop() }
        print("ROUND killed host: stop \(stopped); loaded after: \(agent.printed() != nil); socket file after stop: \(FileManager.default.fileExists(atPath: agent.place.socket))")
        #expect((try? stopped.get()) != nil && agent.printed() == nil)
        #expect(!FileManager.default.fileExists(atPath: agent.place.socket), "stop after a crash left the socket's file")
    }

    // MARK: The round's own (I1, I2, N1, N4, N5, the old installer's plist)

    /// `bootstrap` wrapped by `around` (given the agent's plist path and folder, and a plist of start's job changed by
    /// `change`, written aside): what start says and whether a job is left.
    func wrappedBootstrap(_ change: (inout [String: Any]) -> Void,
                          _ around: @escaping (_ path: String, _ folder: String, _ aside: String, _ bootstrap: () -> MacAgent.Ran?) -> MacAgent.Ran?)
        async throws -> (Result<String, StartRefusal>, loadedAfter: Bool) {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        var values = NodeAgent.dictionary(agent.job)
        change(&values)
        let aside = agent.dir + "/changed.plist"
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: URL(fileURLWithPath: aside))
        var steps = agent.agent.steps
        let real = steps.launchctl
        let path = agent.place.plistPath, folder = agent.place.plistFolder
        steps.launchctl = { words in
            guard words.first == "bootstrap" else { return real(words) }
            return around(path, folder, aside) { real(words) }
        }
        steps.patience = 20
        let started = await offPool { MacAgent(place: agent.place, steps: steps).start(agent.job, build: agent.build, folder: agent.folder) }
        let printed = agent.printed()
        if let pid = printed?.pid { agent.loaded.append(pid) }
        print("ROUND wrapped bootstrap: start \(started); loaded after: \(printed.map { "\($0)" } ?? "none")")
        return (started, printed != nil)
    }

    /// I1: start's file renamed away, a changed one (`Nice` 5: a line the agent doesn't compare) put in its place for
    /// launchd's read, then start's file put back: the same inode at the path, its bytes start's, but its ctime moved.
    /// Refused and unloaded. Red before: start took it.
    @Test func aSwapAwayAndBackOfTheFile() async throws {
        let (started, loaded) = try await wrappedBootstrap({ $0["Nice"] = 5 }) { path, _, aside, bootstrap in
            let kept = path + ".kept"
            rename(path, kept)
            rename(aside, path)
            let ran = bootstrap()
            unlink(path)
            rename(kept, path)
            return ran
        }
        #expect((try? started.get()) == nil, "a job loaded from a file swapped away and back was taken")
        #expect(!loaded, "a refused start left its job loaded")
    }

    /// I1: the plist's folder renamed away, another folder holding a changed plist (`Nice` 5) put in its place for
    /// launchd's read, then the folder put back: start's file unchanged, its folder's ctime moved. Refused and unloaded.
    /// Red before: start took it.
    @Test func aSwapAwayAndBackOfTheFolder() async throws {
        let (started, loaded) = try await wrappedBootstrap({ $0["Nice"] = 5 }) { path, folder, aside, bootstrap in
            let kept = folder + ".kept"
            rename(folder, kept)
            mkdir(folder, 0o755)
            rename(aside, path)
            let ran = bootstrap()
            unlink(path)
            rmdir(folder)
            rename(kept, folder)
            return ran
        }
        #expect((try? started.get()) == nil, "a job loaded through a folder swapped away and back was taken")
        #expect(!loaded, "a refused start left its job loaded")
    }

    /// I2 with the agent's own path: a job of the label loaded from other bytes at the agent's plist path (`KeepAlive`
    /// true, `RunAtLoad`), running the pinned host with the job's exact arguments, then start's bytes written back at
    /// the path. launchd's word (`properties = keepalive | …`) says it isn't start's job: start, status and stop refuse
    /// it, and it stays loaded. Red before: start said it runs already.
    @Test func aJobLoadedFromOtherBytesAtTheAgentsOwnPath() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        var values = NodeAgent.dictionary(agent.job)
        values["KeepAlive"] = true
        values["RunAtLoad"] = true
        try FileManager.default.createDirectory(atPath: agent.place.plistFolder, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: URL(fileURLWithPath: agent.place.plistPath))
        #expect(agent.launchctl(["bootstrap", agent.place.domain, agent.place.plistPath])?.status == 0)
        #expect(await eventually { agent.hostAnswers() }, "\(agent.log)")
        let pid = try #require(agent.printed()?.pid)
        agent.loaded.append(pid)
        unlink(agent.place.plistPath)
        try NodeAgent.plist(agent.job).get().write(to: URL(fileURLWithPath: agent.place.plistPath))
        let started = await offPool { agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }
        let status = await offPool { agent.agent.status() }
        let stopped = await offPool { agent.agent.stop() }
        print("ROUND other bytes at the agent's path: start \(started); status \(status); stop \(stopped)")
        #expect((try? started.get()) == nil, "start took a job loaded from other bytes for the node")
        #expect((try? status.get()) == nil, "status took it")
        #expect((try? stopped.get()) == nil, "stop took it")
        #expect(agent.printed()?.pid == pid && kill(pid, 0) == 0, "it wasn't left alone")
    }

    /// N4: a plist folder writable by others is refused before anything is written or loaded.
    @Test func aPlistFolderWritableByOthersIsRefused() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        try FileManager.default.createDirectory(atPath: agent.place.plistFolder, withIntermediateDirectories: true)
        chmod(agent.place.plistFolder, 0o777)
        let started = await offPool { agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }
        guard case .failure(let why) = started else { Issue.record("started in a folder others can write"); return }
        #expect(why.text.contains("writable"), "\(why.text)")
        #expect(agent.printed() == nil && !FileManager.default.fileExists(atPath: agent.place.plistPath))
    }

    /// The nit: a plist of start's bytes that group and others can write is refused by start itself, saying why, before
    /// launchd is asked (which refuses it with nothing to tell). Red before: launchd's bootstrap failure was the message.
    @Test func aWritablePlistIsRefusedByStartSayingWhy() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        try FileManager.default.createDirectory(atPath: agent.place.plistFolder, withIntermediateDirectories: true)
        try NodeAgent.plist(agent.job).get().write(to: URL(fileURLWithPath: agent.place.plistPath))
        chmod(agent.place.plistPath, 0o666)
        let started = await offPool { agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }
        guard case .failure(let why) = started else { Issue.record("started a writable plist"); return }
        #expect(why.text.contains("writable") && !why.text.contains("bootstrap"), "\(why.text)")
        #expect(agent.printed() == nil)
    }

    /// The earlier installer's plist (with `HOME` and `PATH` in its environment) is refused, and the refusal says what
    /// to do. Red before: it said only that the file isn't start's.
    @Test func theEarlierInstallersPlistIsRefusedSayingWhatToDo() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        var values = NodeAgent.dictionary(agent.job)
        values["EnvironmentVariables"] = agent.job.environment.merging(["HOME": agent.dir + "/home", "PATH": "/usr/bin:/bin:/x/swift/bin"]) { $1 }
        try FileManager.default.createDirectory(atPath: agent.place.plistFolder, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: URL(fileURLWithPath: agent.place.plistPath))
        let started = await offPool { agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }
        guard case .failure(let why) = started else { Issue.record("started an earlier installer's plist"); return }
        #expect(why.text.contains("remove") && why.text.contains(agent.place.plistPath), "\(why.text)")
        #expect(agent.printed() == nil)
    }

    /// N1 at function level: a job of the label running at `pid`, and a server that answers (`sessions`) with
    /// `serverStop`'s answer, or none.
    func stopWith(server: MacAgent.ServerStop?) throws -> (Result<String, StartRefusal>, confirms: Int, bootouts: Int, stops: Int) {
        let dir = try scratch.shortFolder("vsn1").path
        let place = NodeAgent.Place(label: "dev.vibeswitcher.node.test-fn", plistFolder: dir + "/la", dataRoot: dir + "/node",
                                    lock: dir + "/node/host.lock", uid: getuid(), launchctl: "/bin/launchctl")
        try FileManager.default.createDirectory(atPath: place.plistFolder, withIntermediateDirectories: true)
        let row = NodePins.Build(commit: String(repeating: "e", count: 40), host: Data(repeating: 1, count: 20), server: Data(repeating: 2, count: 20),
                                 cli: Data(repeating: 3, count: 20))
        let job = NodeAgent.Job(label: place.label, programArguments: ["/bin/sleep"], environment: [:], standardErrorPath: place.log, atLogin: false)
        try NodeAgent.plist(job).get().write(to: URL(fileURLWithPath: place.plistPath))
        let counts = Locked((confirms: 0, bootouts: 0, stops: 0, gone: false))
        let running = "x = {\n\tstate = running\n\tpid = 4242\n\tpath = \(place.plistPath)\n\targuments = {\n\t\t/bin/sleep\n\t}\n\tstderr path = \(place.log)\n\tstdout path = /dev/null\n"
            + "\tenvironment = {\n\t\tOSLogRateLimit => 64\n\t\tXPC_SERVICE_NAME => \(place.label)\n\t}\n\tproperties = inferred program\n}"
        var steps = MacAgent.Steps(launchctl: { words in
                                       switch words.first {
                                       case "print": return counts.value.gone ? MacAgent.Ran(status: 113, output: "") : MacAgent.Ran(status: 0, output: running)
                                       case "bootout": counts.value.bootouts += 1; counts.value.gone = true; return MacAgent.Ran(status: 0, output: "")
                                       default: return MacAgent.Ran(status: 0, output: "")
                                       }
                                   },
                                   pins: { .success(NodePins(uid: getuid(), builds: [row])) }, cdhashOf: { _ in nil },
                                   see: { _, pid, _ in .host(MacAgent.Host(commit: row.commit, pid: pid, startedAt: nil)) }, say: { _ in },
                                   confirm: { _ in counts.value.confirms += 1; return .success(()) },
                                   serverStop: { _ in counts.value.stops += 1; return server ?? .none("no server answers") },
                                   children: { _ in [] }, alive: { _ in false }, lockFree: { _ in true }, patience: 2,
                                   arguments: { _ in ["/bin/sleep"] }, jobArguments: { _ in ["/bin/sleep"] },
                                   liveSessions: { server == nil ? nil : 3 })
        steps.executable = { _ in "/bin/sleep" }
        let stopped = MacAgent(place: place, steps: steps).stop()
        return (stopped, counts.value.confirms, counts.value.bootouts, counts.value.stops)
    }

    /// N1: a server that answers and refuses the stop: stop fails, saying why, asks no typed code of its own and
    /// unloads nothing. Red before: the code was typed, the server's answer dropped and the job booted out.
    @Test func aServerThatRefusesTheStopStopsNothing() throws {
        let (stopped, confirms, bootouts, stops) = try stopWith(server: .refused(StartRefusal("voice: the dialog was cancelled")))
        guard case .failure(let why) = stopped else { Issue.record("stopped over the server's refusal"); return }
        #expect(why.text.contains("the dialog was cancelled"), "\(why.text)")
        #expect(confirms == 0 && bootouts == 0 && stops == 1, "confirms \(confirms), bootouts \(bootouts), stops \(stops)")
    }

    /// N1: a server that takes the stop: asked once (by the server's rule, inside `serverStop`), no typed code of the
    /// agent's own, then the job unloaded. Red before: the code was asked first, then the server again.
    @Test func aServerThatTakesTheStopIsAskedOnce() throws {
        let (stopped, confirms, bootouts, stops) = try stopWith(server: .stopped)
        #expect((try? stopped.get()) != nil, "\(stopped)")
        #expect(confirms == 0 && stops == 1 && bootouts == 1, "confirms \(confirms), bootouts \(bootouts), stops \(stops)")
    }

    /// N1: no server answers: the typed code (what ends said: the bootout, the hangup), then the bootout.
    @Test func withNoServerStopAsksTheCodeAndBootsOut() throws {
        let (stopped, confirms, bootouts, _) = try stopWith(server: nil)
        #expect((try? stopped.get()) != nil, "\(stopped)")
        #expect(confirms == 1 && bootouts == 1, "confirms \(confirms), bootouts \(bootouts)")
    }

    /// N5: `status --json` checks the host on the Mac as the plain `status` does. Red before: JSON skipped it.
    @Test func statusChecksTheHostWithJSONToo() {
        #expect(MacAgent.statusChecksHost(onTheMac: true, isScratch: false, refused: false, json: true))
        #expect(MacAgent.statusChecksHost(onTheMac: true, isScratch: false, refused: false, json: false))
        #expect(!MacAgent.statusChecksHost(onTheMac: true, isScratch: true, refused: false, json: true))
        #expect(!MacAgent.statusChecksHost(onTheMac: true, isScratch: false, refused: true, json: true))
        #expect(!MacAgent.statusChecksHost(onTheMac: false, isScratch: false, refused: false, json: true))
    }

    // MARK: Helpers

    /// A plist in XML with its keys in `pairs`' order (PropertyListSerialization sorts them).
    static func xml(_ pairs: [(key: String, value: Any)]) -> Data {
        func value(_ any: Any) -> String {
            switch any {
            case let bool as Bool: return bool ? "<true/>" : "<false/>"
            case let text as String: return "<string>\(text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;"))</string>"
            case let list as [String]: return "<array>" + list.map(value).joined() + "</array>"
            case let dict as [String: String]: return "<dict>" + dict.sorted { $0.key < $1.key }.map { "<key>\($0.key)</key>" + value($0.value) }.joined() + "</dict>"
            default: return "<string>?</string>"
            }
        }
        let body = pairs.map { "\t<key>\($0.key)</key>\n\t\(value($0.value))\n" }.joined()
        return Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n" + body + "</dict>\n</plist>\n").utf8)
    }
}

extension ScratchAgent {
    /// A job of the scratch label bootstrapped from a plist of `values` outside the agent's folder; its path.
    func foreign(_ values: [String: Any]) throws -> String {
        let path = dir + "/foreign-\(UUID().uuidString.prefix(4)).plist"
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: URL(fileURLWithPath: path))
        let ran = launchctl(["bootstrap", place.domain, path])
        try #require(ran?.status == 0, "bootstrap: \(String(describing: ran))")
        return path
    }

    /// Something takes a connection at the scratch socket.
    func hostAnswers() -> Bool { (try? UnixSocket.connect(path: place.socket)).map { Sys.close($0); return true } ?? false }

    /// The processes whose arguments name the scratch folder.
    func scratchProcesses() -> [String] {
        let ran = NodeStarter.run("/usr/bin/pgrep", ["-f", dir], environment: ["PATH=/usr/bin:/bin"], timeout: 10)
        return (ran?.output ?? "").split(whereSeparator: \.isNewline).map(String.init)
    }
}
