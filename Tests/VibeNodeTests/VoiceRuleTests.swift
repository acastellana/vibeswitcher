import Foundation
import Testing
import VibeCore
import VibeNode

/// The user's voice as a pure function (`Voice.judge`) on the fixtures E1's Step 1 recorded
/// (docs/process/v2-linux-inventory.md, "The voice rule's scopes"): this machine's hybrid layout gives a `0::` line and a
/// v1 `name=systemd` line, and both are read. The Mac runs these.
struct VoiceRuleTests {
    static let uid: uid_t = 1000

    /// A hybrid layout's lines for `path`, as measured here: the v1 lines first, the unified one last.
    static func hybrid(_ path: String) -> [String] {
        ["29:name=systemd:\(path)", "28:misc:/", "26:pids:\(path)", "19:memory:\(path)", "15:cpuset:/", "0::\(path)"]
    }

    /// A Windows Terminal tab's shell here, as the user measured it (the bootstrap path's M4, 2026-11-17, after a `wsl
    /// --shutdown`): every line of `/proc/self/cgroup`.
    static let terminalTab = ["15:name=systemd:/init.scope", "14:misc:/", "13:rdma:/", "12:pids:/init.scope", "11:hugetlb:/", "10:net_prio:/",
                              "9:perf_event:/", "8:net_cls:/", "7:freezer:/", "6:devices:/init.scope", "5:memory:/init.scope", "4:blkio:/",
                              "3:cpuacct:/", "2:cpu:/", "1:cpuset:/", "0::/init.scope"]

    /// The unit the user's `systemd-run --user --wait --pipe cat /proc/self/cgroup` ran in (M4, 2026-11-17): its name
    /// is from the user's journal (`Started run-u0.service`, logged by the user's manager, whose own cgroup is
    /// `…/user@1000.service/init.scope`). The line it printed wasn't captured: this path is derived, not pasted.
    static let systemdRunUnit = "/user.slice/user-1000.slice/user@1000.service/app.slice/run-u0.service"

    static let nodeUnit = "/user.slice/user-1000.slice/user@1000.service/app.slice/vibeswitcher-node.service"
    /// The server's rule when it runs in the node's unit.
    static let systemd = VoiceRule.at(start: hybrid(nodeUnit), testScopes: nil, uid: uid)

    /// A peer that passes every line, in `/init.scope`; each case changes one fact.
    static func peer(cgroup: [String]? = hybrid("/init.scope"), ancestry: [PeerFacts.Ancestor]? = [.init(pid: 900, startTicks: 5), .init(pid: 451, startTicks: 2)],
                     terminal: PeerFacts.Terminal = .named("ttypts0"), marker: Bool? = false, runner: Bool? = false, uid: uid_t? = VoiceRuleTests.uid) -> PeerFacts {
        PeerFacts(pid: 900, uid: uid, cgroup: cgroup, ancestry: ancestry, terminal: terminal, sessionMarker: marker, underRunner: runner)
    }

    static let live = LiveSessions(programs: [4000, 4100], terminals: ["ttypts7", "ttypts8"], host: 3000, server: 3001)

    static func judged(_ facts: PeerFacts, rule: VoiceRule = systemd) -> Voice { Voice.judge(facts, live: live, rule: rule) }

    static func refused(_ voice: Voice) -> Bool { if case .notUser = voice { return true } else { return false } }

    @Test func aTerminalScopeIsTheUser() {
        #expect(Self.systemd.mode == .systemd)
        #expect(Self.judged(Self.peer()) == .user)
        #expect(Self.judged(Self.peer(cgroup: Self.hybrid("/user.slice/user-1000.slice/session-3.scope"))) == .user)
        // The unified hierarchy alone (no v1 lines) is read the same.
        #expect(Self.judged(Self.peer(cgroup: ["0::/init.scope"])) == .user)
        // The user's M4 (2026-11-17): a shell in a new Windows Terminal tab, a `claude` started there and its Bash
        // tool's child, each line as `cat /proc/self/cgroup` gave it (the v1 numbers are that boot's).
        #expect(Self.judged(Self.peer(cgroup: Self.terminalTab)) == .user)
        #expect(VoiceRule.terminalScopes.first?.basis.contains("the user's M4, 2026-11-17") == true)
        #expect(Self.judged(Self.peer(cgroup: ["0::/user.slice/user-1000.slice/session-12.scope"])) == .user)
        // Another user's session scope isn't this user's.
        #expect(Self.refused(Self.judged(Self.peer(cgroup: ["0::/user.slice/user-1001.slice/session-3.scope"]))))
        // The scope list is data: each row says where it comes from.
        // After WSL's kernel update (6.18, 2026-11-20) a Windows Terminal tab's shell and what it starts are in
        // /non-systemd, as `cat /proc/self/cgroup` gave it there (a unified hierarchy only).
        #expect(Self.judged(Self.peer(cgroup: ["0::/non-systemd"])) == .user)
        #expect(Self.refused(Self.judged(Self.peer(cgroup: ["0::/non-systemd/x.scope"]))))
        #expect(VoiceRule.terminalScopes.map(\.pattern) == ["/init.scope", "/non-systemd", "/user.slice/user-{uid}.slice/session-*.scope"])
        #expect(VoiceRule.terminalScopes.allSatisfy { $0.basis.hasPrefix("measured") || $0.basis.hasPrefix("documented") })
    }

