import Foundation
import Testing
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
        #expect(Self.judged(Self.peer(cgroup: ["0::/user.slice/user-1000.slice/session-12.scope"])) == .user)
        // Another user's session scope isn't this user's.
        #expect(Self.refused(Self.judged(Self.peer(cgroup: ["0::/user.slice/user-1001.slice/session-3.scope"]))))
        // The scope list is data: each row says where it comes from.
        #expect(VoiceRule.terminalScopes.map(\.pattern) == ["/init.scope", "/user.slice/user-{uid}.slice/session-*.scope"])
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
        #expect(VoiceRule.at(start: nil, testScopes: nil, uid: Self.uid).mode == .weaker)
        // A scratch host's test scopes give the cgroup rule on those scopes alone.
        let test = VoiceRule.at(start: Self.hybrid("/init.scope"), testScopes: ["/test.scope"], uid: Self.uid)
        #expect(test.mode == .systemd && test.scopes.map(\.pattern) == ["/test.scope"])
        #expect(Self.judged(Self.peer(cgroup: ["0::/test.scope"]), rule: test) == .user)
        #expect(Self.refused(Self.judged(Self.peer(), rule: test)))
    }
}
