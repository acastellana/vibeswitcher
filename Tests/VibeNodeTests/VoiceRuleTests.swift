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
        #expect(calls == ["ServerStart.swift: let rule = VoiceRule.at(start: Platform.Processes.cgroup(getpid()), testScopes: parsed.testUserScopes)"], "\(calls)")
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

    @Test func underTheWeakerRuleAStateChangeNeedsAControllingTerminal() {
        let weaker = VoiceRule.at(start: Self.hybrid("/init.scope"), testScopes: nil, uid: Self.uid)
        #expect(weaker.mode == .weaker)
        #expect(weaker.says.contains("a state change needs a controlling terminal"), "\(weaker.says)")
        // An escaped session's process: out of the host's tree, no terminal, no marker. The four lines pass it.
        let escaped = Self.peer(cgroup: nil, ancestry: [.init(pid: 900, startTicks: 5), .init(pid: 1, startTicks: 1)], terminal: .none)
        #expect(Self.judged(escaped, rule: weaker) == .user)
        // A state change from it is refused; with a terminal (no session's) it isn't.
        // A kind missing from `NodeWire.kinds` needs the user's voice (`Requests.handle`) and so changes state.
        for kind in ["stop", "lead", "answer", "hold", "config.accept", "base.accept", "base.keep", "hooks.install", "hooks.remove", "build.switch", "unlisted"] {
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
        #expect(NodeWire.kinds.filter { $0.value != .user }.keys.allSatisfy { !NodeWire.changesState($0) })
        // The cgroup rule doesn't ask it: there a peer with no terminal is the user's when its cgroup is a terminal's.
        #expect(Voice.handsRefusal(Self.peer(terminal: .none), kind: "stop", rule: Self.systemd) == nil)
    }
}
