import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost
@testable import VibeNode

/// The re-check of the review's round: the independent reviewer's attacks on the fixes, taken over as the builder's (the
/// node on the Mac's design, "The re-check's round"). Every job a scratch label (`ScratchAgent`), every plist in a
/// Scratch, every load booted out by `tearDown` failing or not. A test whose name starts `limit` asserts what the spec
/// states it can't bind; every other test asserts the property.
@Suite(.serialized, .enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's launchd"))
struct MacAgentRecheckTests {
    let scratch = Scratch()

    /// `start` with `bootstrap` wrapped by `around` (the agent's plist path, its folder, a changed plist written aside),
    /// with the agent's place `place` (default: the scratch agent's own).
    func wrapped(_ agent: ScratchAgent, place: NodeAgent.Place? = nil, _ change: (inout [String: Any]) -> Void,
                 _ around: @escaping (_ path: String, _ folder: String, _ aside: Data, _ bootstrap: () -> MacAgent.Ran?) -> MacAgent.Ran?)
        async throws -> (Result<String, StartRefusal>, loadedAfter: NodeAgent.Printed?) {
        let place = place ?? agent.place
        var values = NodeAgent.dictionary(agent.job)
        change(&values)
        let aside = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        var steps = agent.agent.steps
        let real = steps.launchctl
        steps.launchctl = { words in
            guard words.first == "bootstrap" else { return real(words) }
            return around(place.plistPath, place.plistFolder, aside) { real(words) }
        }
        steps.patience = 20
        let started = await offPool { MacAgent(place: place, steps: steps).start(agent.job, build: agent.build, folder: agent.folder) }
        let printed = agent.printed()
        if let pid = printed?.pid { agent.loaded.append(pid) }
        return (started, printed)
    }

    /// The scratch agent's place with its plist folder one level lower (`<dir>/anc/LaunchAgents`), so `<dir>/anc` is an
    /// ancestor that can be swapped without moving the builds or the data root.
    func lowered(_ agent: ScratchAgent) throws -> NodeAgent.Place {
        let p = agent.place
        let place = NodeAgent.Place(label: p.label, plistFolder: agent.dir + "/anc/LaunchAgents", dataRoot: p.dataRoot, lock: p.lock, uid: p.uid, launchctl: p.launchctl)
        try FileManager.default.createDirectory(atPath: place.plistFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        return place
    }

    // MARK: I1

    /// A hard link to start's plist (made before start), written through with other bytes (`Nice` 5, a key launchd's
    /// print doesn't show) just before the bootstrap and written back after it: the inode at the path the same, its bytes
    /// start's again. Refused (its ctime moved) and unloaded.
    @Test func aHardLinkWrittenThroughAndBack() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        try FileManager.default.createDirectory(atPath: agent.place.plistFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let made = try NodeAgent.plist(agent.job).get()
        try made.write(to: URL(fileURLWithPath: agent.place.plistPath))
        let alias = agent.dir + "/alias.plist"
        #expect(link(agent.place.plistPath, alias) == 0)
        func overwrite(_ data: Data) {
            let fd = open(alias, O_WRONLY | O_TRUNC)
            _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            Sys.close(fd)
        }
        let (started, loaded) = try await wrapped(agent, { $0["Nice"] = 5 }) { _, _, aside, bootstrap in
            overwrite(aside)
            let ran = bootstrap()
            overwrite(made)
            return ran
        }
        print("RECHECK hard link written through and back: \(started)")
        #expect((try? started.get()) == nil, "a job loaded from bytes written through a hard link and back was taken")
        #expect(loaded == nil, "a refused start left its job loaded")
        #expect((try? Data(contentsOf: URL(fileURLWithPath: agent.place.plistPath))) == made)
    }

    /// The file swapped for launchd's read, then start's file renamed back, then a second swap and swap back of an
    /// unrelated name in the folder: refused (the folder's ctime moved), and unloaded.
    @Test func aSwapAndBackWithKeepAliveIsRefusedAndUnloaded() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        let (started, loaded) = try await wrapped(agent, { $0["KeepAlive"] = true }) { path, _, aside, bootstrap in
            rename(path, path + ".kept")
            try? aside.write(to: URL(fileURLWithPath: path))
            let ran = bootstrap()
            unlink(path)
            rename(path + ".kept", path)
            return ran
        }
        print("RECHECK swap and back, KeepAlive: \(started)")
        #expect((try? started.get()) == nil)
        #expect(loaded == nil, "a refused start left a KeepAlive job loaded: \(String(describing: loaded))")
    }

    /// The stated limit: an ancestor of the plist folder swapped away and back around the bootstrap, the plist launchd
    /// read carrying a key `print` doesn't show (`Nice` 5): start says the node runs.
    @Test func limitAnAncestorSwappedAndBackWithAnUnshownKey() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        let place = try lowered(agent)
        let (started, loaded) = try await wrapped(agent, place: place, { $0["Nice"] = 5 }) { path, folder, aside, bootstrap in
            Self.ancestorSwap(folder: folder, path: path, aside: aside, bootstrap)
        }
        print("RECHECK ancestor swapped and back, Nice 5: \(started); loaded \(String(describing: loaded))")
        #expect((try? started.get()) != nil, "the stated limit isn't what happens: \(started)")
        _ = await offPool { MacAgent(place: place, steps: agent.agent.steps).stop() }
    }

    /// An ancestor swapped and back with keys `print` shows: refused by launchd's word, and unloaded.
    @Test func anAncestorSwappedAndBackWithShownKeysIsRefused() async throws {
        let shown: [(String, (inout [String: Any]) -> Void)] = [
            ("KeepAlive", { $0["KeepAlive"] = true }),
            ("an extra variable", { var env = $0["EnvironmentVariables"] as? [String: String] ?? [:]; env["PLANTED"] = "1"; $0["EnvironmentVariables"] = env }),
            ("StandardOutPath", { $0["StandardOutPath"] = $0["StandardErrorPath"] }),
        ]
        for (what, change) in shown {
            let agent = try ScratchAgent(scratch)
            defer { agent.tearDown() }
            let place = try lowered(agent)
            let (started, loaded) = try await wrapped(agent, place: place, change) { path, folder, aside, bootstrap in
                Self.ancestorSwap(folder: folder, path: path, aside: aside, bootstrap)
            }
            print("RECHECK ancestor swapped and back, \(what): \(started)")
            #expect((try? started.get()) == nil, "\(what): taken")
            #expect(loaded == nil, "\(what): left loaded")
            agent.tearDown()
        }
    }

    /// The measurement behind the stated limit: for each key, an ancestor swapped and back, and what start says. Keys it
    /// accepts are the ones the file check alone binds. Prints a table; asserts only that nothing is left loaded after
    /// a refusal.
    @Test func surveyOfKeysThroughAnAncestorSwap() async throws {
        let keys: [(String, Any)] = [
            ("Nice", 5), ("ThrottleInterval", 1), ("ExitTimeOut", 1), ("SoftResourceLimits", ["NumberOfFiles": 64]),
            ("HardResourceLimits", ["Core": 1_000_000]), ("Umask", 0), ("WorkingDirectory", "/"),
            ("StandardInPath", "/dev/zero"), ("ProcessType", "Interactive"), ("AbandonProcessGroup", true), ("LowPriorityIO", true),
            ("StartInterval", 3600), ("WatchPaths", ["/nonexistent-recheck-watch"]), ("EnableTransactions", true),
            ("SessionCreate", true), ("LimitLoadToSessionType", "Aqua"), ("EnablePressuredExit", true), ("LaunchOnlyOnce", true),
        ]
        var rows: [String] = []
        for (key, value) in keys {
            let agent = try ScratchAgent(scratch)
            defer { agent.tearDown() }
            let place = try lowered(agent)
            let (started, loaded) = try await wrapped(agent, place: place, { $0[key] = value }) { path, folder, aside, bootstrap in
                Self.ancestorSwap(folder: folder, path: path, aside: aside, bootstrap)
            }
            switch started {
            case .success: rows.append("\(key): ACCEPTED (start said the node runs)")
            case .failure(let why): rows.append("\(key): refused: \(why.text.prefix(220))")
            }
            if case .failure = started { #expect(loaded == nil, "\(key): a refused start left its job loaded") }
            agent.tearDown()
        }
        print("RECHECK key survey through an ancestor swap:\n" + rows.joined(separator: "\n"))
    }

    static func ancestorSwap(folder: String, path: String, aside: Data, _ bootstrap: () -> MacAgent.Ran?) -> MacAgent.Ran? {
        let ancestor = (folder as NSString).deletingLastPathComponent
        rename(ancestor, ancestor + ".kept")
        mkdir(ancestor, 0o755)
        mkdir(folder, 0o755)
        try? aside.write(to: URL(fileURLWithPath: path))
        let ran = bootstrap()
        unlink(path)
        rmdir(folder)
        rmdir(ancestor)
        rename(ancestor + ".kept", ancestor)
        return ran
    }

    // MARK: I2

    /// A job of the label loaded from another plist (`Nice` 5, the pinned host's exact command line, kickstarted), that
    /// plist then replaced by a symbolic link to the agent's plist (start's bytes): is it taken as the node? I2 says a
    /// running job loaded from another plist is refused.
    @Test func aJobFromAnotherPlistThatIsNowALinkToTheAgentsPlist() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        try FileManager.default.createDirectory(atPath: agent.place.plistFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try NodeAgent.plist(agent.job).get().write(to: URL(fileURLWithPath: agent.place.plistPath))
        var values = NodeAgent.dictionary(agent.job)
        values["Nice"] = 5
        let other = try agent.foreign(values)
        #expect(agent.launchctl(["kickstart", agent.place.target])?.status == 0)
        #expect(await eventually { agent.hostAnswers() }, "\(agent.log)")
        let pid = try #require(agent.printed()?.pid)
        agent.loaded.append(pid)
        unlink(other)
        #expect(symlink(agent.place.plistPath, other) == 0)
        let shownPath = agent.printed()?.path
        let status = await offPool { agent.agent.status() }
        let started = await offPool { agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }
        print("RECHECK another plist, now a link to the agent's: launchd's path \(String(describing: shownPath)); status \(status); start \(started)")
        #expect((try? status.get()) == nil, "status took a job loaded from another plist (now a link to the agent's)")
        #expect((try? started.get()) == nil, "start took it as running already")
        let stopped = await offPool { agent.agent.stop() }
        #expect((try? stopped.get()) == nil, "stop ended a job from another plist")
    }

    /// The same with a hard link: the other plist's name made a hard link of the agent's plist after the load.
    @Test func aJobFromAnotherPlistThatIsNowAHardLinkOfTheAgentsPlist() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        try FileManager.default.createDirectory(atPath: agent.place.plistFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try NodeAgent.plist(agent.job).get().write(to: URL(fileURLWithPath: agent.place.plistPath))
        var values = NodeAgent.dictionary(agent.job)
        values["Nice"] = 5
        let other = try agent.foreign(values)
        #expect(agent.launchctl(["kickstart", agent.place.target])?.status == 0)
        #expect(await eventually { agent.hostAnswers() }, "\(agent.log)")
        let pid = try #require(agent.printed()?.pid)
        agent.loaded.append(pid)
        unlink(other)
        #expect(link(agent.place.plistPath, other) == 0)
        let status = await offPool { agent.agent.status() }
        print("RECHECK another plist, now a hard link of the agent's: status \(status)")
        #expect((try? status.get()) == nil, "status took a job loaded from another plist (now a hard link of the agent's)")
        let stopped = await offPool { agent.agent.stop() }
        #expect((try? stopped.get()) == nil, "stop ended a job from another plist")
    }

    /// From the agent's own path: the pinned host with other arguments (`--idle-exit 601`), start's bytes written back
    /// after the load. start, status and stop refuse it; it runs on, loaded.
    @Test func otherArgumentsFromTheAgentsOwnPathAreLeftAlone() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        var values = NodeAgent.dictionary(agent.job)
        values["ProgramArguments"] = agent.job.programArguments.map { $0 == "600" ? "601" : $0 }
        try FileManager.default.createDirectory(atPath: agent.place.plistFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: URL(fileURLWithPath: agent.place.plistPath))
        #expect(agent.launchctl(["bootstrap", agent.place.domain, agent.place.plistPath])?.status == 0)
        #expect(agent.launchctl(["kickstart", agent.place.target])?.status == 0)
        #expect(await eventually { agent.hostAnswers() }, "\(agent.log)")
        let pid = try #require(agent.printed()?.pid)
        agent.loaded.append(pid)
        unlink(agent.place.plistPath)
        try NodeAgent.plist(agent.job).get().write(to: URL(fileURLWithPath: agent.place.plistPath))
        if case .success = await offPool({ agent.agent.status() }) { Issue.record("status took it") }
        if case .success = await offPool({ agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }) { Issue.record("start took it") }
        if case .success = await offPool({ agent.agent.stop() }) { Issue.record("stop took it") }
        #expect(agent.printed()?.pid == pid && kill(pid, 0) == 0, "it wasn't left alone")
    }

    // MARK: N1

    /// No server: what `confirm` shows says what ends and how (the bootout, the hangup), and it is asked once.
    @Test func withNoServerWhatEndsAndHowIsSaidOnce() throws {
        let dir = try scratch.shortFolder("vsr1").path
        let place = NodeAgent.Place(label: "dev.vibeswitcher.node.test-rc", plistFolder: dir + "/la", dataRoot: dir + "/node",
                                    lock: dir + "/node/host.lock", uid: getuid(), launchctl: "/bin/launchctl")
        let job = try MacAgentRoundTests.standIn(place)
        let row = NodePins.Build(commit: String(repeating: "e", count: 40), host: Data(repeating: 1, count: 20), server: Data(repeating: 2, count: 20), cli: Data(repeating: 3, count: 20))
        let shown = Locked<[String]>([])
        let gone = Locked(false)
        var steps = MacAgent.Steps(launchctl: { words in
                                       switch words.first {
                                       case "print": return gone.value ? MacAgent.Ran(status: 113, output: "") : MacAgent.Ran(status: 0, output: MacAgentTests.printed(job, place: place, pid: 4242))
                                       case "bootout": gone.value = true; return MacAgent.Ran(status: 0, output: "")
                                       default: return MacAgent.Ran(status: 0, output: "")
                                       }
                                   },
                                   pins: { .success(NodePins(uid: getuid(), builds: [row])) }, cdhashOf: { _ in nil },
                                   see: { _, pid, _ in .host(MacAgent.Host(commit: row.commit, pid: pid, startedAt: nil)) }, say: { _ in },
                                   confirm: { what in shown.value.append(what); return .success(()) },
                                   serverStop: { _ in Issue.record("serverStop asked with no server"); return .stopped },
                                   children: { _ in [] }, alive: { _ in false }, lockFree: { _ in true }, patience: 2,
                                   arguments: { _ in job.programArguments }, job: { _ in job }, server: { .none("nothing listens") })
        steps.executable = { _ in job.programArguments[0] }
        steps.sessionID = { _ in nil }
        let stopped = MacAgent(place: place, steps: steps).stop()
        #expect((try? stopped.get()) != nil, "\(stopped)")
        #expect(shown.value.count == 1, "\(shown.value)")
        #expect(shown.value.first.map { $0.contains("bootout") && $0.contains("hangup") && $0.contains("nothing listens") } == true, "\(shown.value)")
    }

    // MARK: N2

    /// A session's leftover whose session leader (the host's child) ended before stop's look, in that leader's session,
    /// still carrying the session's id, ignoring TERM and HUP: no parent link reaches it, and its session's leader is in
    /// no look. The spec says only a process that left its session and carries no readable id can't be found: does stop
    /// say it ended while it runs?
    @Test func limitAnOrphanInADeadLeadersSessionCarryingTheId() async throws {
        let dir = try scratch.shortFolder("vsr2").path
        let ready = dir + "/orphan.pid", leader = dir + "/leader.pid"
        let id = UUID().uuidString
        // host -> child (setsid: a session's program) -> grandchild (stays in the session, ignores TERM and HUP); the
        // child exits at once, so the grandchild is launchd's. The environment reads are injected (the stand-ins are
        // Apple's platform binaries, whose environment the kernel doesn't give): the session's program and its
        // leftover carry `id` while they run, as a session's processes do.
        let script = "my $c = fork; if (!$c) { POSIX::setsid(); open(my $l, '>', '\(leader)'); print $l $$; close($l); my $g = fork; if (!$g) { $SIG{TERM}='IGNORE'; $SIG{HUP}='IGNORE'; open(my $f, '>', '\(ready)'); print $f $$; close($f); sleep 600; exit 0 } exit 0 } waitpid($c, 0); sleep 600"
        var spawn = Platform.Spawn(executable: "/usr/bin/perl", arguments: ["perl", "-MPOSIX", "-e", script])
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.group = .ownGroup
        guard case .success(let host) = spawn.start() else { Issue.record("no stand-in host"); return }
        #expect(await eventually { ((try? String(contentsOfFile: ready, encoding: .utf8)).flatMap { pid_t($0) }) != nil })
        let orphan = try #require((try? String(contentsOfFile: ready, encoding: .utf8)).flatMap { pid_t($0) })
        let program = try #require((try? String(contentsOfFile: leader, encoding: .utf8)).flatMap { pid_t($0) })
        defer { kill(orphan, SIGKILL); kill(-host, SIGKILL); var s: Int32 = 0; waitpid(host, &s, 0) }
        #expect(await eventually { kill(program, 0) != 0 && Platform.Processes.children(host).isEmpty }, "the session's program didn't end")
        let place = NodeAgent.Place(label: "dev.vibeswitcher.node.test-rc", plistFolder: dir + "/la", dataRoot: dir + "/node",
                                    lock: dir + "/node/host.lock", uid: getuid(), launchctl: "/bin/launchctl")
        let job = try MacAgentRoundTests.standIn(place)
        let gone = Locked(false)
        var steps = MacAgent.Steps.system(place: place, pins: { .success(NodePins(uid: getuid(), builds: [NodePins.Build(commit: "c", host: Data(), server: Data(), cli: Data())])) },
                                          say: { _ in }, confirm: { _ in .success(()) }, serverStop: { _ in .none("no server answers") }, job: { _ in job })
        steps.arguments = { _ in job.programArguments }
        steps.executable = { _ in job.programArguments[0] }
        steps.sessionID = { pid in (pid == program || pid == orphan) && kill(pid, 0) == 0 ? id : nil }
        steps.carrying = { ids in ids.contains(id) && kill(orphan, 0) == 0 ? Platform.Processes.link(orphan).map { [$0] } ?? [] : [] }
        steps.launchctl = { words in
            switch words.first {
            case "print": return gone.value ? MacAgent.Ran(status: 113, output: "") : MacAgent.Ran(status: 0, output: MacAgentTests.printed(job, place: place, pid: host))
            case "bootout": kill(-host, SIGKILL); var s: Int32 = 0; waitpid(host, &s, 0); gone.value = true; return MacAgent.Ran(status: 0, output: "")
            default: return MacAgent.Ran(status: 0, output: "")
            }
        }
        steps.see = { _, pid, _ in .host(MacAgent.Host(commit: "c", pid: pid, startedAt: nil)) }
        steps.patience = 3
        let stopped = await offPool { MacAgent(place: place, steps: steps).stop() }
        print("RECHECK orphan in a dead leader's session carrying the id: \(stopped); orphan alive: \(kill(orphan, 0) == 0); its session \(getsid(orphan))")
        // The stated limit (the design's table; a host-side record of its sessions' ids is owed): no look finds the orphan,
        // and stop's words never claim more than what it could find.
        if case .success(let said) = stopped, kill(orphan, 0) == 0 {
            #expect(said.contains("stop could find") && !said.contains("every process it started has ended"), "\(said)")
        }
    }

    // MARK: N4

    /// A plist folder of another owner (root's `/usr/share`): refused before anything is written or loaded.
    @Test func aFolderOfAnotherOwnerIsRefused() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        let p = agent.place
        let place = NodeAgent.Place(label: p.label, plistFolder: "/usr/share", dataRoot: p.dataRoot, lock: p.lock, uid: p.uid, launchctl: p.launchctl)
        let started = await offPool { MacAgent(place: place, steps: agent.agent.steps).start(agent.job, build: agent.build, folder: agent.folder) }
        guard case .failure(let why) = started else { Issue.record("started in root's folder"); return }
        #expect(why.text.contains("another owner") || why.text.contains("only the user"), "\(why.text)")
        #expect(agent.printed() == nil)
    }

    /// A group-writable folder (0775) and a group-writable plist (0664): each refused, nothing loaded.
    @Test func groupWritableFolderAndPlistAreRefused() async throws {
        do {
            let agent = try ScratchAgent(scratch)
            defer { agent.tearDown() }
            try FileManager.default.createDirectory(atPath: agent.place.plistFolder, withIntermediateDirectories: true)
            chmod(agent.place.plistFolder, 0o775)
            if case .success = await offPool({ agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }) { Issue.record("a 0775 folder was taken") }
            #expect(agent.printed() == nil && !FileManager.default.fileExists(atPath: agent.place.plistPath))
        }
        do {
            let agent = try ScratchAgent(scratch)
            defer { agent.tearDown() }
            try FileManager.default.createDirectory(atPath: agent.place.plistFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            try NodeAgent.plist(agent.job).get().write(to: URL(fileURLWithPath: agent.place.plistPath))
            chmod(agent.place.plistPath, 0o664)
            if case .success = await offPool({ agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }) { Issue.record("a 0664 plist was taken") }
            #expect(agent.printed() == nil)
        }
    }

    /// A folder whose mode bits say only the user writes it, with an ACL granting everyone `add_file,delete_child`: the
    /// spec says the folder must be writable by neither group nor others. And a plist of start's bytes, 0644, with an
    /// ACL granting everyone `write`.
    @Test func aclsThatLetOthersWrite() async throws {
        do {
            let agent = try ScratchAgent(scratch)
            defer { agent.tearDown() }
            try FileManager.default.createDirectory(atPath: agent.place.plistFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            try ScratchAgent.run("/bin/chmod", ["+a", "everyone allow add_file,delete_child", agent.place.plistFolder])
            let started = await offPool { agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }
            print("RECHECK folder with an ACL for everyone: \(started)")
            #expect((try? started.get()) == nil, "a folder others can write by ACL was taken")
            _ = await offPool { agent.agent.stop() }
        }
        do {
            let agent = try ScratchAgent(scratch)
            defer { agent.tearDown() }
            try FileManager.default.createDirectory(atPath: agent.place.plistFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            try NodeAgent.plist(agent.job).get().write(to: URL(fileURLWithPath: agent.place.plistPath))
            chmod(agent.place.plistPath, 0o644)
            try ScratchAgent.run("/bin/chmod", ["+a", "everyone allow write", agent.place.plistPath])
            let started = await offPool { agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }
            print("RECHECK plist with an ACL for everyone: \(started); loaded \(agent.printed() != nil)")
            #expect((try? started.get()) == nil, "a plist others can write by ACL was taken (and launchd loaded it)")
            _ = await offPool { agent.agent.stop() }
        }
    }

    // MARK: The lock nit

    /// The user's lock not there yet, and a scratch `--lock` that is a symbolic link to its path: the same file once the
    /// host opens it (`HostServer.start` follows links and makes it).
    @Test func aLinkToTheUsersLockNotYetMade() throws {
        let dir = try scratch.shortFolder("vsrl").path
        let users = dir + "/user/host.lock"
        try FileManager.default.createDirectory(atPath: dir + "/user", withIntermediateDirectories: true)
        let linked = dir + "/scratch.lock"
        #expect(symlink(users, linked) == 0)
        #expect(CheckedSessions.isSameLock(linked, users), "a link to the user's lock path (not yet made) isn't the user's lock")
        #expect(CheckedSessions.isSameLock(dir + "/user/../user/host.lock", users))
    }
}

extension MacAgentRecheckTests {
    /// I1 with no write to the plist, its folder or an ancestor: start's own bootstrap goes through, then (before the
    /// host is seen) the label is booted out and a job of it bootstrapped from another plist elsewhere (`Nice` 5, the
    /// pinned host's exact command line), and that other plist replaced by a symbolic link to the agent's plist. Does
    /// start say the node runs, with a loaded job that differs from the one it wrote?
    @Test func startsJobReplacedFromAnotherPlistThenLinked() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        var values = NodeAgent.dictionary(agent.job)
        values["Nice"] = 5
        let other = agent.dir + "/other.plist"
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: URL(fileURLWithPath: other))
        let place = agent.place
        var steps = agent.agent.steps
        let real = steps.launchctl
        steps.launchctl = { words in
            guard words.first == "bootstrap" else { return real(words) }
            let ran = real(words)
            _ = real(["bootout", place.target])
            _ = real(["bootstrap", place.domain, other])
            unlink(other)
            symlink(place.plistPath, other)
            return ran
        }
        steps.patience = 20
        let started = await offPool { MacAgent(place: place, steps: steps).start(agent.job, build: agent.build, folder: agent.folder) }
        let printed = agent.printed()
        if let pid = printed?.pid { agent.loaded.append(pid) }
        let raw = agent.launchctl(["print", place.target])?.output ?? ""
        print("RECHECK start's job replaced from another plist, then linked: \(started); launchd's path \(String(describing: printed?.path)); nice line: \(raw.split(separator: "\n").filter { $0.lowercased().contains("nice") })")
        #expect((try? started.get()) == nil, "start said the node runs with a job loaded from another plist (Nice 5)")
        #expect((try? started.get()) != nil || printed == nil, "a refused start left a job loaded")
    }

    /// What `launchctl print` shows of each key: a job of the scratch label bootstrapped (not started) from a plist of
    /// start's job plus the key, its print diffed with the plain job's. Prints, per key, the lines that differ.
    @Test func surveyOfWhatPrintShows() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        let empty = agent.dir + "/empty-stdin"
        FileManager.default.createFile(atPath: empty, contents: Data())
        let keys: [(String, Any)] = Self.surveyKeys(dir: agent.dir, stdin: empty)
        func printed(_ values: [String: Any]) throws -> [String] {
            let path = agent.dir + "/survey-\(UUID().uuidString.prefix(6)).plist"
            try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: URL(fileURLWithPath: path))
            guard agent.launchctl(["bootstrap", agent.place.domain, path])?.status == 0 else { return ["(bootstrap refused)"] }
            let out = agent.launchctl(["print", agent.place.target])?.output ?? ""
            _ = agent.launchctl(["bootout", agent.place.target])
            _ = await_unloaded(agent)
            return out.split(separator: "\n").map(String.init).filter { !$0.contains(path) && !$0.contains("immediate reason") }
        }
        let base = NodeAgent.dictionary(agent.job)
        let plain = Set(try printed(base))
        var rows: [String] = []
        for (key, value) in keys {
            var values = base
            values[key] = value
            let lines = try printed(values)
            let added = lines.filter { !plain.contains($0) }
            rows.append("\(key): " + (added.isEmpty ? "NOT SHOWN" : added.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " | ")))
        }
        print("RECHECK what print shows:\n" + rows.joined(separator: "\n"))
        #expect(agent.printed() == nil)
    }

    static func surveyKeys(dir: String, stdin: String) -> [(String, Any)] {
        [
            ("Nice", 5), ("ThrottleInterval", 1), ("ExitTimeOut", 1), ("SoftResourceLimits", ["NumberOfFiles": 64]),
            ("HardResourceLimits", ["Core": 1_000_000]), ("Umask", 0), ("WorkingDirectory", "/"),
            ("StandardInPath", stdin), ("ProcessType", "Interactive"), ("AbandonProcessGroup", true), ("LowPriorityIO", true),
            ("StartInterval", 3600), ("StartCalendarInterval", ["Minute": 7]), ("WatchPaths", [dir + "/watch-none"]),
            ("QueueDirectories", [dir + "/queue-none"]), ("KeepAlive", ["SuccessfulExit": false]), ("KeepAlive", ["Crashed": true]),
            ("KeepAlive", ["PathState": [dir + "/path-state": false]]), ("EnableTransactions", true), ("SessionCreate", true),
            ("LimitLoadToSessionType", "Aqua"), ("EnablePressuredExit", true), ("LaunchOnlyOnce", true),
            ("MachServices", ["dev.vibeswitcher.node.test-recheck.planted": true]),
        ]
    }

    /// N2 between the two looks: the host's child (a session's program, its id in its environment, in its own group) is
    /// in the first look; while the prompt waits it forks a child that leaves its session (setsid, ignoring TERM and
    /// HUP), carrying the id, and exits. Does stop say it ended every process it could find while that one runs?
    @Test func aChildThatLeavesItsSessionBetweenTheTwoLooks() async throws {
        let dir = try scratch.shortFolder("vsr3").path
        let go = dir + "/go", ready = dir + "/left.pid", programFile = dir + "/program.pid"
        let id = UUID().uuidString
        let script = "$SIG{CHLD}='IGNORE'; my $c = fork; if (!$c) { setpgid(0, 0); open(my $p, '>', '\(programFile)'); print $p $$; close($p); until (-e '\(go)') { select(undef, undef, undef, 0.05) } my $g = fork; if (!$g) { POSIX::setsid(); $SIG{TERM}='IGNORE'; $SIG{HUP}='IGNORE'; open(my $f, '>', '\(ready)'); print $f $$; close($f); sleep 600; exit 0 } exit 0 } sleep 600"
        var spawn = Platform.Spawn(executable: "/usr/bin/perl", arguments: ["perl", "-MPOSIX", "-e", script])
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.group = .ownGroup
        guard case .success(let host) = spawn.start() else { Issue.record("no stand-in host"); return }
        let left = Locked<pid_t>(0)
        defer { if left.value > 0 { kill(left.value, SIGKILL) }; FileManager.default.createFile(atPath: go, contents: Data()); kill(-host, SIGKILL); var s: Int32 = 0; waitpid(host, &s, 0) }
        #expect(await eventually { ((try? String(contentsOfFile: programFile, encoding: .utf8)).flatMap { pid_t($0) }) != nil })
        let program = try #require((try? String(contentsOfFile: programFile, encoding: .utf8)).flatMap { pid_t($0) })
        let place = NodeAgent.Place(label: "dev.vibeswitcher.node.test-rc", plistFolder: dir + "/la", dataRoot: dir + "/node",
                                    lock: dir + "/node/host.lock", uid: getuid(), launchctl: "/bin/launchctl")
        let job = try MacAgentRoundTests.standIn(place)
        let gone = Locked(false)
        var steps = MacAgent.Steps.system(place: place, pins: { .success(NodePins(uid: getuid(), builds: [NodePins.Build(commit: "c", host: Data(), server: Data(), cli: Data())])) },
                                          say: { _ in },
                                          confirm: { _ in
                                              // The prompt: meanwhile the session's program forks one that leaves its session, and exits.
                                              FileManager.default.createFile(atPath: go, contents: Data())
                                              let deadline = Platform.Clock.steadyDate().addingTimeInterval(20)
                                              while Platform.Clock.steadyDate() < deadline {
                                                  if let pid = (try? String(contentsOfFile: ready, encoding: .utf8)).flatMap({ pid_t($0) }), Platform.Processes.children(host).isEmpty {
                                                      left.value = pid
                                                      break
                                                  }
                                                  usleep(20_000)
                                              }
                                              return .success(())
                                          },
                                          serverStop: { _ in .none("no server answers") }, job: { _ in job })
        steps.arguments = { _ in job.programArguments }
        steps.executable = { _ in job.programArguments[0] }
        // The environment reads injected (the stand-ins are platform binaries): the session's program and what it
        // forked carry `id` while they run.
        steps.sessionID = { pid in (pid == program || (left.value > 0 && pid == left.value)) && kill(pid, 0) == 0 ? id : nil }
        steps.carrying = { ids in ids.contains(id) && left.value > 0 && kill(left.value, 0) == 0 ? Platform.Processes.link(left.value).map { [$0] } ?? [] : [] }
        steps.launchctl = { words in
            switch words.first {
            case "print": return gone.value ? MacAgent.Ran(status: 113, output: "") : MacAgent.Ran(status: 0, output: MacAgentTests.printed(job, place: place, pid: host))
            case "bootout": kill(-host, SIGKILL); var s: Int32 = 0; waitpid(host, &s, 0); gone.value = true; return MacAgent.Ran(status: 0, output: "")
            default: return MacAgent.Ran(status: 0, output: "")
            }
        }
        steps.see = { _, pid, _ in .host(MacAgent.Host(commit: "c", pid: pid, startedAt: nil)) }
        steps.patience = 3
        let stopped = await offPool { MacAgent(place: place, steps: steps).stop() }
        try #require(left.value > 0, "the leaver never came")
        print("RECHECK a child leaving its session between the looks: \(stopped); it runs: \(kill(left.value, 0) == 0)")
        #expect((try? stopped.get()) == nil || kill(left.value, 0) != 0, "stop said it ended every process it could find while pid \(left.value), carrying the session's id, runs")
    }
}

