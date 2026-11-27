import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

// The node kinds the guarded track needs first (group G3 of v2-remaining): `update` (D1, D2), `journal.ack` (C9, N6) and
// `claude.autoupdate` (E8, N8). Each is the user's voice, recorded, never an item of `approve`'s batch, and the
// terminal's alone for every page (`.terminalOnly`) until the device keys track's slices 14 and 15. What runs here, on
// the Mac and with no host: who may send them (`Principal`, the voice rule, the Mac's closed rule and its Touch ID rule),
// their arguments (unknown, extra and malformed refused, nothing taken from a caller that names a path or a program),
// and each one's act on scratch seams: a scratch builds folder and a fake installer, no journal written, a scratch Claude
// config. The whole recorded request (the vault's record first, then the act) has no test here: it needs a scratch
// host's vault, which the Mac's runner has none of, and none is written for Linux yet.

/// A host that is never there.
private struct NoHost: HostDialer {
    func connect(queue: DispatchQueue, patience: TimeInterval) throws -> HostConnection { throw HostLink.Failure("no host in this test") }
}

@Suite(.timeLimit(.minutes(5)))
struct GuardedKindsTests {
    private let scratch = Scratch()
    static let kinds = ["update", "journal.ack", "claude.autoupdate"]
    static let commit = String(repeating: "a", count: 40)
    static let other = String(repeating: "b", count: 40)

    /// A `Requests` on `rule`, over a link with no host.
    private func requests(_ rule: VoiceRule = VoiceRule(mode: .weaker, scopes: [], uid: getuid(), says: "a test's")) -> Requests {
        let root = scratch.url("root")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let link = HostLink(dialer: NoHost(), root: root, queue: DispatchQueue(label: "guarded-kinds"))
        return Requests(link: link, sessions: nil, rule: rule, root: root, hostSocket: scratch.url("h.sock").path, commit: "test", hostPID: 1)
    }

    /// `kind` with `args` from `facts` through `handle`, as the server's socket gives it.
    private func ask(_ requests: Requests, _ kind: String, _ args: [String: NodeWire.Value]? = nil, from facts: PeerFacts) async -> NodeWire.Reply? {
        let reply = Locked<NodeWire.Reply?>(nil)
        let request = NodeWire.Request(id: "r1", kind: kind, args: args, action: UUID().uuidString.lowercased())
        requests.queue.async { requests.handle(request, from: facts) { answer in reply.mutate { $0 = answer } } }
        _ = await eventually(timeout: 60) { reply.value != nil }
        return reply.value
    }

    /// One of the act functions, called on `queue` as `act` calls it.
    private func act(_ requests: Requests, _ kind: String, _ args: [String: NodeWire.Value]? = nil,
                     _ call: @escaping (Requests, NodeWire.Request, @escaping (NodeWire.Reply) -> Void) -> Void) async -> NodeWire.Reply? {
        let reply = Locked<NodeWire.Reply?>(nil)
        let request = NodeWire.Request(id: "r1", kind: kind, args: args, action: UUID().uuidString.lowercased())
        requests.queue.async { call(requests, request) { answer in reply.mutate { $0 = answer } } }
        _ = await eventually(timeout: 60) { reply.value != nil }
        return reply.value
    }

    /// The user at a terminal, under the weaker rule (`CardWorld.user`'s shape, a controlling terminal of its own).
    static let user = PeerFacts(pid: 9_000_950, uid: getuid(), cgroup: nil, ancestry: [.init(pid: 9_000_950, startTicks: 5)],
                                terminal: .named("ttytest-g3"), sessionMarker: false, underRunner: false)

    /// Well-formed arguments for each kind.
    static func args(_ kind: String) -> [String: NodeWire.Value]? {
        switch kind {
        case "update": return ["commit": .string(commit)]
        case "claude.autoupdate": return ["on": .bool(false)]
        default: return nil
        }
    }

    // MARK: The table