    @Test func anAnswerFromTheNodesCgroupIsRefused() {
        let voice = Self.judged(Self.peer(cgroup: Self.hybrid(Self.nodeUnit)))
        #expect(voice == .notUser("its cgroup \(Self.nodeUnit) is the node's unit"), "\(voice)")
        // Outside the manager too (a unit of the system's of that name).
        #expect(Self.refused(Self.judged(Self.peer(cgroup: ["0::/system.slice/vibeswitcher-node.service"]))))
    }

    @Test func anAnswerFromATransientUserUnitIsRefused() {
        for path in ["/user.slice/user-1000.slice/user@1000.service/app.slice/run-u12.service",
                     "/user.slice/user-1000.slice/user@1000.service/app.slice/app-org.gnome.Terminal.slice/vte-spawn-1.scope",
                     "/user.slice/user-1000.slice/user@1000.service/init.scope"] {
            let voice = Self.judged(Self.peer(cgroup: Self.hybrid(path)))
            #expect(voice == .notUser("its cgroup \(path) is in the user's systemd manager (a user unit, systemd-run, a service)"), "\(path): \(voice)")
        }
        // The user's M4 (2026-11-17): `systemd-run --user` ran its command in `run-u0.service`. Refused on the unified
        // line alone, on the hybrid layout's lines, and when only the v1 line names the unit.
        let why = Voice.notUser("its cgroup \(Self.systemdRunUnit) is in the user's systemd manager (a user unit, systemd-run, a service)")
        #expect(Self.judged(Self.peer(cgroup: ["0::" + Self.systemdRunUnit])) == why)
        #expect(Self.judged(Self.peer(cgroup: Self.hybrid(Self.systemdRunUnit))) == why)
        #expect(Self.judged(Self.peer(cgroup: ["15:name=systemd:" + Self.systemdRunUnit, "0::/init.scope"])) == why)
        // A journal entry from it doesn't count either (`NodeJournal.passes` is the same rule on `_SYSTEMD_CGROUP`).
        #expect(Self.systemd.cgroupRefusal(["0::" + Self.systemdRunUnit]) != nil)
    }

    @Test func atAndCronAreRefused() {
        for path in ["/system.slice/atd.service", "/system.slice/cron.service"] {
            let voice = Self.judged(Self.peer(cgroup: Self.hybrid(path)))
            guard case .notUser(let why) = voice else { Issue.record("\(path) was taken"); continue }
            #expect(why.contains("no terminal scope"), "\(why)")
        }
    }

    @Test func aPeerWhoseCgroupCantBeReadIsNotTheUser() {
        #expect(Self.judged(Self.peer(cgroup: nil)) == .notUser("its cgroup can't be read"))
        // Lines that name neither hierarchy the rule reads.
        #expect(Self.judged(Self.peer(cgroup: ["26:pids:/init.scope", "15:cpuset:/"])) == .notUser("its cgroup names no systemd or unified hierarchy"))
        // On a hybrid layout both lines must pass: a v1 line in the user's manager isn't hidden by a unified one.
        let mixed = ["29:name=systemd:/user.slice/user-1000.slice/user@1000.service/app.slice/run-u3.service", "0::/init.scope"]
        #expect(Self.refused(Self.judged(Self.peer(cgroup: mixed))))
        // Its user unreadable, or another user.
        #expect(Self.judged(Self.peer(uid: nil)) == .notUser("its user can't be read"))
        #expect(Self.refused(Self.judged(Self.peer(uid: 1001))))
    }

    @Test func aPeerWhoseEnvironmentCantBeReadIsNotTheUser() {
        #expect(Self.judged(Self.peer(marker: nil)) == .notUser("its environment can't be read"))
        // Every other field unreadable fails it too.
        #expect(Self.judged(Self.peer(ancestry: nil)) == .notUser("its ancestry can't be read"))
        #expect(Self.judged(Self.peer(terminal: .unreadable)) == .notUser("its controlling terminal can't be read"))
        #expect(Self.judged(Self.peer(runner: nil)) == .notUser("whether it runs under branch code can't be read"))
    }

    @Test func aPeerUnderALiveSessionIsNotTheUser() {
        let underProgram = Self.peer(ancestry: [.init(pid: 900, startTicks: 9), .init(pid: 4100, startTicks: 8), .init(pid: 3000, startTicks: 1)])
        #expect(Self.judged(underProgram) == .notUser("it runs under a live session's program (pid 4100)"))
        let underHost = Self.peer(ancestry: [.init(pid: 900, startTicks: 9), .init(pid: 3000, startTicks: 1)])
        #expect(Self.judged(underHost) == .notUser("it runs under the session host (pid 3000)"))
        let underServer = Self.peer(ancestry: [.init(pid: 900, startTicks: 9), .init(pid: 3001, startTicks: 1)])
        #expect(Self.judged(underServer) == .notUser("it runs under the server (pid 3001)"))
        // The session's program itself.
        #expect(Self.refused(Self.judged(Self.peer(ancestry: [.init(pid: 4000, startTicks: 3)]))))
    }

    @Test func aPeerOnASessionsTerminalIsNotTheUser() {
        #expect(Self.judged(Self.peer(terminal: .named("ttypts8"))) == .notUser("its terminal ttypts8 is a live session's"))
        // No terminal at all is no session's.
        #expect(Self.judged(Self.peer(terminal: .none)) == .user)
    }