/// Waits until launchd has no job of the scratch label (bounded), for the print survey.
func await_unloaded(_ agent: ScratchAgent) -> Bool {
    let deadline = Platform.Clock.steadyDate().addingTimeInterval(10)
    while agent.printed() != nil {
        guard Platform.Clock.steadyDate() < deadline else { return false }
        usleep(50_000)
    }
    return true
}

extension MacAgentRecheckTests {
    /// The job's own variable (`SHELL`) with its value followed by lines that `NodeAgent.printed` reads as the job's:
    /// `}` ending the environment block, `path = <the agent's plist>`, a new environment block, and a line the parser
    /// skips. A job of the label loaded from another plist with that value.
    func injected(_ agent: ScratchAgent) -> [String: Any] {
        var values = NodeAgent.dictionary(agent.job)
        var env = agent.job.environment
        env["SHELL"] = (env["SHELL"] ?? "/bin/sh") + "\n\t}\n\tpath = \(agent.place.plistPath)\n\tenvironment = {\n,planted-after-the-newline=yes"
        values["EnvironmentVariables"] = env
        values["Nice"] = 5
        return values
    }

    /// I2 through launchd's text: is a job loaded from another plist taken as the node because a value in its
    /// environment prints a `path` line? (`print`'s text is said to be a refusal only.)
    @Test func aValueThatPrintsAPathLineMakesAnotherPlistOurs() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        try FileManager.default.createDirectory(atPath: agent.place.plistFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try NodeAgent.plist(agent.job).get().write(to: URL(fileURLWithPath: agent.place.plistPath))
        let other = try agent.foreign(injected(agent))
        #expect(agent.launchctl(["kickstart", agent.place.target])?.status == 0)
        #expect(await eventually { agent.hostAnswers() }, "\(agent.log)")
        let pid = try #require(agent.printed()?.pid)
        agent.loaded.append(pid)
        let raw = agent.launchctl(["print", agent.place.target])?.output ?? ""
        let parsed = agent.printed()
        print("RECHECK injected path line: loaded from \(other); parsed path \(String(describing: parsed?.path)); parsed SHELL \(String(describing: parsed?.environment?["SHELL"])); raw env lines: \(raw.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.contains("SHELL") || $0.contains("planted") || $0.contains("path =") })")
        print("RECHECK injected: the host's own SHELL: \(String(describing: Platform.Processes.environment(pid)?.first { $0.hasPrefix("SHELL=") }))")
        let status = await offPool { agent.agent.status() }
        let started = await offPool { agent.agent.start(agent.job, build: agent.build, folder: agent.folder) }
        print("RECHECK injected path line: status \(status); start \(started)")
        #expect((try? status.get()) == nil, "status took a job from another plist (Nice 5, a planted value) for the node")
        #expect((try? started.get()) == nil, "start took it as running already")
    }

