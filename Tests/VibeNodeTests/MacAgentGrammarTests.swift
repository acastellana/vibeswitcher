import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost
@testable import VibeNode

/// launchd's word read by one grammar (the node on the Mac's design, "The re-check's round"): `launchctl print`'s whole
/// output placed line by line against the job start wrote, or refused. Function level on fixtures cut from this Mac's
/// captures (`PrintFixtures`), and on this Mac's real launchd with scratch labels (every job booted out).
@Suite(.serialized)
struct MacAgentGrammarTests {
    let scratch = Scratch()

    /// A scratch place and a job of the node's shape for the fixtures (nothing is loaded).
    func stand() throws -> (NodeAgent.Place, NodeAgent.Job, String) {
        let dir = try scratch.shortFolder("vsgr").path
        let place = NodeAgent.Place(label: "dev.vibeswitcher.node.test-gr", plistFolder: dir + "/la", dataRoot: dir + "/node",
                                    lock: dir + "/node/host.lock", uid: getuid(), launchctl: "/bin/launchctl")
        let job = NodeAgent.Job(label: place.label, programArguments: [dir + "/b/bin/vibeswitcher-host", "--socket", dir + "/node/host.sock", "--lock", dir + "/node/h.lock"],
                                environment: ["SWIFT_BACKTRACE": "enable=no", "HOME": dir + "/home"], standardErrorPath: place.log, atLogin: false)
        try FileManager.default.createDirectory(atPath: place.plistFolder, withIntermediateDirectories: true)
        return (place, job, MacAgent.canonicalPlistPath(place))
    }

    func placed(_ text: String, _ job: NodeAgent.Job, _ path: String) -> Result<NodeAgent.Printed, NodeAgent.Unplaced> {
        NodeAgent.placed(Data(text.utf8), job: job, plistPath: path, uid: getuid())
    }

    /// The fixtures of each state, the job's values put in, are placed, with what they say. Red before: the seam took
    /// every text (so the refusals below passed it too).
    @Test func thisMacsPrintIsPlacedInEachState() throws {
        let (place, job, path) = try stand()
        let running = try placed(MacAgentTests.printed(job, place: place, pid: 4242), job, path).get()
        #expect(running.pid == 4242 && running.state == "running" && running.lastExit == nil)
        let loaded = try placed(MacAgentTests.printed(job, place: place, pid: nil), job, path).get()
        #expect(loaded.pid == nil && loaded.state == "not running" && loaded.runs == 0)
        let killed = try placed(MacAgentTests.printed(job, place: place, pid: nil, fixture: PrintFixtures.killed), job, path).get()
        #expect(killed.pid == nil && killed.lastExit == "signal Killed: 9" && killed.runs == 1)
        // The checked start's own refusal (exit 78) prints with its name (measured: `78: EX_CONFIG`); 1 bare.
        for line in ["last exit code = 78: EX_CONFIG", "last exit code = 1", "last terminating signal = Terminated: 15"] {
            let text = MacAgentTests.printed(job, place: place, pid: nil, fixture: PrintFixtures.killed)
                .replacingOccurrences(of: "last terminating signal = Killed: 9", with: line)
            #expect((try? placed(text, job, path).get()) != nil, "\(line) refused")
        }
        var atLogin = job
        atLogin.atLogin = true
        #expect((try? placed(MacAgentTests.printed(atLogin, place: place, pid: 4242), atLogin, path).get()) != nil)
        // The plain job's print isn't the at-login job's (properties, immediate reason), nor the other way round.
        #expect((try? placed(MacAgentTests.printed(job, place: place, pid: 4242), atLogin, path).get()) == nil)
    }