    @Test func aPeerWithTheSessionMarkerIsNotTheUser() {
        #expect(Self.judged(Self.peer(marker: true)) == .notUser("its environment carries VIBESWITCHER_SESSION"))
    }

    @Test func aPeerUnderABranchCodeRunnerIsNotTheUser() {
        #expect(Self.judged(Self.peer(runner: true)) == .notUser("it runs under a branch code runner"))
    }

    @Test func withoutSystemdTheRuleIsTheOtherFourAndSaysSo() {
        let weaker = VoiceRule.at(start: Self.hybrid("/init.scope"), testScopes: nil, uid: Self.uid)
        #expect(weaker.mode == .weaker)
        #expect(weaker.says.contains("weaker") && weaker.says.contains("isn't checked"), "\(weaker.says)")
        // No cgroup to tell by: cron's passes, and so does an unreadable one.
        #expect(Self.judged(Self.peer(cgroup: Self.hybrid("/system.slice/cron.service")), rule: weaker) == .user)
        #expect(Self.judged(Self.peer(cgroup: nil), rule: weaker) == .user)
        // The other four lines still hold.
        #expect(Self.refused(Self.judged(Self.peer(marker: true), rule: weaker)))
        #expect(Self.refused(Self.judged(Self.peer(terminal: .named("ttypts7")), rule: weaker)))
        #expect(Self.refused(Self.judged(Self.peer(ancestry: [.init(pid: 900, startTicks: 1), .init(pid: 3000, startTicks: 1)]), rule: weaker)))
        #expect(Self.refused(Self.judged(Self.peer(runner: true), rule: weaker)))
    }

    @Test func theWeakerRuleIsChosenOnlyFromTheServersOwnCgroup() {
        // `at` takes the server's own cgroup lines and nothing else: no file under /run/user/<uid> can choose it.
        #expect(VoiceRule.at(start: Self.hybrid(Self.nodeUnit), testScopes: nil, uid: Self.uid).mode == .systemd)
        #expect(VoiceRule.at(start: ["0::" + Self.nodeUnit], testScopes: nil, uid: Self.uid).mode == .systemd)
        // A unit of that name outside the user's manager, another user's manager, a scope of the user's: weaker.
        #expect(VoiceRule.at(start: ["0::/system.slice/vibeswitcher-node.service"], testScopes: nil, uid: Self.uid).mode == .weaker)
        #expect(VoiceRule.at(start: ["0::/user.slice/user-1001.slice/user@1001.service/app.slice/vibeswitcher-node.service"], testScopes: nil, uid: Self.uid).mode == .weaker)
        #expect(VoiceRule.at(start: Self.hybrid("/init.scope"), testScopes: nil, uid: Self.uid).mode == .weaker)
        // Its own cgroup unread where the system has cgroups: closed, never the weaker rule (`anUnreadOwnCgroupClosesTheRule`).
        #expect(VoiceRule.at(start: nil, testScopes: nil, uid: Self.uid, cgroups: true).mode == .closed)
        // Read, and naming neither hierarchy the rule reads (cgroup v1 with no systemd): no user manager, the weaker rule.
        #expect(VoiceRule.at(start: ["26:pids:/", "15:cpuset:/"], testScopes: nil, uid: Self.uid, cgroups: true).mode == .weaker)
        // Where the user's manager runs the server (another unit than the node's: `systemd-run --user`, a unit of a
        // worker's), the cgroup tells: the systemd rule, never the weaker one. Its sessions are in the user's manager
        // with it, so the rule refuses them.
        for path in ["/user.slice/user-1000.slice/user@1000.service/app.slice/run-u3.service",
                     "/user.slice/user-1000.slice/user@1000.service/init.scope"] {
            let rule = VoiceRule.at(start: Self.hybrid(path), testScopes: nil, uid: Self.uid)
            #expect(rule.mode == .systemd && rule.scopes == VoiceRule.terminalScopes, "\(path): \(rule)")
            #expect(Self.refused(Self.judged(Self.peer(cgroup: Self.hybrid(path)), rule: rule)))
            #expect(Self.judged(Self.peer(), rule: rule) == .user)
        }
        // On a hybrid layout either line in the user's manager is enough.
        let mixed = ["29:name=systemd:/user.slice/user-1000.slice/user@1000.service/app.slice/run-u3.service", "0::/init.scope"]
        #expect(VoiceRule.at(start: mixed, testScopes: nil, uid: Self.uid).mode == .systemd)
        // A scratch host's test scopes give the cgroup rule on those scopes alone.
        let test = VoiceRule.at(start: Self.hybrid("/init.scope"), testScopes: ["/test.scope"], uid: Self.uid)
        #expect(test.mode == .systemd && test.scopes.map(\.pattern) == ["/test.scope"])
        #expect(Self.judged(Self.peer(cgroup: ["0::/test.scope"]), rule: test) == .user)
        #expect(Self.refused(Self.judged(Self.peer(), rule: test)))
    }

    // MARK: A scratch node's test's cgroup root