    /// I1 through launchd's text: start's own bootstrap, then its job swapped (bootout, bootstrap) for one from another
    /// plist whose value prints the agent's `path`: no write to the plist, its folder or an ancestor.
    @Test func startsJobSwappedForOneWhoseValuePrintsTheAgentsPath() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        let other = agent.dir + "/injected.plist"
        try PropertyListSerialization.data(fromPropertyList: injected(agent), format: .xml, options: 0).write(to: URL(fileURLWithPath: other))
        let place = agent.place
        var steps = agent.agent.steps
        let real = steps.launchctl
        steps.launchctl = { words in
            guard words.first == "bootstrap" else { return real(words) }
            let ran = real(words)
            _ = real(["bootout", place.target])
            _ = real(["bootstrap", place.domain, other])
            return ran
        }
        steps.patience = 20
        let started = await offPool { MacAgent(place: place, steps: steps).start(agent.job, build: agent.build, folder: agent.folder) }
        let printed = agent.printed()
        if let pid = printed?.pid { agent.loaded.append(pid) }
        print("RECHECK start's job swapped for an injected one: \(started); loaded after: \(String(describing: printed))")
        #expect((try? started.get()) == nil, "start said the node runs with a job from another plist (Nice 5, a planted value)")
        #expect((try? started.get()) != nil || printed == nil, "a refused start left a job loaded")
    }
}