    /// Every line the grammar can't place refuses: a value carrying lines (`path`, a second environment block), a line
    /// launchd prints for a key the job doesn't have (the reviewer's list), `keepalive`, an extra variable, a line after
    /// the closing `}`, a carriage return, a byte above 0x7E, an unknown state, another path. Red before: each was taken.
    @Test func everyLineTheGrammarCantPlaceRefuses() throws {
        let (place, job, path) = try stand()
        let good = MacAgentTests.printed(job, place: place, pid: 4242)
        func with(_ change: (String) -> String) -> String { change(good) }
        func insert(_ lines: String, before anchor: String) -> String {
            with { $0.replacingOccurrences(of: anchor, with: lines + anchor) }
        }
        let variants: [(String, String)] = [
            ("a value that prints a path line", with { $0.replacingOccurrences(of: "\t\tSWIFT_BACKTRACE => enable=no\n",
                with: "\t\tSWIFT_BACKTRACE => enable=no\n\t}\n\tpath = \(path)\n\tenvironment = {\n\t\tX => y\n") }),
            ("a second path line", insert("\tpath = \(path)\n", before: "\ttype = LaunchAgent")),
            ("inherited environment carrying lines", with { $0.replacingOccurrences(of: "Listeners\n", with: "Listeners\n\t}\n\tpath = \(path)\n\tinherited environment = {\n") }),
            ("nice", insert("\tnice = 5\n", before: "\tspawn type")),
            ("umask", insert("\tumask = 0\n", before: "\tspawn type")),
            ("working directory", insert("\tworking directory = /tmp\n", before: "\tinherited environment")),
            ("stdin path", insert("\tstdin path = /dev/null\n", before: "\tstdout path")),
            ("run interval", insert("\trun interval = 3600 seconds\n", before: "\tspawn type")),
            ("resource limits", insert("\tresource limits = {\n\t\tcore (soft) => 1000\n\t}\n\n", before: "\tspawn type")),
            ("semaphores", insert("\tsemaphores = {\n\t\tsuccessful exit => 0\n\t}\n\n", before: "\tresource coalition")),
            ("event triggers", insert("\tevent triggers = {\n\t}\n\n", before: "\tspawn type")),
            ("endpoints", insert("\tendpoints = {\n\t}\n\n", before: "\tspawn type")),
            ("minimum runtime", with { $0.replacingOccurrences(of: "minimum runtime = 10", with: "minimum runtime = 37") }),
            ("exit timeout", with { $0.replacingOccurrences(of: "exit timeout = 5", with: "exit timeout = 9") }),
            ("spawn type", with { $0.replacingOccurrences(of: "interactive (4)", with: "daemon (3)") }),
            ("keepalive", with { $0.replacingOccurrences(of: "\tproperties = inferred program", with: "\tproperties = keepalive | inferred program") }),
            ("an extra variable", with { $0.replacingOccurrences(of: "\t\tOSLogRateLimit => 64\n", with: "\t\tOSLogRateLimit => 64\n\t\tPLANTED => yes\n") }),
            ("a variable changed", with { $0.replacingOccurrences(of: "enable=no", with: "enable=yes") }),
            ("a line after the closing line", good + "\tpath = \(path)\n"),
            ("a carriage return", with { $0.replacingOccurrences(of: "\ttype = LaunchAgent", with: "\ttype = LaunchAgent\r") }),
            ("a byte above 0x7E", with { $0.replacingOccurrences(of: "\tcpumon = default", with: "\tcpumon = défault") }),
            ("an unknown state", with { $0.replacingOccurrences(of: "\tstate = running", with: "\tstate = spawn scheduled") }),
            ("another plist", with { $0.replacingOccurrences(of: "\tpath = \(path)", with: "\tpath = \(path).other") }),
            ("another program", with { $0.replacingOccurrences(of: "\tprogram = ", with: "\tprogram = /x") }),
            ("the arguments' order", with { $0.replacingOccurrences(of: "\t\t--socket\n", with: "") }),
        ]
        for (what, text) in variants {
            #expect(text != good, "\(what): the variant is the good text")
            if case .success = placed(text, job, path) { Issue.record("\(what): placed") }
        }
    }