    /// The test flag of a scratch node whose test runs inside the user's manager (the node's own merge gate):
    /// `--test-cgroup-root=`. A server with `--node` refuses it, as it does every test flag (it says so at its start:
    /// `refused`), and takes nothing from it; a scratch server takes a cgroup's path only.
    @Test func theTestCgroupRootIsRefusedUnderNode() throws {
        let base = ["vibeswitcher-server", "--host-connector", "3", "--host-socket", "/x/host.sock"]
        let flag = ServerArguments.testCgroupRootFlag + Self.nodeUnit
        let node = try ServerArguments.parse(base + ["--node", "--node-root", "/x/b", flag, ServerArguments.testUserScopesFlag + "/"]).get()
        #expect(node.refused == [flag, ServerArguments.testUserScopesFlag + "/"], "\(node)")
        #expect(node.testCgroupRoot == nil && node.testUserScopes == nil)
        // With both dropped the user's server reads the sender where it is, by the rule its own cgroup gives: a peer in
        // the node's unit (the test process such a flag would speak for) is refused by its cgroup, as ever.
        let rule = VoiceRule.at(start: Self.hybrid(Self.nodeUnit), testScopes: node.testUserScopes, uid: Self.uid)
        let lines = node.testCgroupRoot.map { PeerFacts.rerooted(Self.hybrid(Self.nodeUnit), at: $0) } ?? Self.hybrid(Self.nodeUnit)
        #expect(Self.judged(Self.peer(cgroup: lines), rule: rule) == .notUser("its cgroup \(Self.nodeUnit) is the node's unit"))

        let scratch = try ServerArguments.parse(base + ["--root", "/x", flag]).get()
        #expect(scratch.refused.isEmpty && scratch.testCgroupRoot == Self.nodeUnit, "\(scratch)")
        // Not a cgroup's path below the root: not taken (the server doesn't start).
        for bad in ["", "/", "relative.scope", "/a/", "/a//b", "/a/../b", "/a/./b"] {
            #expect(throws: ServerArguments.Usage.self, "\(bad)") { try ServerArguments.parse(base + ["--root", "/x", ServerArguments.testCgroupRootFlag + bad]).get() }
            #expect(PeerFacts.rerooted(Self.hybrid("/a/b"), at: bad) == Self.hybrid("/a/b"), "\(bad)")
        }
    }

    /// The root only says where a scratch node's test runs: a sender in that very cgroup reads `/`, which the test's
    /// scope names, and nothing else gains by it. A path outside the root is left as the machine has it and is refused
    /// as it would be without a root; a path under it is no scope of the test's; and the rule itself is the one every
    /// server applies (`cgroupRefusal`), so a re-read path still has to be a scope the rule knows.
    @Test func aCgroupRootRereadsOnlyWhatIsAtOrUnderItAndWidensNoScope() {
        let root = Self.nodeUnit
        let test = VoiceRule.at(start: Self.hybrid(root), testScopes: ["/"], uid: Self.uid)
        func judged(_ lines: [String], rule: VoiceRule = test) -> Voice { Self.judged(Self.peer(cgroup: PeerFacts.rerooted(lines, at: root)), rule: rule) }
        // The test's own cgroup, on the hybrid layout and the unified one alone: the user of a scratch node.
        #expect(PeerFacts.rerooted(Self.hybrid(root), at: root) == Self.hybrid("/"))
        #expect(judged(Self.hybrid(root)) == .user)
        #expect(judged(["0::" + root]) == .user)
        // Without the root the same test scope can't name it: the refusal a run in the node's unit met (2026-11-19).
        #expect(Self.judged(Self.peer(cgroup: Self.hybrid(root)), rule: test) == .notUser("its cgroup \(root) is the node's unit"))

        // Outside the root: as the machine has it, each refused for what it is.
        let managed = "is in the user's systemd manager (a user unit, systemd-run, a service)", noScope = "is no terminal scope this node knows (/)"
        let outside = ["/user.slice/user-1000.slice/user@1000.service/app.slice/run-u12.service": managed,
                       "/user.slice/user-1000.slice/user@1000.service/app.slice": managed,
                       "/user.slice/user-1000.slice/user@1000.service/init.scope": managed,
                       // A sibling whose name only starts as the root's does: whole components count.
                       root + "2": managed,
                       "/system.slice/vibeswitcher-node.service": "is the node's unit",
                       "/init.scope": noScope,
                       "/user.slice/user-1000.slice/session-3.scope": noScope]
        for (path, why) in outside {
            #expect(PeerFacts.rerooted(Self.hybrid(path), at: root) == Self.hybrid(path), "\(path)")
            #expect(judged(Self.hybrid(path)) == .notUser("its cgroup \(path) \(why)"), "\(path)")
        }
        // A hierarchy's line still outside (the systemd line in the root, the unified one elsewhere): refused by it.
        #expect(Self.refused(judged(["15:name=systemd:" + root, "0::/user.slice/user-1000.slice/user@1000.service/app.slice/run-u3.service"])))
        // Under the root: read from there, and no scope of the test's.
        #expect(PeerFacts.rerooted(["0::" + root + "/sub/leaf"], at: root) == ["0::/sub/leaf"])
        #expect(judged(["0::" + root + "/sub"]) == .notUser("its cgroup /sub is no terminal scope this node knows (/)"))
        // The other lines of a sender in the root still count: a session's marker, another user.
        #expect(Self.refused(Self.judged(Self.peer(cgroup: PeerFacts.rerooted(Self.hybrid(root), at: root), marker: true), rule: test)))
        #expect(Self.refused(Self.judged(Self.peer(cgroup: PeerFacts.rerooted(Self.hybrid(root), at: root), uid: 1001), rule: test)))
        // And the root alone is no pass: by the node's own rule (no test scopes) `/` is no terminal's scope.
        #expect(judged(Self.hybrid(root), rule: Self.systemd) == .notUser("its cgroup / is no terminal scope this node knows (/init.scope, /non-systemd, /user.slice/user-{uid}.slice/session-*.scope)"))
    }