extension MacAgentRecheckTests {
    /// The link route with `KeepAlive` as a dictionary (`SuccessfulExit` false: launchd starts the host again whenever
    /// it exits), which `print` shows as `semaphores`, not in `properties`: does start say the node runs?
    @Test func startsJobReplacedByAKeepAliveDictionaryJobThenLinked() async throws {
        let agent = try ScratchAgent(scratch)
        defer { agent.tearDown() }
        var values = NodeAgent.dictionary(agent.job)
        values["KeepAlive"] = ["SuccessfulExit": false]
        let other = agent.dir + "/other.plist"
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: URL(fileURLWithPath: other))
        let place = agent.place
        var steps = agent.agent.steps
        let real = steps.launchctl
        steps.launchctl = { words in
            guard words.first == "bootstrap" else { return real(words) }
            let ran = real(words)
            _ = real(["bootout", place.target])
            _ = real(["bootstrap", place.domain, other])
            unlink(other)
            symlink(place.plistPath, other)
            return ran
        }
        steps.patience = 20
        let started = await offPool { MacAgent(place: place, steps: steps).start(agent.job, build: agent.build, folder: agent.folder) }
        let printed = agent.printed()
        if let pid = printed?.pid { agent.loaded.append(pid) }
        let raw = agent.launchctl(["print", place.target])?.output ?? ""
        print("RECHECK start's job replaced by a KeepAlive-dictionary job, then linked: \(started); semaphores: \(raw.contains("successful exit")); properties: \(String(describing: printed?.properties))")
        #expect((try? started.get()) == nil, "start said the node runs with a KeepAlive (SuccessfulExit false) job from another plist")
    }
}