    /// The job refuses to be written with anything but printable ASCII in a string (a newline in a variable, a control
    /// character in an argument, a non-ASCII home). Red before: written.
    @Test func aJobWithAControlCharacterOrANonASCIIByteIsNotWritten() throws {
        let (place, job, _) = try stand()
        var newline = job
        newline.environment["SWIFT_BACKTRACE"] = "enable=no\n\tpath = /x"
        #expect((try? NodeAgent.plist(newline).get()) == nil)
        var control = job
        control.programArguments.append("a\u{7}b")
        #expect((try? NodeAgent.plist(control).get()) == nil)
        #expect((try? NodeAgent.Job.node(prefix: "/Users/ü/.vibeswitcher/v2/builds", commit: String(repeating: "a", count: 40), home: "/Users/ü",
                                         dataRoot: "/Users/ü/.vibeswitcher/v2/node", atLogin: false).get()) == nil)
        #expect((try? NodeAgent.plist(job).get()) != nil)
        _ = place
    }

    // MARK: This Mac's launchd

    /// The canary for a newer macOS: the scratch host's real job, printed by this Mac's launchd, is placed in every
    /// state it goes through: running after start, killed, and loaded not run. (On a release that prints otherwise this
    /// fails, and so does start: the intended failure.)
    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's launchd"))
    func thisMacsLaunchdPrintsTheJobAsTheGrammarSays() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        _ = try await offPool { agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }.get()
        let path = MacAgent.canonicalPlistPath(agent.place)
        func place() -> Result<NodeAgent.Printed, NodeAgent.Unplaced> {
            NodeAgent.placed(Data((agent.launchctl(["print", agent.place.target])?.output ?? "").utf8), job: agent.job, plistPath: path, uid: getuid())
        }
        let running = try place().get()
        let pid = try #require(running.pid)
        agent.loaded.append(pid)
        #expect(kill(pid, SIGKILL) == 0)
        #expect(await eventually { agent.printed()?.state == "not running" })
        let killed = try place().get()
        #expect(killed.pid == nil && killed.lastExit?.contains("signal") == true)
        #expect(agent.launchctl(["bootout", agent.place.target])?.status == 0)
        #expect(agent.launchctl(["bootstrap", agent.place.domain, agent.place.plistPath])?.status == 0)
        let loaded = try place().get()
        #expect(loaded.pid == nil && loaded.runs == 0)
    }

    /// Notes 1 and 2: one real job per `launchd.plist` key this Mac's `print` shows (measured), each loaded from a
    /// scratch plist under the scratch label, is refused by the grammar; the keys it shows nothing of are placed (the
    /// design's table of what can't be bound).
    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's launchd"))
    func everyKeyPrintShowsIsRefusedAndTheUnshownArePlaced() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        let shown: [(String, Any)] = [("Nice", 5), ("ThrottleInterval", 37), ("ExitTimeOut", 9), ("SoftResourceLimits", ["Core": 1000]),
                                      ("HardResourceLimits", ["Core": 1000]), ("Umask", 0), ("WorkingDirectory", agent.dir), ("StandardInPath", "/dev/null"),
                                      ("StartInterval", 3600), ("StartCalendarInterval", ["Hour": 3]), ("WatchPaths", [agent.dir + "/watched"]),
                                      ("QueueDirectories", [agent.dir + "/queue"]), ("MachServices", [agent.place.label + ".mach": true]),
                                      ("ProcessType", "Standard"), ("AbandonProcessGroup", true), ("EnableTransactions", true), ("LaunchOnlyOnce", true),
                                      ("LowPriorityIO", true), ("SessionCreate", true), ("WaitForDebugger", true), ("UnknownKeyOfTheTest", "x")]
        let unshown: [(String, Any)] = [("AssociatedBundleIdentifiers", ["dev.vibeswitcher.x"]), ("Debug", true), ("Disabled", false),
                                        ("InitGroups", true), ("LimitLoadToSessionType", ["Aqua", "Background"]), ("POSIXSpawnType", "Interactive")]
        func printOf(_ key: String, _ value: Any) throws -> Result<NodeAgent.Printed, NodeAgent.Unplaced> {
            var values = NodeAgent.dictionary(agent.job)
            values[key] = value
            let folder = agent.dir + "/keys-\(key)"
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            let file = folder + "/\(agent.place.label).plist"
            try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: URL(fileURLWithPath: file))
            try #require(agent.launchctl(["bootstrap", agent.place.domain, file])?.status == 0, "\(key): not loaded")
            defer { _ = agent.launchctl(["bootout", agent.place.target]); _ = await_unloaded(agent) }
            agent.printed()?.pid.map { agent.loaded.append($0) }
            let output = agent.launchctl(["print", agent.place.target])?.output ?? ""
            var place = agent.place
            place.plistFolder = folder
            return NodeAgent.placed(Data(output.utf8), job: agent.job, plistPath: MacAgent.canonicalPlistPath(place), uid: getuid())
        }
        for (key, value) in shown {
            if case .success = try printOf(key, value) { Issue.record("\(key): placed though print shows it") }
        }
        for (key, value) in unshown {
            if case .failure(let why) = try printOf(key, value) { Issue.record("\(key): refused (\(why.description)), measured as printing nothing") }
        }
    }

    /// A loaded job of the label from the earlier installer's plist (with `HOME` and `PATH`) at the agent's path:
    /// start and stop refuse it, leave it loaded, and say what to do. Red before: the refusal gave no way forward.
    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's launchd"))
    func aLoadedJobFromTheEarlierInstallerIsToldWhatToDo() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        var values = NodeAgent.dictionary(agent.job)
        values["EnvironmentVariables"] = agent.job.environment.merging(["HOME": agent.dir + "/home", "PATH": "/usr/bin:/bin:/x/swift/bin"]) { $1 }
        try FileManager.default.createDirectory(atPath: agent.place.plistFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: URL(fileURLWithPath: agent.place.plistPath))
        #expect(agent.launchctl(["bootstrap", agent.place.domain, agent.place.plistPath])?.status == 0)
        for (what, result) in [("start", await offPool { agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }),
                               ("stop", await offPool { agent.agent.stop() })] {
            guard case .failure(let why) = result else { Issue.record("\(what) took it"); continue }
            #expect(why.text.contains("launchctl bootout \(agent.place.target)") && why.text.contains("vibeswitcher start"), "\(what): \(why.text)")
        }
        #expect(agent.printed() != nil, "it wasn't left loaded")
    }

    // MARK: Notes 6 and 7

    /// Note 6: only no listener at all is "no server"; a listener that fails the server check, or a hello that is
    /// garbage or late, stops nothing. Red before: each was "no server".
    @Test func onlyNoListenerIsNoServer() {
        #expect(MacAgent.serverSeen(.noListener("nothing listens")) == .none("nothing listens"))
        guard case .refused = MacAgent.serverSeen(.notTheServer("pid 9 isn't the node's server")) else { Issue.record("a failed check was no server"); return }
        guard case .refused = MacAgent.serverSeen(.noHello("no hello in 15 s")) else { Issue.record("a bad hello was no server"); return }
    }

    /// Note 7: a bootout that doesn't unload is said as failed, never as "the job was unloaded" (start's kickstart
    /// refused, the job staying loaded). Red before: "the job was unloaded".
    @Test func aBootoutThatFailsIsSaidAsFailed() throws {
        let stand = MacAgentTests.Stand(try scratch.shortFolder("vsb7").path)
        let log = MacAgentTests.Recorder()
        var steps = stand.agent(log: log, printed: { log.calls.contains { $0.first == "bootstrap" } ? MacAgentTests.printed(stand.job, place: stand.place, pid: nil) : nil }).steps
        let real = steps.launchctl
        steps.launchctl = { words in words.first == "kickstart" ? MacAgent.Ran(status: 1, output: "") : real(words) }
        let started = MacAgent(place: stand.place, steps: steps).start(stand.job, build: stand.row, folder: "/x")
        guard case .failure(let why) = started else { Issue.record("started"); return }
        #expect(!why.text.contains("was unloaded") && why.text.contains("couldn't be unloaded"), "\(why.text)")
    }
}