    /// Each is the user's voice, changes state, is recorded before it acts, never in a batch, the terminal's alone for
    /// a page, typed, and taken by this server.
    @Test func eachIsTheUsersRecordedVoiceAndNeverInABatch() throws {
        for name in Self.kinds {
            let spec = try #require(KindSpec.spec(name), "\(name) isn't a kind")
            #expect(spec.sender == .user && spec.effect == .change && spec.servedBy == .requests, "\(name)")
            let recorded = try #require(spec.recorded, "\(name) isn't recorded")
            #expect(!recorded.batch && !recorded.carded, "\(name)")
            guard case .terminalOnly(let why) = spec.page else { Issue.record("\(name): \(spec.page)"); continue }
            #expect(why.contains("guarded change"), "\(name): \(why)")
            #expect(spec.typed?.kind == name && NodeWire.taken.contains(name) && Requests.recorded.contains(name), "\(name)")
        }
    }

    /// What a page is told of `journal.ack` matches what it does (the G3 review's N2): it records, the server writes no
    /// journal entry and clears no mark, and the marks stay until `status --ack` in a terminal.
    @Test func journalAcksReasonSaysTheMarksStay() throws {
        let spec = try #require(KindSpec.spec("journal.ack"))
        guard case .terminalOnly(let why) = spec.page else { Issue.record("\(spec.page)"); return }
        #expect(!why.contains("clears the marks"), "\(why)")
        #expect(why.contains("the marks stay until vibeswitcher status --ack in a terminal"), "\(why)")
    }

    // MARK: Who may send them

    /// A page is refused each of them, whatever its rights, an acting page's (`web_acts` on) too: with the terminal's
    /// reason, never as an unknown kind; none is in any page's `hello.kinds`.
    @Test func aPageIsRefusedThemWhateverItsRights() {
        for rights: LiveRights in [[], .read, .draft, [.read, .draft], [.read, .draft, .watch], [.read, .draft, .watch, .act], .act] {
            for terminals in [false, true] {
                let page = Principal.page(rights, terminals: terminals)
                for name in Self.kinds {
                    guard case .refused(let code, let why) = page.route(name) else { Issue.record("\(name) from \(rights): \(page.route(name))"); continue }
                    #expect(code == .voice, "\(name)")
                    if rights.contains(.act) {
                        #expect(why.contains("is the terminal's alone") && why.contains("guarded change"), "\(name): \(why)")
                    } else {
                        #expect(why.contains("is the user's voice"), "\(name): \(why)")
                    }
                    let reply = page.refusal(NodeWire.Request(id: "p", kind: name, args: Self.args(name), action: UUID().uuidString))
                    #expect(reply?.error?.code == NodeWire.Code.voice.rawValue, "\(name): \(String(describing: reply))")
                    #expect(!page.kinds.contains(name), "\(name) in hello.kinds for \(rights)")
                }
            }
        }
    }