    /// A scratch node gives its server a root only where its test runs inside the user's manager or the node's unit;
    /// from a terminal, on a CI runner and on the Mac (no cgroup) the server reads the machine's own paths.
    @Test func aScratchNodeGivesARootOnlyInsideTheUsersManager() {
        #expect(ScratchNode.cgroupRoot(own: Self.nodeUnit, uid: Self.uid) == Self.nodeUnit)
        #expect(ScratchNode.cgroupRoot(own: Self.systemdRunUnit, uid: Self.uid) == Self.systemdRunUnit)
        #expect(ScratchNode.cgroupRoot(own: "/system.slice/vibeswitcher-node.service", uid: Self.uid) == "/system.slice/vibeswitcher-node.service")
        for elsewhere in ["/init.scope", "/user.slice/user-1000.slice/session-3.scope", "/system.slice/hosted-compute-agent.service",
                          "/user.slice/user-1001.slice/user@1001.service/app.slice/run-u1.service", "/"] {
            #expect(ScratchNode.cgroupRoot(own: elsewhere, uid: Self.uid) == nil, "\(elsewhere)")
        }
        #expect(ScratchNode.cgroupRoot(own: nil, uid: Self.uid) == nil)
        // This run's own: a root exactly when its cgroup is one of those, and then its scope is `/`.
        #expect(ScratchNode.cgroupRoot == ScratchNode.cgroupRoot(own: ScratchNode.ownCgroup, uid: getuid()))
        #expect(ScratchNode.ownScope == (ScratchNode.cgroupRoot == nil ? ScratchNode.ownCgroup : "/"))
    }

    // MARK: A scratch node's test under a branch code runner

    /// The other test flag of a scratch node whose test the merge gate runs: `--test-runner-above`, for a run under a
    /// branch code runner. A server with `--node` refuses it, as it does every test flag (said at its start:
    /// `refused`), and takes nothing from it; it takes no value, so it names no process.
    @Test func theTestRunnerAboveIsRefusedUnderNode() throws {
        let base = ["vibeswitcher-server", "--host-connector", "3", "--host-socket", "/x/host.sock"]
        let node = try ServerArguments.parse(base + ["--node", "--node-root", "/x/b", ServerArguments.testRunnerAboveFlag]).get()
        #expect(node.refused == [ServerArguments.testRunnerAboveFlag] && !node.testRunnerAbove, "\(node)")
        let scratch = try ServerArguments.parse(base + ["--root", "/x", ServerArguments.testRunnerAboveFlag]).get()
        #expect(scratch.refused.isEmpty && scratch.testRunnerAbove, "\(scratch)")
        #expect(try !ServerArguments.parse(base + ["--root", "/x"]).get().testRunnerAbove)
        // A value is another argument, which no server knows.
        #expect(throws: ServerArguments.Usage.self) { try ServerArguments.parse(base + ["--root", "/x", ServerArguments.testRunnerAboveFlag + "=4000"]).get() }
    }

    /// Real processes, read from `/proc` as the server reads a sender: a runner R1, under it a process B standing for
    /// a scratch server (its own runners: R1, and whatever this test run is under), and under B a second runner R2
    /// with a command of its own.
    ///
    /// - The user's node (the flag dropped under `--node`: no runners left out): B and R2's command are both under a
    ///   runner, and refused as branch code.
    /// - A scratch server that has the flag leaves out the runners above itself, so a sender beside it (B) isn't under
    ///   one: the test process of a run under the gate's runner.
    /// - R2 is below the scratch node's root: its command is refused on that scratch server too, and so is anything
    ///   under a runner the server doesn't run under.
    @Test(NodeTraits.linuxOnly) func onlyTheRunnersAboveTheScratchServerItselfAreLeftOut() async throws {
        let wrapper = Platform.Tools.branchShell + ["-c", "\"$@\"; exit $?", "vibeswitcher-branch-code"]
        // R1 runs a shell that starts R2 (with its command) and becomes B.
        let arguments = wrapper + ["/bin/bash", "-c", "\"$@\" & exec /bin/sleep 600", "inner"] + wrapper + ["/bin/sleep", "601"]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let outer = process.processIdentifier
        defer {
            for link in ScratchNode.descendants(of: outer) { kill(link.pid, SIGKILL) }
            process.terminate()
        }
        func child(of pid: pid_t, running wanted: ([String]) -> Bool) -> pid_t? {
            Platform.Processes.children(pid).first { wanted(Platform.Processes.arguments($0)) }
        }
        let found = Locked<(server: pid_t, inner: pid_t, command: pid_t)?>(nil)
        try #require(await eventually(timeout: 60) {
            guard let server = child(of: outer, running: { $0 == ["/bin/sleep", "600"] }),
                  let inner = child(of: server, running: BranchCode.isRunner),
                  let command = child(of: inner, running: { $0 == ["/bin/sleep", "601"] }) else { return false }
            found.value = (server, inner, command)
            return true
        }, "the runners' processes never showed")
        let (server, inner, command) = try #require(found.value)

        // What a scratch server there reads of itself: R1, nearest first, then this run's own runners; never R2.
        let above = PeerFacts.runners(above: server)
        #expect(above.first?.pid == outer, "\(above)")
        #expect(!above.contains { $0.pid == inner })
        #expect(Array(above.dropFirst()) == PeerFacts.runners(above: getpid()), "\(above)")

        let rule = VoiceRule(mode: .weaker, scopes: [], uid: getuid(), says: "the test's")
        func judged(_ pid: pid_t, leavingOut runners: [PeerFacts.Ancestor]) -> Voice {
            Voice.judge(PeerFacts.read(pid: pid, runnersAbove: runners), live: LiveSessions(), rule: rule)
        }
        let branchCode = Voice.notUser("it runs under a branch code runner")
        // No runners left out (the user's node, and a scratch one without the flag): both refused.
        #expect(PeerFacts.read(pid: server).underRunner == true && PeerFacts.read(pid: command).underRunner == true)
        #expect(judged(server, leavingOut: []) == branchCode)
        #expect(judged(command, leavingOut: []) == branchCode)
        // The scratch server's own left out: a sender beside it is the user, one under R2 still isn't.
        #expect(PeerFacts.read(pid: server, runnersAbove: above).underRunner == false)
        #expect(judged(server, leavingOut: above) == .user)
        #expect(PeerFacts.read(pid: command, runnersAbove: above).underRunner == true)
        #expect(judged(command, leavingOut: above) == branchCode)
        // A runner is left out as that process only: its pid with another start is another process.
        let reused = above.map { PeerFacts.Ancestor(pid: $0.pid, startTicks: $0.startTicks + 1) }
        #expect(judged(server, leavingOut: reused) == branchCode)
        // R2's command reads R2 and then R1 as its own runners, nearest first.
        #expect(Array(PeerFacts.runners(above: command).map(\.pid).prefix(2)) == [inner, outer])
    }

    /// A scratch node tells its server so only where its test really runs under a runner: by the same reading of
    /// `/proc` the server makes of a sender. From a terminal, a worker's shell, on CI and on the Mac it says nothing.
    @Test func aScratchNodeSaysARunnerIsAboveOnlyWhenOneIs() {
        #expect(ScratchNode.runnerAbove == !PeerFacts.runners(above: getpid()).isEmpty)
        if !Platform.CodeIdentity.isAvailable {
            // The server's own read of this process, nothing left out: under a runner exactly then (where every
            // ancestor's arguments can be read at all: where one can't, no sender here is the user either way).
            if let under = PeerFacts.read(pid: getpid()).underRunner {
                #expect(under == ScratchNode.runnerAbove)
                // With this process's runners left out, as its scratch server leaves them out: under none.
                #expect(PeerFacts.read(pid: getpid(), runnersAbove: PeerFacts.runners(above: getpid())).underRunner == false)
            }
        } else {
            #expect(!ScratchNode.runnerAbove)
        }
    }

    /// The root and the runners reach the read of a sender from one place, the server's own arguments at its start:
    /// `ServerStart` hands `parsed.testCgroupRoot` (nil under `--node`) and, only with `parsed.testRunnerAbove` (false
    /// under `--node`), its own runners (`PeerFacts.runners(above: getpid())`) to the socket's server, which keeps
    /// both as constants and is the only caller that reads a sender with either. No file, request or environment
    /// variable names a root or a runner.
    @Test func theCgroupRootAndTheRunnersComeOnlyFromTheServersOwnStart() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var files: [String: Set<String>] = [:]
        var reads: [String] = []
        for folder in ["Sources/VibeNode", "Sources/VibeCore", "Sources/VibeHost", "Sources/VibePlatform", "Sources/vibeswitcher-server",
                       "Sources/vibeswitcher-cli", "Sources/vibeswitcher-host", "Sources/vibeswitcher-mcp", "Sources/vibeswitcher-hook"] {
            let base = repo.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in walker where file.pathExtension == "swift" {
                let text = ServerLintTests.code(try String(contentsOf: file, encoding: .utf8))
                for name in ["testCgroupRoot", "testCgroupRootFlag", "cgroupRoot", "rerooted(", "testRunnerAbove", "testRunnerAboveFlag",
                             "runnersAbove", "runners(above:"] where text.contains(name) {
                    files[name, default: []].insert(file.lastPathComponent)
                }
                for line in text.components(separatedBy: "\n")
                where line.contains("PeerFacts.read(") || line.contains("cgroupRoot: parsed") || line.contains("runners(above:") && !line.contains("func ") {
                    reads.append(file.lastPathComponent + ": " + line.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        // The flags and what they were parsed to: the arguments, and the start that hands them on.
        #expect(files["testCgroupRootFlag"] == ["ServerArguments.swift"], "\(files)")
        #expect(files["testRunnerAboveFlag"] == ["ServerArguments.swift"], "\(files)")
        #expect(files["testCgroupRoot"] == ["ServerArguments.swift", "ServerStart.swift"], "\(files)")
        #expect(files["testRunnerAbove"] == ["ServerArguments.swift", "ServerStart.swift"], "\(files)")
        // The root and the runners themselves: the start, the socket's server and the read. The re-read: the read alone.
        #expect(files["cgroupRoot"] == ["ServerArguments.swift", "ServerStart.swift", "NodeServer.swift", "PeerFacts.swift"], "\(files)")
        #expect(files["runnersAbove"] == ["ServerStart.swift", "NodeServer.swift", "PeerFacts.swift"], "\(files)")
        #expect(files["rerooted("] == ["PeerFacts.swift"], "\(files)")
        // The one call that reads runners: the start's, of the server itself (below).
        #expect(files["runners(above:"] == ["ServerStart.swift"], "\(files)")
        #expect(reads.sorted() == [
            // At the accept; then a request's sender, read again unless its kind is `anyone`'s (then as read at the accept).
            "NodeServer.swift: let facts = PeerFacts.read(pid: token.pid, token: token, cgroupRoot: cgroupRoot, runnersAbove: runnersAbove)",
            "NodeServer.swift: let facts = atAccept ?? PeerFacts.read(pid: sender.pid, token: sender, cgroupRoot: cgroupRoot, runnersAbove: runnersAbove)",
            "ServerStart.swift: clock: clock, cgroupRoot: parsed.testCgroupRoot, runnersAbove: runnersAbove,",
            // Of the server itself, and only with the flag.
            "ServerStart.swift: let runnersAbove = parsed.testRunnerAbove ? PeerFacts.runners(above: getpid()) : []",
        ], "\(reads)")
        // The socket's server keeps both as constants.
        let server = ServerLintTests.code(try String(contentsOf: repo.appendingPathComponent("Sources/VibeNode/Server/NodeServer.swift"), encoding: .utf8))
        #expect(server.contains("private let cgroupRoot: String?") && !server.contains("var cgroupRoot"))
        #expect(server.contains("private let runnersAbove: [PeerFacts.Ancestor]") && !server.contains("var runnersAbove"))
    }

    /// The rule is fixed once, at the server's start, from the server's own cgroup (`/proc/self`'s, by its own pid) and
    /// its own arguments: nothing a peer sends, no file under the node's root or `/run/user/<uid>`, and no request
    /// changes it afterwards.
    @Test func theRuleIsFixedOnceAtTheServersStartFromItsOwnCgroup() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var calls: [String] = []
        for folder in ["Sources/VibeNode", "Sources/vibeswitcher-server", "Sources/vibeswitcher-cli"] {
            let base = repo.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in walker where file.pathExtension == "swift" {
                let text = ServerLintTests.code(try String(contentsOf: file, encoding: .utf8))
                for line in text.components(separatedBy: "\n") where line.contains("VoiceRule.at(") {
                    calls.append(file.lastPathComponent + ": " + line.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        #expect(calls == ["ServerStart.swift: let rule = VoiceRule.at(start: Platform.Processes.cgroup(getpid()), testScopes: parsed.testUserScopes, usersNode: parsed.node)"], "\(calls)")
        // `Requests` keeps the rule it was given: a constant.
        let requests = ServerLintTests.code(try String(contentsOf: repo.appendingPathComponent("Sources/VibeNode/Server/Requests.swift"), encoding: .utf8))
        #expect(requests.contains("public let rule: VoiceRule"))
        #expect(!requests.contains("var rule"))
    }

    /// A session can make the server's own cgroup read fail (in the user manager's delegated subtree, a chain of
    /// cgroups whose path is past `PATH_MAX`: `/proc/<pid>/cgroup` then fails with ENAMETOOLONG; the host moved there,
    /// the server killed, and the host's restart of it inherits the path). That read failing must not choose the
    /// weaker rule: the rule is closed, every peer refused, and `status` says so.
    @Test func anUnreadOwnCgroupClosesTheRule() {
        for unread in [nil, [String]()] as [[String]?] {
            let closed = VoiceRule.at(start: unread, testScopes: nil, uid: Self.uid, cgroups: true)
            #expect(closed.mode == .closed && closed.scopes.isEmpty, "\(String(describing: unread)): \(closed)")
            #expect(closed.says.contains("closed") && closed.says.contains("couldn't be read"), "\(closed.says)")
            // The peer every other rule takes, and the escaped one the weaker rule's four lines pass, are refused.
            #expect(Self.judged(Self.peer(), rule: closed) == .notUser(VoiceRule.closedRefusal))
            #expect(Self.judged(Self.peer(cgroup: nil, terminal: .none), rule: closed) == .notUser(VoiceRule.closedRefusal))
        }
        // Where the system has cgroups (Linux), the server's own read decides it (the default): an unread cgroup there
        // is closed.
        if Platform.Processes.hasCgroups {
            #expect(VoiceRule.systemHasCgroups)
            #expect(VoiceRule.at(start: nil, testScopes: nil, uid: Self.uid).mode == .closed)
        }
        // A system with no cgroups at all (the Mac's scratch nodes) has no user manager to tell by: the weaker rule.
        #expect(VoiceRule.at(start: nil, testScopes: nil, uid: Self.uid, cgroups: false).mode == .weaker)
        // A scratch host's test scopes still give their cgroup rule.
        #expect(VoiceRule.at(start: nil, testScopes: ["/test.scope"], uid: Self.uid, cgroups: true).mode == .systemd)
    }

    /// The node on the Mac's design (2026-11-19), step 1: the user's server on a system with no cgroups (the Mac) has no
    /// rule that tells the user's voice yet, so it is on the closed rule, every peer refused with the unbuilt rule's
    /// reason; unbuilt is refused, never the weaker rule by default. A scratch server there keeps the weaker rule; on a
    /// system with cgroups (Linux) the flag changes nothing. Both arms are pure: they run on both systems.
    @Test func theUsersServerWithoutCgroupsIsClosedUntilItsRuleIsBuilt() {
        for start in [nil, ["0::/"], Self.hybrid("/init.scope")] as [[String]?] {
            let unbuilt = VoiceRule.at(start: start, testScopes: nil, uid: Self.uid, cgroups: false, usersNode: true)
            #expect(unbuilt.mode == .closed && unbuilt.scopes.isEmpty, "\(String(describing: start)): \(unbuilt)")
            #expect(unbuilt.says == NodeSystem.voiceUnbuilt && unbuilt.refusal == NodeSystem.voiceUnbuilt)
            #expect(Self.judged(Self.peer(), rule: unbuilt) == .notUser(NodeSystem.voiceUnbuilt))
            #expect(Self.judged(Self.peer(cgroup: nil), rule: unbuilt) == .notUser(NodeSystem.voiceUnbuilt))
            #expect(Voice.handsRefusal(Self.peer(cgroup: nil, terminal: .none), kind: "stop", rule: unbuilt) == nil, "judge refused it already")
            // A scratch server on the same system: the weaker rule, as before.
            #expect(VoiceRule.at(start: start, testScopes: nil, uid: Self.uid, cgroups: false).mode == .weaker)
        }
        // On a system with cgroups the user's server's rule is its cgroup's, as before.
        #expect(VoiceRule.at(start: Self.hybrid(Self.nodeUnit), testScopes: nil, uid: Self.uid, cgroups: true, usersNode: true) == Self.systemd)
        #expect(VoiceRule.at(start: Self.hybrid("/init.scope"), testScopes: nil, uid: Self.uid, cgroups: true, usersNode: true).mode == .weaker)
        #expect(VoiceRule.at(start: nil, testScopes: nil, uid: Self.uid, cgroups: true, usersNode: true).refusal == nil)
        // This system's default: closed on the Mac, the cgroup's rule on Linux.
        let here = VoiceRule.at(start: Platform.Processes.cgroup(getpid()), testScopes: nil, uid: Self.uid, usersNode: true)
        if Platform.Processes.hasCgroups {
            #expect(here.refusal == nil, "\(here)")
        } else {
            #expect(here.mode == .closed && here.refusal == NodeSystem.voiceUnbuilt, "\(here)")
        }
    }

    @Test func underTheWeakerRuleAStateChangeNeedsAControllingTerminal() {
        let weaker = VoiceRule.at(start: Self.hybrid("/init.scope"), testScopes: nil, uid: Self.uid)
        #expect(weaker.mode == .weaker)
        #expect(weaker.says.contains("a state change needs a controlling terminal"), "\(weaker.says)")
        // An escaped session's process: out of the host's tree, no terminal, no marker. The four lines pass it.
        let escaped = Self.peer(cgroup: nil, ancestry: [.init(pid: 900, startTicks: 5), .init(pid: 1, startTicks: 1)], terminal: .none)
        #expect(Self.judged(escaped, rule: weaker) == .user)
        // A state change from it is refused; with a terminal (no session's) it isn't.
        // A kind missing from `NodeWire.kinds` needs the user's voice (`Requests.handle`) and so changes state.
        for kind in ["stop", "lead", "answer", "hold", "tell", "config.accept", "base.accept", "base.keep", "hooks.install", "hooks.remove", "build.switch", "send", "set", "unlisted"] {
            let why = Voice.handsRefusal(escaped, kind: kind, rule: weaker)
            #expect(why?.contains("controlling terminal") == true, "\(kind): \(String(describing: why))")
            #expect(Voice.handsRefusal(Self.peer(cgroup: nil, terminal: .named("ttypts0")), kind: kind, rule: weaker) == nil, "\(kind)")
            #expect(Voice.handsRefusal(Self.peer(cgroup: nil, terminal: .unreadable), kind: kind, rule: weaker) != nil, "\(kind)")
        }
        // What changes nothing (no typed word), the reads and the lead's tool server's kinds aren't asked it.
        for kind in ["start", "config.held", "base.show", "status", "questions", "question.post"] {
            #expect(Voice.handsRefusal(escaped, kind: kind, rule: weaker) == nil, "\(kind)")
        }
        // Every user's-voice kind is one or the other: a kind added later changes state unless listed as not.
        #expect(NodeWire.kinds.filter { $0.value == .user }.keys.allSatisfy { NodeWire.changesState($0) != NodeWire.changesNothing.contains($0) })
        #expect(NodeWire.changesState("unlisted") && NodeWire.changesState("e9.later"))
        // The reads and the lead's tool server's kinds change nothing; a web client's (a draft, a terminal) change state.
        #expect(NodeWire.kinds.filter { $0.value == .anyone || $0.value == .leadToolServer }.keys.allSatisfy { !NodeWire.changesState($0) })
        #expect(NodeWire.kinds.filter { $0.value == .webDraft || $0.value == .webTerminal }.keys.allSatisfy { NodeWire.changesState($0) })
        // The cgroup rule doesn't ask it: there a peer with no terminal is the user's when its cgroup is a terminal's.
        #expect(Voice.handsRefusal(Self.peer(terminal: .none), kind: "stop", rule: Self.systemd) == nil)
    }
}