    /// On the socket each is the user's voice, judged when asked.
    @Test func onTheSocketEachIsJudgedAsTheUsersVoice() {
        for name in Self.kinds { #expect(Principal.process(Self.user).route(name) == .usersVoice, "\(name)") }
    }

    /// A caller without the right the command line needs today is refused before anything is done: a session's
    /// process (its marker), another user's, one with no controlling terminal under the weaker rule, one from the
    /// node's own unit under the cgroup rule. Nothing installed, written or changed.
    @Test func aCallerWithoutTheRightIsRefusedAndNothingIsDone() async throws {
        let world = try UpdateWorld(scratch)
        let home = scratch.url("home-refused")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try #"{"model": "opus"}"#.write(to: home.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        var session = Self.user
        session.sessionMarker = true
        var another = Self.user
        another.uid = getuid() + 1
        var noTerminal = Self.user
        noTerminal.terminal = .none
        let unit = PeerFacts(pid: 9_000_951, uid: getuid(), cgroup: ["0::/user.slice/user-\(getuid()).slice/user@\(getuid()).service/app.slice/\(VoiceRule.nodeUnit)"],
                             ancestry: [.init(pid: 9_000_951, startTicks: 5)], terminal: .named("ttytest-g3"), sessionMarker: false, underRunner: false)
        let weaker = VoiceRule(mode: .weaker, scopes: [], uid: getuid(), says: "a test's")
        let cgroups = VoiceRule(mode: .systemd, scopes: VoiceRule.terminalScopes, uid: getuid(), says: "a test's")
        for (rule, facts) in [(weaker, session), (weaker, another), (weaker, noTerminal), (cgroups, unit)] {
            let requests = requests(rule)
            requests.home = home.path
            requests.installRoot = world.prefix
            requests.updateInstaller = .test(program: world.installer)
            for name in Self.kinds {
                let reply = try #require(await ask(requests, name, Self.args(name), from: facts))
                #expect(!reply.ok && reply.error?.code == NodeWire.Code.voice.rawValue, "\(name) from \(facts): \(reply)")
            }
        }
        #expect(!world.ran)
        #expect(try String(contentsOf: home.appendingPathComponent(".claude/settings.json"), encoding: .utf8) == #"{"model": "opus"}"#)
    }

    /// On the Mac the user's server is on the closed rule while `NodeSystem.approvalMeasured` is false: each is refused
    /// for the user too.
    @Test func theMacsClosedRuleRefusesThemToEveryone() async throws {
        #expect(NodeSystem.approvalMeasured == false)
        let rule = VoiceRule.at(start: nil, testScopes: nil, cgroups: false, usersNode: true)
        #expect(rule.mode == .closed)
        let requests = requests(rule)
        for name in Self.kinds {
            let reply = try #require(await ask(requests, name, Self.args(name), from: Self.user))
            #expect(!reply.ok && reply.error?.code == NodeWire.Code.voice.rawValue, "\(name): \(reply)")
        }
    }

    /// The Mac's Touch ID rule, once measured: no dialog names any of them yet (the guarded change's text is slices
    /// 14–15's), so each is refused with no dialog shown, the person approving everything.
    @Test func theMacsTouchIDRuleShowsNoDialogForThem() async throws {
        let person = ApprovalVoiceTests.Person(.approved)
        let requests = requests(VoiceRule(mode: .approval, scopes: [], uid: getuid(), says: VoiceRule.approvalSays))
        let pid: pid_t = 9_000_952
        requests.approval = ApprovalVoice(authenticator: person, commandLine: ApprovalVoiceTests.commandLine, runs: { token, code in
            code == ApprovalVoiceTests.commandLine && token.pid == pid
        }, hardened: { _ in true })
        requests.approvalLinkWelcomed = { true }
        let facts = PeerFacts(pid: pid, uid: getuid(), cgroup: nil, ancestry: [.init(pid: pid, startTicks: 5)], terminal: .named("ttytest-mac"),
                              sessionMarker: nil, underRunner: false)
        for name in Self.kinds {
            let done = Locked<NodeWire.Reply?>(nil)
            let request = NodeWire.Request(id: "m", kind: name, args: Self.args(name), action: UUID().uuidString.lowercased())
            requests.queue.async { requests.approvalJudgment(request, from: facts, token: ApprovalVoiceTests.token(pid)) { done.value = $0 } }
            _ = await eventually(timeout: 60) { done.value != nil }
            let reply = try #require(done.value, "\(name): no answer")
            #expect(!reply.ok && reply.error?.message.contains("has no dialog the Mac can show") == true, "\(name): \(reply)")
        }
        #expect(person.asked.isEmpty, "\(person.asked)")
    }

    // MARK: Their arguments

    /// Unknown, extra and malformed fields are refused `bad-args` before anything is recorded or done: no installer,
    /// builds folder, scope, program, home or path is ever taken from a request.
    @Test func unknownExtraAndMalformedFieldsAreRefused() async throws {
        let requests = requests()
        let extra: [String: [String: NodeWire.Value]] = [
            "update": ["commit": .string(Self.commit), "installer": .string("/bin/sh")],
            "journal.ack": ["action": .string("x")],
            "claude.autoupdate": ["on": .bool(false), "home": .string("/")],
        ]
        for (name, args) in extra {
            let reply = RequestArguments.refusal(NodeWire.Request(id: "x", kind: name, args: args))
            #expect(reply?.error?.code == NodeWire.Code.badArgs.rawValue, "\(name): \(String(describing: reply))")
            let asked = try #require(await ask(requests, name, args, from: Self.user))
            #expect(asked.error?.code == NodeWire.Code.badArgs.rawValue, "\(name): \(asked)")
        }
        for key in ["prefix", "installRoot", "scope", "program", "script", "path", "own"] {
            let reply = RequestArguments.refusal(NodeWire.Request(id: "x", kind: "update", args: ["commit": .string(Self.commit), key: .string("/somewhere/else")]))
            #expect(reply?.error?.code == NodeWire.Code.badArgs.rawValue, "\(key)")
        }
        #expect(RequestArguments.taken["update"] == ["commit", "rollback"])
        #expect(RequestArguments.taken["journal.ack"] == [])
        #expect(RequestArguments.taken["claude.autoupdate"] == ["on"])
        let malformed: [(String, [String: NodeWire.Value])] = [
            ("update", ["commit": .int(5)]), ("update", ["commit": .string(Self.commit), "rollback": .string("yes")]),
            ("claude.autoupdate", ["on": .string("false")]),
        ]
        for (name, args) in malformed {
            let reply = RequestArguments.formRefusal(NodeWire.Request(id: "x", kind: name, args: args))
            #expect(reply?.error?.code == NodeWire.Code.badArgs.rawValue, "\(name) \(args): \(String(describing: reply))")
        }
        // Well-formed but not enough: no commit, a commit that isn't one, no `on`.
        for args: [String: NodeWire.Value]? in [nil, ["commit": .string("HEAD")], ["commit": .string(String(Self.commit.prefix(12)))], ["rollback": .bool(true)]] {
            let reply = await act(requests, "update", args) { $0.update($1, reply: $2) }
            #expect(reply?.error?.code == NodeWire.Code.badArgs.rawValue, "\(String(describing: args)): \(String(describing: reply))")
        }
        let none = await act(requests, "claude.autoupdate", nil) { $0.claudeAutoUpdate($1, reply: $2) }
        #expect(none?.error?.code == NodeWire.Code.badArgs.rawValue, "\(String(describing: none))")
    }

    // MARK: update

    /// A scratch builds folder (an `installs` record and the running build's folder) and a fake installer that makes
    /// the commit's folder and its `installs` line, noting that it ran.
    struct UpdateWorld {
        var prefix: String
        var installer: String
        var ranFile: String
        var ran: Bool { FileManager.default.fileExists(atPath: ranFile) }

        init(_ scratch: Scratch, exit: Int = 0) throws {
            let base = scratch.url("update-world")
            prefix = base.appendingPathComponent("builds").path
            try FileManager.default.createDirectory(atPath: prefix + "/" + GuardedKindsTests.other, withIntermediateDirectories: true)
            try "\(GuardedKindsTests.other) 2026-11-26T00:00:00Z\n".write(toFile: prefix + "/installs", atomically: true, encoding: .utf8)
            ranFile = base.appendingPathComponent("installer-ran").path
            installer = base.appendingPathComponent("fake-install-node").path
            let script = "#!/bin/sh\necho \"$1 $2\" > '\(ranFile)'\nmkdir -p \"$2/$1/bin\"\necho \"$1 2026-11-27T00:00:00Z\" >> \"$2/installs\"\nexit \(exit)\n"
            try writeClosedOnExec(script, to: URL(fileURLWithPath: installer), mode: 0o700)
        }
    }

    private func plan(_ world: UpdateWorld, installer: UpdateInstall.Installer?, running: String? = GuardedKindsTests.other, blockers: [String] = [],
                      rollbackTarget: String? = nil, held: StartRefusal? = nil) -> UpdateRequest {
        UpdateRequest(installRoot: world.prefix, home: scratch.url("update-home").path, installer: installer, running: running, blockers: blockers,
                      rollbackTarget: rollbackTarget, held: { held }, say: { _ in })
    }

    /// The happy path: the fake installer run once with the commit and the builds folder, through `UpdateInstall.run`
    /// (the command line's install step), what it left seen for the switch's seal, and the switch's handover said with
    /// what is still owed.
    @Test func anUpdateInstallsThroughTheCommandLinesStepThenSwitches() throws {
        let world = try UpdateWorld(scratch)
        let before = SwitchSeal.listingLines(world.prefix)
        let planned = plan(world, installer: .test(program: world.installer)).plan(.init(commit: Self.commit))
        guard case .switchTo(let commit, let seen, let installed) = planned else { Issue.record("\(planned)"); return }
        #expect(commit == Self.commit && installed)
        #expect(try String(contentsOfFile: world.ranFile, encoding: .utf8) == "\(Self.commit) \(world.prefix)\n")
        #expect(seen?.beforeListing == before && seen?.after == SwitchSeal.listingHash(lines: SwitchSeal.listingLines(world.prefix)), "\(String(describing: seen))")
        var switched = WireKinds.BuildSwitch.Result(outcome: "handed-over", commit: Self.commit, said: "handed over")
        switched.from = Self.other
        let result = UpdateRequest.result(switched, installed: true)
        #expect(result.outcome == "handed-over" && result.installed == true && result.from == Self.other)
        #expect(result.owed?.count == 2 && result.owed?.first?.contains("vibeswitcher switch \(Self.commit)") == true, "\(String(describing: result.owed))")
        #expect(UpdateRequest.result(.init(outcome: "already", commit: Self.commit, said: "already"), installed: false).owed == nil)
    }

    /// A rollback to the installs record's target switches with nothing installed; to any other commit it is refused.
    @Test func aRollbackSwitchesOnlyToTheRecordsTargetAndInstallsNothing() throws {
        let world = try UpdateWorld(scratch)
        let back = plan(world, installer: .test(program: world.installer), running: Self.commit, rollbackTarget: Self.other)
        #expect(back.plan(.init(commit: Self.other, rollback: true)) == .switchTo(commit: Self.other, seen: nil, installed: false))
        let wrong = String(repeating: "c", count: 40)
        guard case .refused(.refused, let why) = back.plan(.init(commit: wrong, rollback: true)) else { Issue.record("not refused"); return }
        #expect(why.contains("isn't the build to roll back to"), "\(why)")
        #expect(!world.ran)
    }

    /// Each refusal comes before the installer runs: a live worker (the rule on switches), the builds folder held, no
    /// installer on this server; the running build is `already`; a failed install switches nothing and leaves no folder.
    @Test func anUpdateRefusedInstallsNothing() throws {
        let world = try UpdateWorld(scratch)
        let installer = UpdateInstall.Installer.test(program: world.installer)
        let cases: [(UpdateRequest, String)] = [
            (plan(world, installer: installer, blockers: ["a worker (task-x) runs"]), "can't run now"),
            (plan(world, installer: installer, held: StartRefusal("the builds folder is held")), "the builds folder is held"),
            (plan(world, installer: nil), "runs no install for update"),
        ]
        for (request, said) in cases {
            guard case .refused(.refused, let why) = request.plan(.init(commit: Self.commit)) else { Issue.record("\(said): not refused"); continue }
            #expect(why.contains(said), "\(why)")
        }
        #expect(!world.ran)
        guard case .already(let already) = plan(world, installer: installer, running: Self.commit).plan(.init(commit: Self.commit)) else {
            Issue.record("not already"); return
        }
        #expect(already.outcome == "already" && already.installed == false)
        #expect(!world.ran)
        let failing = try UpdateWorld(scratch, exit: 3)
        guard case .refused(.refused, let why) = plan(failing, installer: .test(program: failing.installer)).plan(.init(commit: Self.commit)) else {
            Issue.record("a failed install not refused"); return
        }
        #expect(why.contains("failed (exit 3") && why.contains("the folder it made is removed"), "\(why)")
        #expect(!FileManager.default.fileExists(atPath: failing.prefix + "/" + Self.commit))
    }

    /// The builds folder read before the vault's look and again after it, as the command line reads it: a change made
    /// while the vault looked (a rewritten install script) refuses the update, and nothing is run (the blind check's 1).
    @Test func aBuildsFolderChangedDuringTheVaultsLookRefusesTheUpdate() throws {
        let world = try UpdateWorld(scratch)
        let prefix = world.prefix
        var request = plan(world, installer: .test(program: world.installer))
        request.held = {
            try? "rewritten\n".write(toFile: prefix + "/" + GuardedKindsTests.other + "/install-node.sh", atomically: false, encoding: .utf8)
            return nil
        }
        guard case .refused(.refused, let why) = request.plan(.init(commit: Self.commit)) else { Issue.record("not refused"); return }
        #expect(why.contains("a change you haven't accepted"), "\(why)")
        #expect(!world.ran)
    }

    /// The server's image proves its own build as the command line's does, by its own name (`vibeswitcher-server`):
    /// taken past the layout check where the command line's name would be refused (the advisor's check of G3: with the
    /// command line's name alone, a real node's server never had an installer).
    @Test func theServersOwnImageIsLookedForByItsName() throws {
        let prefix = scratch.url("server-image")
        let bin = prefix.appendingPathComponent(Self.commit + "/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let server = bin.appendingPathComponent(UpdateInstall.serverProgram)
        try writeClosedOnExec("#!/bin/sh\n", to: server, mode: 0o700)
        guard case .failure(let asCommandLine) = NodeFolders.installedBuild(executable: server.path, prefix: prefix.path) else { Issue.record("taken"); return }
        #expect(asCommandLine.text.contains("not <prefix>/<commit>/bin/"), "\(asCommandLine.text)")
        let asServer = NodeFolders.installedBuild(executable: server.path, prefix: prefix.path, program: UpdateInstall.serverProgram)
        if case .failure(let refused) = asServer { #expect(!refused.text.contains("not <prefix>/<commit>/bin/"), "\(refused.text)") }
    }

    /// No build the host runs (its notes name none): refused, nothing installed, as the command line refuses it.
    @Test func anUpdateWithNoRunningBuildIsRefused() throws {
        let world = try UpdateWorld(scratch)
        guard case .refused(.refused, let why) = plan(world, installer: .test(program: world.installer), running: nil).plan(.init(commit: Self.commit)) else {
            Issue.record("not refused"); return
        }
        #expect(why.contains("name no build"), "\(why)")
        #expect(!world.ran)
    }

    /// The server's look of the builds folder is the command line's too (`config held`, the engine's look): when it can't
    /// be had (no engine, or a look that fails), the update is refused, never let through (the advisor's check of G3).
    @Test func theServersHeldLookFailsClosed() async throws {
        let requests = requests()
        let home = scratch.url("held-home").path
        #expect(requests.updateHeld(home: home)() != nil, "no engine: let through")
        let root = scratch.url("held-root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        requests.engine = LeadEngine(root: root, nodeRoot: nil, link: requests.link, clock: nil)
        let held = Locked<StartRefusal?>(nil)
        let done = Locked(false)
        DispatchQueue.global().async {
            held.value = requests.updateHeld(home: home)()
            done.value = true
        }
        _ = await eventually(timeout: 120) { done.value }
        #expect(done.value && held.value != nil, "a look with no vault let the update through")
    }

    /// The server's act refuses before any plan without an install root, and takes its installer from itself alone.
    @Test func theServersActNeedsItsOwnInstallRoot() async throws {
        let requests = requests()
        let reply = await act(requests, "update", ["commit": .string(Self.commit)]) { $0.update($1, reply: $2) }
        #expect(reply?.error?.code == NodeWire.Code.refused.rawValue && reply?.error?.message.contains("no install root") == true, "\(String(describing: reply))")
        #expect(requests.updateInstaller == nil, "a server installs nothing unless its start names an installer")
    }

    // MARK: journal.ack

    /// The ack's record is the vault's record of the `journal.ack` action (`voiced` writes it before the act): the act
    /// writes no journal entry, and its reply says the marks stay until slices 14–15 change the reader.
    @Test func theServersAckIsTheVaultsRecordAndWritesNoJournalEntry() async throws {
        let requests = requests()
        let reply = try #require(await act(requests, "journal.ack") { $0.journalAck($1, reply: $2) })
        let result = try #require(try? (reply.result ?? .null).wire(WireKinds.JournalAck.Result.self), "\(reply)")
        #expect(result.recorded == "vault" && result.counts == false && result.said == JournalAck.serverSaid, "\(result)")
        #expect(JournalAck.serverSaid.contains("vibeswitcher status --ack"))
    }

    /// Why the server never writes the ack's journal entry (the blind check's 2): written from the node's unit, today's
    /// reader doesn't count it, and `marks` says it came from somewhere not a terminal's, a line no ack clears. The same
    /// entry from a terminal's scope counts and marks nothing: the command line's (`status --ack`) stays the one that
    /// clears the marks.
    @Test func anAckEntryFromTheNodesUnitWouldBeAFalseAlarm() throws {
        let action = UUID().uuidString.lowercased()
        var fields = Dictionary(JournalAck.entry(action: action).map { ($0.name, $0.value) }, uniquingKeysWith: { $1 })
        fields["_UID"] = String(getuid())
        fields["__REALTIME_TIMESTAMP"] = String(Int(Date().timeIntervalSince1970 * 1_000_000))
        var unit = fields
        unit["_SYSTEMD_CGROUP"] = "/user.slice/user-\(getuid()).slice/user@\(getuid()).service/app.slice/\(VoiceRule.nodeUnit)"
        var terminal = fields
        terminal["_SYSTEMD_CGROUP"] = "/init.scope"
        let rule = VoiceRule(mode: .systemd, scopes: VoiceRule.terminalScopes, uid: getuid(), says: "a test's")
        let event = NodeJournal.Event(kind: .start, at: Date(timeIntervalSince1970: 1_000))
        #expect(!NodeJournal.acknowledged(event, entries: [JournalEntry(unit)], rule: rule))
        #expect(NodeJournal.marks(accepted: [], entries: [JournalEntry(unit)], rule: rule).count == 1)
        #expect(NodeJournal.acknowledged(event, entries: [JournalEntry(terminal)], rule: rule))
        #expect(NodeJournal.marks(accepted: [], entries: [JournalEntry(terminal)], rule: rule).isEmpty)
    }

    // MARK: claude.autoupdate

    /// Off writes `DISABLE_AUTOUPDATER=1` into Claude Code's settings' `env`, every other byte kept; on takes it out
    /// (and `env` with it when nothing else is there); asked again, nothing is written. Each write is the app's
    /// (`appWrite`) of that one file.
    @Test func theSwitchWritesOnlyTheVariableInClaudesSettings() throws {
        let home = scratch.url("claude-home")
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "{\n  \"model\": \"opus\",\n  \"effort\": 0.1,\n  \"hooks\": {\"Stop\": []}\n}\n"
        try original.write(to: settings, atomically: true, encoding: .utf8)
        let written = Locked<[[String]]>([])
        let appWrite: ([String], () throws -> Void) throws -> Void = { paths, write in
            written.mutate { $0.append(paths) }
            try write()
        }
        #expect(ClaudeAutoUpdate.isOn(home: home.path) == true)
        #expect(try ClaudeAutoUpdate.set(on: false, home: home.path, appWrite: appWrite).get() == true)
        let off = try String(contentsOf: settings, encoding: .utf8)
        #expect(off.hasPrefix("{\n  \"model\": \"opus\",\n  \"effort\": 0.1,\n  \"hooks\": {\"Stop\": []}"), "\(off)")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(off.utf8)) as? [String: Any])
        #expect((object["env"] as? [String: String]) == ["DISABLE_AUTOUPDATER": "1"], "\(off)")
        #expect(ClaudeAutoUpdate.isOn(home: home.path) == false)
        #expect(try ClaudeAutoUpdate.set(on: false, home: home.path, appWrite: appWrite).get() == false)
        #expect(try ClaudeAutoUpdate.set(on: true, home: home.path, appWrite: appWrite).get() == true)
        #expect(try String(contentsOf: settings, encoding: .utf8) == original)
        #expect(written.value == [[settings.path], [settings.path]], "\(written.value)")
    }

    /// Settings that aren't an object, or whose `env` isn't one: refused, the file left as it was, nothing written.
    @Test func theSwitchRefusesSettingsItCantReadAndChangesNothing() throws {
        let home = scratch.url("claude-bad")
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        for text in ["[1, 2]", "{\"env\": \"DISABLE_AUTOUPDATER=1\"}", "{not json"] {
            try text.write(to: settings, atomically: true, encoding: .utf8)
            let called = Locked(false)
            let set = ClaudeAutoUpdate.set(on: false, home: home.path, appWrite: { _, write in called.value = true; try write() })
            guard case .failure = set else { Issue.record("\(text): not refused"); continue }
            #expect(!called.value && (try? String(contentsOf: settings, encoding: .utf8)) == text, "\(text)")
        }
    }

    /// The server's act, in its own home: the switch turned off and on again there.
    @Test func theServersActSwitchesItInItsOwnHome() async throws {
        let home = scratch.url("claude-server")
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}\n".write(to: settings, atomically: true, encoding: .utf8)
        let requests = requests()
        requests.home = home.path
        let reply = try #require(await act(requests, "claude.autoupdate", ["on": .bool(false)]) { $0.claudeAutoUpdate($1, reply: $2) })
        let result = try #require(try? (reply.result ?? .null).wire(WireKinds.ClaudeAutoUpdateSwitch.Result.self), "\(reply)")
        #expect(result.on == false && result.changed == true && result.config == settings.path, "\(result)")
        #expect(ClaudeAutoUpdate.isOn(home: home.path) == false)
    }
}
