import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost
@testable import VibeNode

/// `switch` and `rollback` between installed builds (the start plan's S8a to S8c; the security architecture document's
/// S8, the rule on switches, and S9). S8a's cases: the plan the server makes of a switch (`SwitchPlan`, the app's
/// `HostClientPlanTests`, port-map row 99), the rollback's target from `<prefix>/installs`, the confirmations
/// (`NodeTexts.switch`, `rollback`; the app's `HostRestartTests`' first case, row 100), and the command line's
/// follow-up after the host handed over (`SwitchFollowUp`), driven in process on a unit `NodeUnit` wrote, a scratch
/// prefix and a recording `systemctl`. The plan and the texts are pure (the Mac runs them); the follow-up's cases are
/// Linux's.
///
/// S8b's cases: `build.switch` in the server (`SwitchRequest`). Its outcome (the app's `HostClientHandoverTests`, row
/// 97) is pure, and its waits and who answered run against a stand-in host (`StubHost`, as the app's `FakeHost`); the
/// rule on switches, the probe's wait (the app's `HostClientSlowProbeTests`, row 99) and a refused rollback run on a
/// scratch node switching between two installed builds (`ScratchBuilds`).
///
/// S8c's cases: `switch` and `rollback` from the built command line on such a node, on a pty of its own (the code
/// typed), or with no terminal; the builds the host, the server, a running tool server and the ones started after name;
/// and the follow-up of a node started detached (`SwitchFollowUp.applyDetached`), in process.
@Suite
struct SwitchTests {
    private let scratch = Scratch()

    static let a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    static let b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    static let c = "0123456789abcdef0123456789abcdef01234567"

    // MARK: The plan (the app's HostClientPlanTests, row 99)

    /// The app's `theBundledBuildIsUsed` and `noRestartIsOfferedWithoutAnOutdatedHost`: the build that runs is the one
    /// asked for, so nothing is switched (asked of a host already on it, with live teams or none).
    /// The real node's switch of 2026-11-25: mid-wait, the outgoing server's /proc entry was read as it exited ("whether
    /// … is dumpable can't be told"), and that ended the switch before its follow-up. A stand-in: the old server answers,
    /// then exits mid-poll (its listener gone, its facts unreadable), then the new one answers. A listener gone or
    /// unreadable is no answer (`NodeCheck.unsettled`); only one whose facts were read and fail is a refusal, and even
    /// then the wait ends with a line and the follow-up runs.
    @Test func theOutgoingServerExitingMidPollIsNoAnswer() {
        let unit = ["0::/user.slice/user-1000.slice/user@1000.service/app.slice/vibeswitcher-node.service"]
        let good = NodeCheck.Listener(pid: 50, dumpable: false, parent: 40, cgroup: unit, session: 40)
        var exiting = good
        exiting.dumpable = nil
        #expect(NodeCheck.unsettled(exiting, alive: true, mode: .node), "a fact unreadable")
        #expect(NodeCheck.unsettled(good, alive: false, mode: .node), "gone")
        var noCgroup = good
        noCgroup.cgroup = nil
        #expect(NodeCheck.unsettled(noCgroup, alive: true, mode: .node) && !NodeCheck.unsettled(noCgroup, alive: true, mode: .scratch(root: "/srv/x")))
        var dumpable = good
        dumpable.dumpable = true
        #expect(!NodeCheck.unsettled(dumpable, alive: true, mode: .node), "read, and failing: a refusal")
        var stranger = good
        stranger.parent = 1
        #expect(!NodeCheck.unsettled(stranger, alive: true, mode: .node))

        // The poll, through the same rules the command line's look applies (`SwitchCommand.lookAtServer`).
        let target = String(repeating: "c", count: 40)
        func look(_ listener: NodeCheck.Listener, alive: Bool, hello: (Int32, String)) -> SwitchSettle.Look {
            guard let why = NodeCheck.refusal(listener, mode: .node, expectedParent: 40, parentSession: 40) else { return .server(pid: hello.0, commit: hello.1) }
            return NodeCheck.unsettled(listener, alive: alive, mode: .node) ? .notYet(why) : .refused(why)
        }
        var replaced = good
        replaced.pid = 51
        let looks = [look(good, alive: true, hello: (50, Self.a)), look(exiting, alive: false, hello: (50, Self.a)),
                     look(replaced, alive: true, hello: (51, target))]
        var index = 0
        let clock = Date(timeIntervalSince1970: 1_000)
        let waited = SwitchSettle.waitForServer(before: 50, target: target, due: true, wait: 120, look: {
            defer { index += 1 }
            return looks[min(index, looks.count - 1)]
        }, now: { clock }, pause: {})
        #expect(waited == .answered(pid: 51, commit: target) && index == 3, "\(waited)")

        // Never settling: a line once the wait is past; a listener that fails the check: a line at once.
        var seconds: TimeInterval = 0
        let slow = SwitchSettle.waitForServer(before: 50, target: target, due: true, wait: 5, look: { look(exiting, alive: false, hello: (50, Self.a)) },
                                              now: { clock.addingTimeInterval(seconds) }, pause: { seconds += 1 })
        guard case .slow(let line) = slow else { Issue.record("\(slow)"); return }
        #expect(line.contains("handed over to \(target)") && line.contains("dumpable can't be told"), "\(line)")
        let refused = SwitchSettle.waitForServer(before: 50, target: target, due: true, wait: 120, look: { look(dumpable, alive: true, hello: (50, Self.a)) },
                                                 now: { clock }, pause: {})
        guard case .refused(let said) = refused else { Issue.record("\(refused)"); return }
        #expect(said.contains("fails the node's check") && said.contains("the follow-up checks the host again"), "\(said)")
    }

    /// What `vs switch` waits for once handed over (`SwitchSettle`): a replacement is due only when the two builds'
    /// records give their servers other bytes; unknown when a record can't be read (not waited for); the server that
    /// stays is the target's under another pid; a page's listener only when it held a token, on the same port.
    @Test(NodeTraits.linuxOnly) func aSwitchWaitsForTheServerThatStaysAndAPagesListener() throws {
        let builds = scratch.url("builds")
        try ScratchBuilds.install(commit: Self.a, into: builds)
        try ScratchBuilds.install(commit: Self.b, into: builds)
        var bytes = try Data(contentsOf: builtProducts.appendingPathComponent(BuildInfo.server))
        bytes.append(0)
        let padded = scratch.url("padded-server")
        try bytes.write(to: padded)
        let c = String(repeating: "c", count: 40)
        try ScratchBuilds.install(commit: c, into: builds, replacing: [BuildInfo.server: padded.path])
        #expect(SwitchSettle.serverDue(installRoot: builds.path, running: Self.a, target: Self.b) == false)
        #expect(SwitchSettle.serverDue(installRoot: builds.path, running: Self.a, target: c) == true)
        #expect(SwitchSettle.serverDue(installRoot: builds.path, running: "unknown", target: c) == nil)
        #expect(SwitchSettle.serverDue(installRoot: builds.path, running: String(repeating: "d", count: 40), target: c) == nil)
        #expect(SwitchSettle.serverDue(installRoot: nil, running: Self.a, target: c) == nil)

        #expect(!SwitchSettle.serverSettled(pid: 10, commit: Self.a, before: 10, target: c, due: true))
        #expect(!SwitchSettle.serverSettled(pid: 11, commit: Self.a, before: 10, target: c, due: true), "a server restarted on the old build")
        #expect(SwitchSettle.serverSettled(pid: 11, commit: c, before: 10, target: c, due: true))
        #expect(SwitchSettle.serverSettled(pid: 10, commit: Self.a, before: 10, target: Self.b, due: false))
        #expect(SwitchSettle.serverSettled(pid: 10, commit: Self.a, before: 10, target: c, due: nil))

        let paired = SwitchSettle.Web(.object(["state": .string("listening"), "port": .int(7311), "tokens": .int(1), "connections": .int(0)]))
        let codeOnly = SwitchSettle.Web(.object(["state": .string("listening"), "port": .int(7311), "tokens": .int(0)]))
        #expect(paired?.awaited == true && codeOnly?.awaited == false && SwitchSettle.Web(nil) == nil)
        #expect(SwitchSettle.webSettled(before: codeOnly, now: nil))
        #expect(!SwitchSettle.webSettled(before: paired, now: nil))
        #expect(!SwitchSettle.webSettled(before: paired, now: SwitchSettle.Web(listening: false, port: nil, tokens: 1)))
        #expect(!SwitchSettle.webSettled(before: paired, now: SwitchSettle.Web(listening: true, port: 7312, tokens: 1)))
        #expect(SwitchSettle.webSettled(before: paired, now: SwitchSettle.Web(listening: true, port: 7311, tokens: 1)))
    }

    @Test func theRunningCommitIsAlreadyRunning() {
        #expect(SwitchPlan.plan(running: Self.a, target: Self.a, installed: [Self.a, Self.b], live: []) == .already)
        #expect(SwitchPlan.plan(running: Self.a, target: Self.a, installed: [Self.a], live: [.lead, .worker, .verifier]) == .already)
    }

    /// A commit with no folder in the install root is not switched to: `install-node.sh` lays it out first.
    @Test func aCommitNotInstalledIsNotSwitchedTo() {
        #expect(SwitchPlan.plan(running: Self.a, target: Self.b, installed: [Self.a], live: []) == .notInstalled)
        #expect(SwitchPlan.plan(running: Self.a, target: Self.b, installed: [], live: []) == .notInstalled)
        #expect(SwitchPlan.plan(running: nil, target: Self.b, installed: [Self.a, Self.c], live: []) == .notInstalled)
    }

    /// Only 40 lowercase hex digits name a commit: a path (`../x`), a short hash and an uppercase one never reach the
    /// install root, even when a folder of that name is listed there.
    @Test func aTargetThatIsntACommitIsRefused() {
        for target in ["../x", "aaaaaaa", Self.b.uppercased(), "", Self.b + "b", "/" + Self.b, Self.b.dropLast() + "g", Self.b.dropLast() + "/"] {
            #expect(SwitchPlan.plan(running: Self.a, target: String(target), installed: [Self.a, Self.b, String(target)], live: []) == .badCommit,
                    "\(target)")
        }
        // Checked before whether it runs already.
        #expect(SwitchPlan.plan(running: "../x", target: "../x", installed: ["../x"], live: []) == .badCommit)
    }

    /// The rule on switches (S8, ST-D15; the app's `anOlderHostKeepsItsSessionsUntilTheyEnd`, its "kept until they
    /// end" now the user's to wait for): while a worker or a verifier is live a switch is refused, naming which.
    @Test func aSwitchWhileWorkersOrVerifiersAreLiveIsRefused() {
        #expect(SwitchPlan.plan(running: Self.a, target: Self.b, installed: [Self.a, Self.b], live: [.lead, .worker]) == .refusedWhileTeamsWork([.worker]))
        #expect(SwitchPlan.plan(running: Self.a, target: Self.b, installed: [Self.a, Self.b], live: [.verifier]) == .refusedWhileTeamsWork([.verifier]))
        #expect(SwitchPlan.plan(running: Self.a, target: Self.b, installed: [Self.a, Self.b], live: [.worker, .lead, .verifier, .worker])
                == .refusedWhileTeamsWork([.worker, .verifier, .worker]))
        // A commit not installed is said first: there is nothing to wait for.
        #expect(SwitchPlan.plan(running: Self.a, target: Self.b, installed: [Self.a], live: [.worker]) == .notInstalled)
    }

    /// The app's `anEmptyOutdatedHostIsReplaced`, `anOutdatedHostWithSessionsHandsOverWhenItCan` and
    /// `aRestartOfACompatibleHostWithSessionsReplacesItUnlessItCanHandOver`: on the node every switch is a handover,
    /// with no session live or only leads. The node never replaces its host to switch (the app's `replace` and
    /// `endAndReplace` are not needed: every node host hands over, and `stop` is how the user ends the sessions).
    @Test func aSwitchWithNoLiveSessionOrOnlyLeadsHandsOver() {
        #expect(SwitchPlan.plan(running: Self.a, target: Self.b, installed: [Self.a, Self.b], live: []) == .handOver(Self.b))
        #expect(SwitchPlan.plan(running: Self.a, target: Self.b, installed: [Self.a, Self.b], live: [.lead, .lead]) == .handOver(Self.b))
        // A running build the server couldn't tell (no build in the host's notes) isn't the target.
        #expect(SwitchPlan.plan(running: nil, target: Self.b, installed: [Self.b], live: [.lead]) == .handOver(Self.b))
    }

    /// The rollback's target (ST-D14): the commit installed before the running build's last install, with its
    /// `installs` line as written; nil when there is none, the running build isn't in the record, or every earlier
    /// line is the running commit's. Lines that don't start with a commit are skipped.
    @Test func theRollbackTargetIsThePreviousInstall() throws {
        let lineA = "\(Self.a) 2026-11-16T10:00:00Z", lineB = "\(Self.b) 2026-11-16T11:00:00Z", lineC = "\(Self.c) 2026-11-16T12:00:00Z"
        let target = try #require(SwitchPlan.rollbackTarget(installs: [lineA, lineB], running: Self.b))
        #expect(target.commit == Self.a && target.line == lineA)
        // The running build's last install counts, and an install of it again in between is passed over.
        let later = try #require(SwitchPlan.rollbackTarget(installs: [lineA, lineB, lineC, lineB, "\(Self.b) 2026-11-16T13:00:00Z"], running: Self.b))
        #expect(later.commit == Self.c && later.line == lineC)
        // Back from a rollback: the install before A is none.
        #expect(SwitchPlan.rollbackTarget(installs: [lineA, lineB], running: Self.a) == nil)
        #expect(SwitchPlan.rollbackTarget(installs: [], running: Self.a) == nil)
        #expect(SwitchPlan.rollbackTarget(installs: [lineA, lineB], running: Self.c) == nil)
        #expect(SwitchPlan.rollbackTarget(installs: [lineB, lineB], running: Self.b) == nil)
        // A line a worker wrote that names no commit, an uppercase one, or a blank line: skipped, never a target.
        let skipped = try #require(SwitchPlan.rollbackTarget(installs: [lineA, "../x 2026", Self.c.uppercased() + " 2026", "", "  ", lineB], running: Self.b))
        #expect(skipped.commit == Self.a && skipped.line == lineA)
    }

    // MARK: The texts (the app's HostRestartTests' first case, row 100)

    /// The app's `aHostThatHandsOverKeepsSessionsWithoutAsking`, renamed: the node asks a code where the app asked
    /// nothing. The confirmation says every session is kept and names no count of sessions it ends; it says a running
    /// team keeps its build until its lead restarts (ST-D16) and the seal's hold until `vs config accept` (ST-D23).
    @Test func aSwitchSaysItKeepsSessions() throws {
        let text = NodeTexts.switch(from: Self.a, to: Self.b, rewrites: .unitAndCurrent)
        #expect(text.contains(Self.a) && text.contains(Self.b), "\(text)")
        #expect(text.contains("keeps every session"), "\(text)")
        let count = try Regex("\\b[0-9]+ sessions?\\b")
        #expect(!text.contains("ends") && !text.contains(count), "\(text)")
        #expect(text.contains("a running team keeps its build until its lead restarts"), "\(text)")
        // ST-D16: who runs the old build's tool server after the switch (no worker is live at one: ST-D15).
        #expect(text.contains("a lead started before the switch keeps starting its workers with the old build's tool server"), "\(text)")
        #expect(text.contains("every team waits until you accept the new build and the unit's change"), "\(text)")
        // The code is still typed (EN-D5): `build.switch` is a state change in the user's voice.
        #expect(NodeWire.kinds["build.switch"] == .user && NodeWire.changesState("build.switch"))
    }

    /// `rollback`'s confirmation names where it goes and the `installs` line it read, which any worker can edit, so
    /// the user reads it before typing the code; the rest is the switch's.
    @Test func aRollbackSaysWhereItGoes() {
        let line = "\(Self.a) 2026-11-16T10:00:00Z"
        let text = NodeTexts.rollback(from: Self.b, to: Self.a, line: line, rewrites: .unitAndCurrent)
        #expect(text.contains(Self.a) && text.contains(Self.b) && text.contains(line), "\(text)")
        #expect(text.contains("keeps every session") && text.contains("every team waits until you accept the new build"), "\(text)")
        // A line holding a control character is shown inert.
        let odd = NodeTexts.rollback(from: Self.b, to: Self.a, line: "\(Self.a) \u{1b}[2Jx", rewrites: .unitAndCurrent)
        #expect(!odd.contains("\u{1b}"), "\(odd)")
    }

    /// The review of S8c: the confirmation the code is typed against says what the node's follow-up writes. Under
    /// systemd the unit's `ExecStart` and `current` (above); on a node started detached (no systemd, ST-D6) there is no
    /// unit and only `current` is moved; a scratch node and the Mac rewrite neither, and say why.
    @Test func aConfirmationSaysWhatTheNodesModeRewrites() {
        let line = "\(Self.a) 2026-11-16T10:00:00Z"
        for text in [NodeTexts.switch(from: Self.a, to: Self.b, rewrites: .currentOnly),
                     NodeTexts.rollback(from: Self.a, to: Self.b, line: line, rewrites: .currentOnly)] {
            #expect(text.contains("`current` is moved to \(Self.b), so the next `vs start` runs it"), "\(text)")
            #expect(!text.contains("unit's ExecStart") && !text.contains("the unit change"), "\(text)")
            #expect(text.contains("every team waits until you accept the new build (`vibeswitcher approve`)"), "\(text)")
            #expect(text.contains("keeps every session"), "\(text)")
        }
        for text in [NodeTexts.switch(from: Self.a, to: Self.b, rewrites: .nothing("a scratch node")),
                     NodeTexts.rollback(from: Self.a, to: Self.b, line: line, rewrites: .nothing("a scratch node"))] {
            #expect(text.contains("no unit is rewritten and `current` isn't moved (a scratch node)"), "\(text)")
            #expect(!text.contains("ExecStart") && !text.contains("is moved to"), "\(text)")
            #expect(text.contains("keeps every session"), "\(text)")
        }
        // The reason is shown inert.
        #expect(!NodeTexts.switch(from: Self.a, to: Self.b, rewrites: .nothing("x\u{1b}[2J")).contains("\u{1b}"))
    }

    // MARK: The follow-up (Linux: a scratch prefix and a recording systemctl)

    /// A recording manager (`StartCommandTests.Manager`) whose home holds the prefix, builds `A` and `B` in it,
    /// `current` naming `A`, swiftly's folder holding `swift` and nvm's `v22.1.0` holding `node` (as
    /// `NodeFolders.toolFolders` takes them), and the unit `NodeUnit.text` wrote for `A` from those.
    struct World {
        let manager: StartCommandTests.Manager
        let home: URL
        let prefix: URL
        let unit: NodeUnit.Inputs

        init(_ scratch: Scratch) throws {
            manager = try StartCommandTests.Manager(scratch)
            home = manager.folder.appendingPathComponent("home")
            prefix = home.appendingPathComponent(".vibeswitcher/v2/builds")
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: manager.unitFolder, withIntermediateDirectories: true)
            chmod(home.path, 0o700)
            let swiftBin = home.appendingPathComponent(".local/share/swiftly/bin")
            let nodeBin = home.appendingPathComponent(".nvm/versions/node/v22.1.0/bin")
            for (folder, program) in [(swiftBin, "swift"), (nodeBin, "node")] {
                try StartCommandTests.makeFolder(folder, below: home)
                try StartCommandTests.makeProgram(folder.appendingPathComponent(program))
            }
            try StartCommandTests.makeBuild(prefix: prefix, commit: SwitchTests.a)
            try StartCommandTests.makeBuild(prefix: prefix, commit: SwitchTests.b)
            try FileManager.default.createSymbolicLink(atPath: prefix.appendingPathComponent("current").path, withDestinationPath: SwitchTests.a)
            unit = NodeUnit.Inputs(prefix: prefix.path, commit: SwitchTests.a, home: home.path, swiftBin: swiftBin.path, nodeBin: nodeBin.path)
            try NodeUnit.text(unit).get().write(to: manager.unitFile, atomically: true, encoding: .utf8)
        }

        static let hostPid: pid_t = 4242

        /// The follow-up to `commit`, the host seen by `seen` (its pid unchanged and on `commit` by default).
        func apply(_ commit: String, seen: SwitchFollowUp.Host? = nil, hostCheck: (() -> Result<SwitchFollowUp.Host, StartRefusal>)? = nil) -> Result<Void, StartRefusal> {
            SwitchFollowUp.apply(tools: manager.tools, prefix: prefix.path, accountHome: home.path, commit: commit, hostPid: Self.hostPid,
                                 hostCheck: hostCheck ?? { .success(seen ?? SwitchFollowUp.Host(pid: Self.hostPid, build: commit)) })
        }

        /// `SwitchFollowUp.isDone` for `commit` here.
        func isDone(_ commit: String) -> Bool { SwitchFollowUp.isDone(tools: manager.tools, prefix: prefix.path, commit: commit) }

        /// Writes the unit `NodeUnit.text` makes of `inputs`, as a worker could.
        func writeUnit(_ inputs: NodeUnit.Inputs) throws {
            try NodeUnit.text(inputs).get().write(to: manager.unitFile, atomically: true, encoding: .utf8)
        }

        var unitText: String { (try? String(contentsOf: manager.unitFile, encoding: .utf8)) ?? "" }
        var current: String? { try? FileManager.default.destinationOfSymbolicLink(atPath: prefix.appendingPathComponent("current").path) }
        var prefixEntries: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: prefix.path)) ?? []).sorted() }
        var unitEntries: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: manager.unitFolder.path)) ?? []).sorted() }
    }

    @Test(NodeTraits.linuxOnly) func aSwitchRewritesOnlyExecStartAndReloads() throws {
        let world = try World(scratch)
        let before = world.unitText
        try world.apply(Self.b).get()
        // The unit is start's for B: only ExecStart's line differs from A's, and it names B's folder, never current.
        var forB = world.unit
        forB.commit = Self.b
        #expect(world.unitText == (try NodeUnit.text(forB).get()), "\(world.unitText)")
        let changed = zip(before.split(separator: "\n"), world.unitText.split(separator: "\n")).filter { $0 != $1 }
        #expect(changed.count == 1 && changed.first?.1.hasPrefix("ExecStart=\(world.prefix.path)/\(Self.b)/bin/vibeswitcher-host ") == true, "\(changed)")
        #expect(before.split(separator: "\n").count == world.unitText.split(separator: "\n").count)
        // The calls: daemon-reload only (the user's node runs on: the host handed over already), with the manager's
        // socket given.
        #expect(world.manager.calls == ["--user daemon-reload"], "\(world.manager.calls)")
        #expect(world.manager.environments == ["XDG_RUNTIME_DIR=\(world.manager.runtime.path) DBUS_SESSION_BUS_ADDRESS=unset"], "\(world.manager.environments)")
        // current names B (relative, as the install lays it out), the unit file is 0644, and no temporary is left.
        #expect(world.current == Self.b)
        #expect(NodeFolders.fileStatus(world.manager.unitFile.path).map { $0.mode & 0o777 } == 0o644)
        #expect(world.prefixEntries == [Self.a, Self.b, "current"].sorted(), "\(world.prefixEntries)")
        #expect(world.unitEntries == [NodeUnit.fileName], "\(world.unitEntries)")
        // And back (a rollback is the same follow-up to A).
        try world.apply(Self.a).get()
        #expect(world.unitText == before && world.current == Self.a)
    }

    @Test(NodeTraits.linuxOnly) func aFollowUpChecksTheTargetAndTheHostFirst() throws {
        let world = try World(scratch)
        let unitBefore = world.unitText
        var hostAsked = 0
        func refused(_ commit: String, seen: SwitchFollowUp.Host? = nil, hostCheck: (() -> Result<SwitchFollowUp.Host, StartRefusal>)? = nil,
                     _ expected: String, sourceLocation: SourceLocation = #_sourceLocation) {
            guard case .failure(let refusal) = world.apply(commit, seen: seen, hostCheck: hostCheck) else {
                Issue.record("the follow-up to \(commit) went", sourceLocation: sourceLocation); return
            }
            #expect(refusal.text.contains(expected), "\(refusal)", sourceLocation: sourceLocation)
            // Nothing rewritten, called or moved.
            #expect(world.unitText == unitBefore, sourceLocation: sourceLocation)
            #expect(world.manager.calls.isEmpty, "\(world.manager.calls)", sourceLocation: sourceLocation)
            #expect(world.current == Self.a, sourceLocation: sourceLocation)
            #expect(world.unitEntries == [NodeUnit.fileName], "\(world.unitEntries)", sourceLocation: sourceLocation)
        }
        let counting = { () -> Result<SwitchFollowUp.Host, StartRefusal> in
            hostAsked += 1
            return .success(SwitchFollowUp.Host(pid: World.hostPid, build: Self.c))
        }

        // Not a commit: refused before anything is read, the host not asked.
        refused("../x", hostCheck: counting, "40 hex")
        refused(Self.b.uppercased(), hostCheck: counting, "40 hex")
        // A commit with no build in the prefix.
        refused(Self.c, hostCheck: counting, Self.c)
        // A target outside the prefix: <prefix>/<C> a link to a build elsewhere.
        let outside = world.manager.folder.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let elsewhere = try StartCommandTests.makeBuild(prefix: outside, commit: Self.c)
        try FileManager.default.createSymbolicLink(atPath: world.prefix.appendingPathComponent(Self.c).path, withDestinationPath: elsewhere.path)
        refused(Self.c, hostCheck: counting, "not a folder directly in the prefix")
        try FileManager.default.removeItem(at: world.prefix.appendingPathComponent(Self.c))
        #expect(hostAsked == 0)

        // A build whose bin differs from its build-info.
        let host = world.prefix.appendingPathComponent("\(Self.b)/bin/\(BuildInfo.host)")
        let good = try Data(contentsOf: host)
        try Data("#!/bin/sh\n# changed\n".utf8).write(to: host)
        refused(Self.b, hostCheck: counting, "sha256")
        try good.write(to: host)
        #expect(hostAsked == 0)

        // The host check: another pid, another build, no build, or no answer.
        refused(Self.b, seen: SwitchFollowUp.Host(pid: World.hostPid + 1, build: Self.b), "pid")
        refused(Self.b, seen: SwitchFollowUp.Host(pid: World.hostPid, build: Self.a), Self.a)
        refused(Self.b, seen: SwitchFollowUp.Host(pid: World.hostPid, build: nil), "name no build")
        refused(Self.b, hostCheck: { .failure(StartRefusal("the server didn't answer")) }, "the server didn't answer")

        // A unit not in start's form (an ExecStart a worker edited): refused, naming it, before any write.
        let edited = unitBefore.replacingOccurrences(of: "--server", with: "--server-x")
        try edited.write(to: world.manager.unitFile, atomically: true, encoding: .utf8)
        guard case .failure(let notStarts) = world.apply(Self.b) else { Issue.record("an edited unit was rewritten"); return }
        #expect(notStarts.text.contains("ExecStart"), "\(notStarts)")
        #expect(world.unitText == edited && world.manager.calls.isEmpty && world.current == Self.a)
        // No unit file at all: refused (`vs start` writes it).
        try FileManager.default.removeItem(at: world.manager.unitFile)
        guard case .failure(let none) = world.apply(Self.b) else { Issue.record("a missing unit was written"); return }
        #expect(none.text.contains(NodeUnit.fileName), "\(none)")
        #expect(world.unitEntries.isEmpty && world.manager.calls.isEmpty && world.current == Self.a)
    }

    /// A reload the manager refuses: the unit stays rewritten (said), and `current` isn't moved.
    @Test(NodeTraits.linuxOnly) func aReloadThatFailsLeavesCurrentAndSaysTheUnitChanged() throws {
        let world = try World(scratch)
        try world.manager.fail("--user daemon-reload")
        guard case .failure(let refusal) = world.apply(Self.b) else { Issue.record("a failed reload went"); return }
        #expect(refusal.text.contains("daemon-reload") && refusal.text.contains(Self.b), "\(refusal)")
        #expect(world.manager.calls == ["--user daemon-reload"] && world.current == Self.a)
        // The way back the refusal names: once the manager reloads, the follow-up again (S8c runs it when the server
        // says the host runs B already and `isDone` says no) finishes it.
        #expect(refusal.text.contains("`vs switch \(Self.b)` again"), "\(refusal)")
        #expect(!world.isDone(Self.b))
        try FileManager.default.removeItem(at: world.manager.folder.appendingPathComponent("fail"))
        try world.apply(Self.b).get()
        #expect(world.manager.calls == ["--user daemon-reload", "--user daemon-reload"] && world.current == Self.b, "\(world.manager.calls)")
        #expect(world.isDone(Self.b) && !world.isDone(Self.a))
    }

    /// `isDone`: the unit, in start's form, names the commit, and so does `current`; a unit or `current` that lags
    /// behind, or a unit that isn't start's or isn't there, isn't done.
    @Test(NodeTraits.linuxOnly) func theFollowUpIsDoneOnlyWhenTheUnitAndCurrentNameTheTarget() throws {
        let world = try World(scratch)
        #expect(world.isDone(Self.a) && !world.isDone(Self.b))
        // current moved by an install, the unit still on A.
        try FileManager.default.removeItem(at: world.prefix.appendingPathComponent("current"))
        try FileManager.default.createSymbolicLink(atPath: world.prefix.appendingPathComponent("current").path, withDestinationPath: Self.b)
        #expect(!world.isDone(Self.a) && !world.isDone(Self.b))
        try world.apply(Self.b).get()
        #expect(world.isDone(Self.b))
        try world.unitText.replacingOccurrences(of: "--server", with: "--server-x").write(to: world.manager.unitFile, atomically: true, encoding: .utf8)
        #expect(!world.isDone(Self.b))
        try FileManager.default.removeItem(at: world.manager.unitFile)
        #expect(!world.isDone(Self.b))
    }

    /// A node started detached (no systemd, ST-D6; S8c) has no unit, and its `start` starts the build `vs` runs from: its
    /// follow-up checks the target and the host as `apply` does, then moves only `current`, calling nothing and leaving
    /// the unit folder as it was.
    @Test(NodeTraits.linuxOnly) func aDetachedNodesFollowUpMovesOnlyCurrent() throws {
        let world = try World(scratch)
        let unitBefore = world.unitText
        func applyDetached(_ commit: String, seen: SwitchFollowUp.Host) -> Result<Void, StartRefusal> {
            SwitchFollowUp.applyDetached(prefix: world.prefix.path, commit: commit, hostPid: World.hostPid, hostCheck: { .success(seen) })
        }
        // The host still on A, or another host: nothing moved.
        for seen in [SwitchFollowUp.Host(pid: World.hostPid, build: Self.a), SwitchFollowUp.Host(pid: World.hostPid + 1, build: Self.b)] {
            guard case .failure(let refusal) = applyDetached(Self.b, seen: seen) else { Issue.record("went with \(seen)"); continue }
            #expect(refusal.text.contains("nothing was rewritten") && refusal.text.contains("`vs switch \(Self.b)` again"), "\(refusal)")
            #expect(world.current == Self.a && !SwitchFollowUp.isCurrent(prefix: world.prefix.path, commit: Self.b))
        }
        // A target that isn't an installed build.
        guard case .failure = applyDetached(Self.c, seen: SwitchFollowUp.Host(pid: World.hostPid, build: Self.c)) else {
            Issue.record("a build not installed was taken"); return
        }
        try applyDetached(Self.b, seen: SwitchFollowUp.Host(pid: World.hostPid, build: Self.b)).get()
        #expect(world.current == Self.b && SwitchFollowUp.isCurrent(prefix: world.prefix.path, commit: Self.b))
        #expect(world.unitText == unitBefore && world.manager.calls.isEmpty, "\(world.manager.calls)")
        #expect(world.prefixEntries == [Self.a, Self.b, "current"].sorted(), "\(world.prefixEntries)")
    }

    /// The review of S8c: the switch's target is checked as an installed build (`NodeFolders.verifyBuild`: its `bin`
    /// holds exactly what its `build-info` records, each hash the recorded one) before the code is asked, so a build
    /// whose tool server or command line a worker rewrote is refused with nothing switched; the host checks only the
    /// host's and the server's images at the handover.
    @Test(NodeTraits.linuxOnly) func aSwitchsTargetIsCheckedBeforeTheCodeIsAsked() throws {
        let world = try World(scratch)
        #expect(SwitchFollowUp.targetRefusal(prefix: world.prefix.path, commit: Self.b) == nil)
        // The command line's file rewritten, its build-info left alone (the world's builds hold no tool server).
        let cli = world.prefix.appendingPathComponent("\(Self.b)/bin/\(NodeFolders.installedCLI)")
        let good = try Data(contentsOf: cli)
        try Data("#!/bin/sh\n# rewritten\n".utf8).write(to: cli)
        let refused = try #require(SwitchFollowUp.targetRefusal(prefix: world.prefix.path, commit: Self.b))
        #expect(refused.text.contains("isn't an installed build") && refused.text.contains("sha256") && refused.text.contains("nothing was switched"),
                "\(refused)")
        #expect(refused.exitCode == 77)
        try good.write(to: cli)
        // A file added to bin, a commit not installed, or no commit at all.
        let extra = world.prefix.appendingPathComponent("\(Self.b)/bin/extra")
        try Data("x".utf8).write(to: extra)
        #expect(SwitchFollowUp.targetRefusal(prefix: world.prefix.path, commit: Self.b)?.text.contains("extra") == true)
        try FileManager.default.removeItem(at: extra)
        #expect(SwitchFollowUp.targetRefusal(prefix: world.prefix.path, commit: Self.c) != nil)
        #expect(SwitchFollowUp.targetRefusal(prefix: world.prefix.path, commit: "../x")?.text.contains("40 hex") == true)
        #expect(SwitchFollowUp.targetRefusal(prefix: world.prefix.path, commit: Self.b) == nil)
    }

    /// The review of S8c: on a node whose follow-up checks the host (under systemd, or started detached), its pid before
    /// the switch must be known before the code is asked. `status` names none while the server's link to its host
    /// isn't welcomed yet: the host is then asked again (`hostCheck`), and when it still names none the switch is
    /// refused with nothing switched, never handed over and then left half done ("the pid isn't known").
    @Test func theHostsPidIsKnownBeforeTheCodeIsAsked() throws {
        var asked = 0
        let known = try SwitchFollowUp.hostBefore(pid: 42, build: Self.a, hostCheck: { asked += 1; return .failure(StartRefusal("no")) }).get()
        #expect(known == SwitchFollowUp.Host(pid: 42, build: Self.a) && asked == 0)
        let askedAgain = try SwitchFollowUp.hostBefore(pid: nil, build: nil, hostCheck: { asked += 1; return .success(SwitchFollowUp.Host(pid: 43, build: Self.a)) }).get()
        #expect(askedAgain == SwitchFollowUp.Host(pid: 43, build: Self.a) && asked == 1)
        guard case .failure(let refused) = SwitchFollowUp.hostBefore(pid: nil, build: Self.a, hostCheck: { .failure(StartRefusal("the server's status names no host pid yet", exitCode: 1)) }) else {
            Issue.record("a switch went with no host pid"); return
        }
        #expect(refused.text.contains("nothing was switched") && refused.text.contains("names no host pid yet"), "\(refused)")
        #expect(refused.exitCode == 1)
    }

    /// The review of S8c: `build.switch`'s reply lost (the connection closed, or no answer in time) may come after the
    /// host handed over. The host as a fresh connection sees it decides: its pid unchanged and on the target is handed
    /// over, and the follow-up runs; anything else, or no answer, says the host may have switched and how to finish.
    @Test func aLostReplyIsFollowedUpOnlyWhenTheHostRunsTheTarget() throws {
        let lost = "the node's server closed the connection"
        let host = try SwitchFollowUp.afterLostReply(lost, commit: Self.b, hostPid: 42, hostCheck: { .success(SwitchFollowUp.Host(pid: 42, build: Self.b)) }).get()
        #expect(host == SwitchFollowUp.Host(pid: 42, build: Self.b))
        for seen in [Result<SwitchFollowUp.Host, StartRefusal>.success(SwitchFollowUp.Host(pid: 42, build: Self.a)),
                     .success(SwitchFollowUp.Host(pid: 43, build: Self.b)), .success(SwitchFollowUp.Host(pid: 42, build: nil)),
                     .failure(StartRefusal("no server answered", exitCode: 1))] {
            guard case .failure(let refused) = SwitchFollowUp.afterLostReply(lost, commit: Self.b, hostPid: 42, hostCheck: { seen }) else {
                Issue.record("followed up with \(seen)"); continue
            }
            #expect(refused.text.contains(lost) && refused.text.contains("the host may have switched") && refused.text.contains("`vs status`")
                    && refused.text.contains("`vs switch \(Self.b)` again finishes this"), "\(refused)")
            #expect(refused.exitCode == 1)
        }
    }

    /// The review of S8c: a detached host's start line (ST-D24) is in its log (`NodeStarter.hostLog`), not the journal:
    /// the newest line of the host's pid is taken, as what follows `vibeswitcher-host: started `.
    @Test func aDetachedHostsStartLineIsReadFromItsLog() {
        let log = [HostStartLine.text(pid: 42, commit: Self.a, backtrace: "enable=no"), "other output",
                   HostStartLine.text(pid: 7, commit: Self.c, backtrace: nil),
                   HostStartLine.text(pid: 42, commit: Self.b, backtrace: "enable=no"), "vibeswitcher-host: started pid 4 build x", ""].joined(separator: "\n")
        #expect(NodeJournal.hostLogStart(log, pid: 42) == "pid 42 build \(Self.b) SWIFT_BACKTRACE=enable=no")
        #expect(NodeJournal.hostLogStart(log, pid: 7) == "pid 7 build \(Self.c) SWIFT_BACKTRACE=unset")
        #expect(NodeJournal.hostLogStart(log, pid: 4242) == nil && NodeJournal.hostLogStart("", pid: 42) == nil)
    }

    /// The review of S8a: the follow-up writes the unit as `start` does (ST-D3, ST-D4): the account's home and swiftly's
    /// folder from where `start` takes them, the node folder only through `NodeFolders.toolFolders`, never a unit's
    /// edited HOME or PATH written back for a switch the user then accepts.
    @Test(NodeTraits.linuxOnly) func aUnitsEditedHomeOrPathIsNotCarriedThroughASwitch() throws {
        let world = try World(scratch)
        // A worker's HOME and swift folder, in start's form: the unit for B is start's, from the account's values.
        var edited = world.unit
        edited.home = "/var/tmp/elsewhere"
        edited.swiftBin = "/var/tmp/planted/bin"
        try world.writeUnit(edited)
        try world.apply(Self.b).get()
        var forB = world.unit
        forB.commit = Self.b
        #expect(world.unitText == (try NodeUnit.text(forB).get()), "\(world.unitText)")
        #expect(!world.unitText.contains("/var/tmp"), "\(world.unitText)")

        // A worker's node folder outside nvm's: refused before anything is written, called or moved.
        func refused(_ unit: NodeUnit.Inputs, _ expected: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
            try world.writeUnit(unit)
            let before = world.unitText, calls = world.manager.calls, current = world.current
            guard case .failure(let refusal) = world.apply(Self.a) else {
                Issue.record("the follow-up went", sourceLocation: sourceLocation); return
            }
            #expect(refusal.text.contains(expected), "\(refusal)", sourceLocation: sourceLocation)
            #expect(refusal.text.contains("nothing was rewritten"), "\(refusal)", sourceLocation: sourceLocation)
            #expect(world.unitText == before && world.manager.calls == calls && world.current == current, sourceLocation: sourceLocation)
            #expect(world.unitEntries == [NodeUnit.fileName], "\(world.unitEntries)", sourceLocation: sourceLocation)
        }
        var planted = forB
        planted.nodeBin = "/var/tmp/planted/nbin"
        try refused(planted, "/var/tmp/planted/nbin")
        // The node folder in nvm's form, but under the HOME a worker wrote: not the account's.
        planted = forB
        planted.home = "/var/tmp/elsewhere"
        planted.nodeBin = "/var/tmp/elsewhere/.nvm/versions/node/v22.1.0/bin"
        try refused(planted, "/var/tmp/elsewhere/.nvm")
        // A swift folder start wouldn't take (group-writable): refused too, as start would.
        let swiftBin = world.home.appendingPathComponent(".local/share/swiftly/bin").path
        chmod(swiftBin, 0o775)
        try refused(forB, swiftBin)
        chmod(swiftBin, 0o755)
    }

    /// ST-D23: after the follow-up in a scratch home, the seal's entries for the builds folder and the unit folder both
    /// changed, so the next look holds every team until `config accept`.
    ///
    /// The entries are `LinuxSealList.watched(home:uid:)`'s for those names (S7, 2026-11-16): the builds folder a
    /// `.listing`, the unit folder a `.folder`.
    @Test(NodeTraits.linuxOnly) func aSwitchLeavesTheSealHoldingUntilAccepted() throws {
        let world = try World(scratch)
        let names = ["~/.vibeswitcher/v2/builds", "~/.config/systemd/user"]
        let entries = names.compactMap { name in LinuxSealList.watched(home: world.home.path, uid: getuid()).first { $0.name == name } }
        try #require(entries.map(\.name) == names)
        #expect(entries.map(\.kind) == [.listing, .folder])
        let before = entries.map(ConfigSeal.fingerprint)
        #expect(before.allSatisfy { $0 != nil })
        #expect(entries.map(ConfigSeal.fingerprint) == before)
        try world.apply(Self.b).get()
        let after = entries.map(ConfigSeal.fingerprint)
        for (index, entry) in entries.enumerated() {
            #expect(after[index] != nil && after[index] != before[index], "\(entry.name) unchanged")
        }
    }

    // MARK: build.switch's outcome (the app's HostClientHandoverTests, row 97)

    /// The app's `theHandoverWaitCoversTheHostsProbe`: the server's wait for the handover's reply covers the host's probe
    /// limit and a margin for saving the sessions and the exec, noted every 15 s; any other request keeps its 15 s.
    @Test func theSwitchWaitCoversTheHostsProbe() {
        #expect(SwitchRequest.probeLimit == HostHandover.probeLimit)
        #expect(SwitchRequest.replyWait >= HostHandover.probeLimit + 15)
        #expect(SwitchRequest.Timing().replyWait == SwitchRequest.replyWait)
        #expect(SwitchRequest.breadcrumb == 15)
        #expect(HostLink.replyWait == 15)
        // The command line waits for every one of the switch's waits (S8c).
        #expect(SwitchRequest.longestWait >= SwitchRequest.replyWait + SwitchRequest.lateWait + SwitchRequest.welcomeWait)
    }

    /// The app's `theOutcomeNamesWhoAnswered`: the outcome says which host answered, on which build, and when.
    @Test func theOutcomeNamesWhoAnswered() {
        let before: (pid: Int32?, build: String?) = (31589, Self.a)
        func said(_ after: (pid: Int32?, build: String?)?, refusal: String? = nil, afterTheWait: Bool = false,
                  before: (pid: Int32?, build: String?) = before) -> String {
            SwitchRequest.outcome(before: before, target: Self.b, after: after, refusal: refusal, afterTheWait: afterTheWait).text
        }
        #expect(said((31589, Self.b)) == "handed over (pid 31589, build \(Self.b))")
        #expect(said((31589, Self.b), afterTheWait: true) == "handed over after the wait (pid 31589, build \(Self.b))")
        #expect(said((31589, Self.a), afterTheWait: true).hasPrefix("handover failed: the old build"))
        #expect(said((31589, Self.a)) == "handover failed: the old build answered (pid 31589, build \(Self.a); asked for \(Self.b))")
        #expect(said((31589, nil)).hasPrefix("handover failed: the old build"))
        #expect(said((1, Self.b)) == "handover failed: a different host answered (pid 1, build \(Self.b); was pid 31589)")
        #expect(said((nil, Self.b)).hasPrefix("handover failed: a different host"))
        #expect(said(nil) == "handover failed: the host (pid 31589) went away and no build answered")
        #expect(said((31589, Self.b), refusal: "Couldn't hand over: probe failed.") == "handover failed: Couldn't hand over: probe failed.")
        // A host too old to give its pid: only the build tells.
        #expect(said((nil, Self.b), before: (nil, Self.a)) == "handed over (pid ?, build \(Self.b))")
        #expect(SwitchRequest.outcome(before: before, target: Self.b, after: (31589, Self.b), refusal: nil, afterTheWait: false)
                == .handedOver(commit: Self.b, pid: 31589, afterTheWait: false))
        // The host's refusal is shown inert.
        #expect(!said(nil, refusal: "no\u{1b}[2J").contains("\u{1b}"))
    }

    /// A link on a stand-in host whose pid is 31589, whose notes name build `A` and which lists one live session (as the
    /// app's `FakeHost` welcomes with one), a scratch install root holding `A` and `B` (folders only: the stand-in never
    /// runs them), and a switch on it whose notes are kept.
    final class StubWorld: @unchecked Sendable {
        let stub: StubHost
        let link: HostLink
        let installRoot: URL
        let notes = Locked<[String]>([])

        init(_ scratch: Scratch, onHandover: StubHost.OnHandover) async throws {
            stub = try StubHost(scratch, capabilities: [HostProtocol.Capability.inputUnits, HostProtocol.Capability.vaultV2,
                                                        HostProtocol.Capability.hostNotes, HostProtocol.Capability.handover],
                            sessions: [StubHost.session()])
            stub.pid = 31589
            stub.build = SwitchTests.a
            stub.onHandover = onHandover
            installRoot = scratch.url("builds")
            for commit in [SwitchTests.a, SwitchTests.b] {
                try FileManager.default.createDirectory(at: installRoot.appendingPathComponent(commit), withIntermediateDirectories: true)
            }
            var timing = HostLink.Timing()
            timing.reconnectDelays = [0.05, 0.1, 0.2, 0.5, 1, 2]
            link = HostLink(dialer: stub.dialer, root: scratch.url("link-root"), queue: DispatchQueue(label: "engine"), timing: timing,
                            sweep: { _ in })
            link.start()
            let link = self.link
            try #require(await eventually { link.queue.sync { link.state == .connected } }, "the link was never welcomed")
        }

        /// `build.switch` to `B` on the link's queue: its answer, once it comes.
        func run(_ timing: SwitchRequest.Timing = SwitchRequest.Timing()) -> Locked<SwitchRequest.Answer?> {
            let answer = Locked<SwitchRequest.Answer?>(nil)
            let request = SwitchRequest(link: link, installRoot: installRoot.path, timing: timing) { [notes] line in notes.mutate { $0.append(line) } }
            link.queue.async { request.run(commit: SwitchTests.b) { answer.value = $0 } }
            return answer
        }

        /// What the switch said of the handover's end.
        var handover: [String] { notes.value.filter { $0.contains("handed over") || $0.contains("handover failed") } }
        /// What it said of its wait.
        var waiting: [String] { notes.value.filter { $0.hasPrefix("build.switch: waiting") || $0.hasPrefix("build.switch: no answer") } }
        /// How many sessions the link has live.
        var live: Int { link.queue.sync { link.sessions.filter(\.isLive).count } }
        /// Whether the stand-in was asked to hand over.
        var askedToHandOver: Bool { stub.requests.contains { if case .handover = $0 { true } else { false } } }

        deinit { stub.quit() }
    }

    /// A switch's answer, waited for.
    private static func answer(_ answer: Locked<SwitchRequest.Answer?>, timeout: TimeInterval = 60) async -> SwitchRequest.Answer? {
        _ = await eventually(timeout: timeout) { answer.value != nil }
        return answer.value
    }

    /// The text of a handed-over answer's `said`, or of a refusal.
    private static func said(_ answer: SwitchRequest.Answer?) -> String? {
        switch answer {
        case .done(let result)?: return result.said
        case .refused(_, let why)?: return why
        case nil: return nil
        }
    }

    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(2))) func aHandoverInPlaceIsHandedOver() async throws {
        let world = try await StubWorld(scratch, onHandover: .reExec(build: Self.b))
        let answer = await Self.answer(world.run())
        guard case .done(let value)? = answer else { Issue.record("\(String(describing: answer))"); return }
        #expect(value.outcome == "handed-over" && value.commit == Self.b && value.pid == 31589, "\(value)")
        #expect(value.from == Self.a && value.afterTheWait == false, "\(value)")
        #expect(world.handover == ["build.switch: handed over (pid 31589, build \(Self.b))"], "\(world.notes.value)")
        // The app's `client.sessions.count == 1`: the session is kept across the handover.
        #expect(world.live == 1)
    }

    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(2))) func theOldBuildAnsweringIsAFailure() async throws {
        let world = try await StubWorld(scratch, onHandover: .fallBack)
        let answer = await Self.answer(world.run())
        let failed = "handover failed: the old build answered (pid 31589, build \(Self.a); asked for \(Self.b))"
        #expect(answer == .refused(.refused, failed))
        #expect(world.handover == ["build.switch: " + failed], "\(world.notes.value)")
        // The app's `outdated(live: 1, …)`: the old build keeps its session.
        #expect(world.live == 1)
    }

    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(2))) func aDifferentHostAnsweringIsAFailure() async throws {
        let world = try await StubWorld(scratch, onHandover: .replacedBy(pid: 40000, build: Self.b))
        let answer = await Self.answer(world.run())
        let failed = "handover failed: a different host answered (pid 40000, build \(Self.b); was pid 31589)"
        #expect(answer == .refused(.refused, failed))
        #expect(world.handover == ["build.switch: " + failed], "\(world.notes.value)")
        #expect(world.live == 1)
    }

    /// The host goes, socket and all: the link's end answers the switch's wait for a welcome at once (the switch's own
    /// waits are on a clock the test moves), the host is asked again on connections of its own for `confirmWait`, and
    /// only then is "no build answered" said; the session it listed is ended.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(2))) func aHostThatGoesAwayIsAFailure() async throws {
        let world = try await StubWorld(scratch, onHandover: .quit)
        #expect(world.live == 1)
        let clock = ManualClock()
        var timing = SwitchRequest.Timing()
        timing.later = clock.schedule
        let running = world.run(timing)
        let link = world.link
        #expect(await eventually { link.queue.sync { if case .gone = link.state { true } else { false } } })
        // Each second of the confirming wait, one more check on a connection of its own (the socket is gone: each fails
        // and arms the next): the clock is moved once each is armed.
        var seen = 0
        for _ in 0..<(2 * Int(SwitchRequest.confirmWait)) where running.value == nil {
            _ = await eventually(timeout: 10) { clock.armed.count > seen || running.value != nil }
            seen = clock.armed.count
            clock.advance(SwitchRequest.confirmEvery)
        }
        let answer = await Self.answer(running)
        let failed = "handover failed: the host (pid 31589) went away and no build answered"
        #expect(answer == .refused(.refused, failed))
        #expect(world.handover == ["build.switch: " + failed], "\(world.notes.value)")
        #expect(link.queue.sync { link.sessions.count == 1 && link.sessions.allSatisfy { !$0.isLive } })
    }

    /// The real node's switch right after a start (2026-11-22): the host handed over, but the new build listened only
    /// after the link had given up reconnecting. The switch asks the host on a connection of its own before it says
    /// anything failed, and says it handed over.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(2))) func aHandoverTheLinkGaveUpOnIsHandedOver() async throws {
        let world = try await StubWorld(scratch, onHandover: .away(build: Self.b))
        var timing = SwitchRequest.Timing()
        timing.confirmEvery = 0.1
        let running = world.run(timing)
        let link = world.link
        try #require(await eventually { link.queue.sync { if case .gone = link.state { true } else { false } } }, "\(world.notes.value)")
        #expect(running.value == nil, "nothing said while the host may still come")
        try world.stub.listenAgain()
        let answer = await Self.answer(running)
        #expect(Self.said(answer) == "handed over (pid 31589, build \(Self.b))", "\(String(describing: answer)) \(world.notes.value)")
        #expect(world.notes.value.contains { $0.contains("asked on a connection of its own, pid 31589 runs build \(Self.b)") }, "\(world.notes.value)")
    }

    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(2))) func aRefusalIsAFailure() async throws {
        let world = try await StubWorld(scratch, onHandover: .refuse("Couldn't hand over: probe failed."))
        let answer = await Self.answer(world.run())
        #expect(answer == .refused(.refused, "handover failed: Couldn't hand over: probe failed."))
        #expect(world.handover == ["build.switch: handover failed: Couldn't hand over: probe failed."], "\(world.notes.value)")
        // The host carried on: the link was never dropped, and its session is kept.
        let link = world.link
        #expect(link.queue.sync { link.welcomes } == 1)
        #expect(world.live == 1)
    }

    /// The handover's connection closes before the handover was sent (another switch's exec, or a host that went before
    /// it welcomed it): nothing was asked, so it is no outcome. The switch says the host couldn't be asked, and doesn't
    /// take the link's next welcome as the handover's.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(2))) func aCloseBeforeTheHandoverIsAskedIsNoOutcome() async throws {
        let world = try await StubWorld(scratch, onHandover: .reExec(build: Self.b))
        let hellos = { world.stub.requests.filter { if case .hello = $0 { true } else { false } }.count }
        #expect(hellos() == 1)
        world.stub.welcomes = false
        let answer = world.run()
        #expect(await eventually { hellos() == 2 }, "\(world.stub.requests)")
        world.stub.welcomes = true
        world.stub.dropConnections()
        let said = Self.said(await Self.answer(answer)) ?? ""
        #expect(said == "the host couldn't be asked to hand over: the host closed the connection before the handover was asked",
                "\(said)\n\(world.notes.value)")
        #expect(!world.askedToHandOver && world.handover.isEmpty, "\(world.notes.value)")
        #expect(world.live == 1)
    }

    /// The host's probe of the new build takes past a request's 15 s: the handover is waited for, noted every 15 s, and
    /// said handed over, never failed first. The switch's waits run on a clock the test moves, past 15 s and on to 30 s
    /// before the host answers.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(2))) func aProbePastFifteenSecondsIsWaitedFor() async throws {
        let world = try await StubWorld(scratch, onHandover: .onCue(then: .reExec(build: Self.b)))
        let clock = ManualClock()
        var timing = SwitchRequest.Timing()
        timing.later = clock.schedule
        let answer = world.run(timing)
        #expect(await eventually { world.askedToHandOver }, "\(world.stub.requests)")
        clock.advance(15)
        clock.advance(15)
        let expected = ["build.switch: waiting for the new build's probe, 15 s", "build.switch: waiting for the new build's probe, 30 s"]
        #expect(await eventually { world.waiting == expected }, "\(world.notes.value)")
        #expect(answer.value == nil && world.handover.isEmpty, "\(world.notes.value)")
        #expect(await eventually { world.stub.cue() })
        #expect(Self.said(await Self.answer(answer)) == "handed over (pid 31589, build \(Self.b))", "\(world.notes.value)")
        #expect(world.waiting == expected, "\(world.notes.value)")
    }

    /// The handover's wait runs out and the host hands over after it: the connection was kept, and the new build's
    /// welcome is the handover's success. The host answers once the switch has noted its wait out.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(2))) func aHandoverAfterTheWaitIsHandedOver() async throws {
        let world = try await StubWorld(scratch, onHandover: .onCue(then: .reExec(build: Self.b)))
        var timing = SwitchRequest.Timing()
        (timing.replyWait, timing.breadcrumb) = (2, 1)
        let answer = world.run(timing)
        #expect(await eventually { world.notes.value.contains { $0.hasPrefix("build.switch: no answer in") } }, "\(world.notes.value)")
        #expect(answer.value == nil && world.handover.isEmpty, "\(world.notes.value)")
        #expect(await eventually { world.stub.cue() })
        guard case .done(let value)? = await Self.answer(answer) else { Issue.record("\(world.notes.value)"); return }
        #expect(value.said == "handed over after the wait (pid 31589, build \(Self.b))" && value.afterTheWait == true, "\(value)")
        #expect(world.waiting == ["build.switch: waiting for the new build's probe, 1 s",
                                  "build.switch: no answer in 2 s; the connection stays open 60 s more"], "\(world.notes.value)")
        #expect(world.live == 1)
    }

    /// The host refuses after the switch stopped waiting: that's the handover failing, and the old build carries on.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(2))) func aRefusalAfterTheWaitIsAFailure() async throws {
        let world = try await StubWorld(scratch, onHandover: .onCue(then: .refuse("Couldn't hand over: probe failed.")))
        var timing = SwitchRequest.Timing()
        (timing.replyWait, timing.breadcrumb) = (1, 1)
        let answer = world.run(timing)
        #expect(await eventually { world.notes.value.contains { $0.hasPrefix("build.switch: no answer in 1 s") } }, "\(world.notes.value)")
        #expect(answer.value == nil && world.handover.isEmpty, "\(world.notes.value)")
        #expect(await eventually { world.stub.cue() })
        #expect(await Self.answer(answer) == .refused(.refused, "handover failed: Couldn't hand over: probe failed."))
        #expect(world.handover == ["build.switch: handover failed: Couldn't hand over: probe failed."], "\(world.notes.value)")
        let link = world.link
        #expect(link.queue.sync { link.welcomes } == 1)
        #expect(world.live == 1)
    }

    // MARK: build.switch on a scratch node (S8, the rule on switches; the app's HostClientSlowProbeTests, row 99)

    /// `status`'s `builds` (ST-D14): the install root, the builds installed, and the rollback's target from its
    /// `installs` for the build the host's notes name, with its line. A server with no install root gives none.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(2))) func statusGivesTheRollbackTarget() async throws {
        let world = try await StubWorld(scratch, onHandover: .refuse("not asked"))
        world.stub.build = Self.b
        let lines = ["\(Self.a) 2026-11-16T10:00:00Z", "\(Self.b) 2026-11-16T11:00:00Z"]
        try (lines.joined(separator: "\n") + "\n").write(to: world.installRoot.appendingPathComponent("installs"), atomically: true, encoding: .utf8)
        // Not a build: a link named as a commit, and the `current` link.
        try FileManager.default.createSymbolicLink(at: world.installRoot.appendingPathComponent(Self.c), withDestinationURL: world.installRoot.appendingPathComponent(Self.a))
        try FileManager.default.createSymbolicLink(at: world.installRoot.appendingPathComponent("current"), withDestinationURL: world.installRoot.appendingPathComponent(Self.b))
        let requests = Requests(link: world.link, sessions: nil, rule: VoiceRule(mode: .weaker, scopes: [], uid: getuid(), says: "a test's"),
                                root: scratch.url("node-root"), hostSocket: world.stub.path, commit: "test", hostPID: 1)
        func status() async -> NodeWire.Value? {
            let reply = Locked<NodeWire.Reply?>(nil)
            requests.queue.async {
                requests.handle(NodeWire.Request(id: "s", kind: "status"), from: CardWorld.user) { answer in reply.value = answer }
            }
            _ = await eventually { reply.value != nil }
            return reply.value?.result
        }
        #expect(await status()?["builds"] == .null)
        requests.installRoot = world.installRoot.path
        let builds = try #require(await status()?["builds"])
        #expect(builds["installRoot"]?.string == world.installRoot.path, "\(builds)")
        #expect(builds["installed"] == .array([.string(Self.a), .string(Self.b)]), "\(builds)")
        #expect(builds["rollback"] == .object(["commit": .string(Self.a), "line": .string(lines[0])]), "\(builds)")
        // On A, nothing was installed before it.
        world.stub.build = Self.a
        #expect(await status()?["builds"]?["rollback"] == .null)
    }

    /// The node's `status` result.
    private static func status(_ client: WireClient) -> NodeWire.Value? {
        WireClient.reply(client.request("status", action: nil))?.result
    }

    /// The host's live sessions and the build its notes name, as `status` gives them.
    private static func host(_ client: WireClient) -> (pid: Int?, live: Int?, build: String?) {
        let host = status(client)?["host"]
        return (host?["pid"]?.int, host?["liveSessions"]?.int, host?["notes"]?["build"]?.string)
    }

    /// The rule on switches (S8, ST-D15): on a scratch node running `A` with a lead and a worker live, `build.switch` to
    /// `B` is refused, naming decision 6 and the worker, and the host's pid and build are unchanged. Once only the lead
    /// is live, it hands over, and the lead is kept.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func aSwitchWhileAWorkerRunsIsRefused() async throws {
        let builds = scratch.url("builds")
        let a = try ScratchBuilds.install(commit: Self.a, into: builds)
        try ScratchBuilds.install(commit: Self.b, into: builds)
        let node = try await ScratchNode(scratch, build: a, installRoot: builds)
        defer { node.stop() }
        let lead = try await node.spawn("sleep 600", label: "Lead · project")
        let worker = try await node.spawn("sleep 600", label: "Worker: task-1")
        let client = try WireClient(node)
        #expect(await eventually { Self.host(client).live == 2 })
        let refused = try #require(WireClient.reply(client.request("build.switch", args: ["commit": .string(Self.b)])))
        #expect(!refused.ok && refused.error?.code == "refused", "\(refused)")
        let message = refused.error?.message ?? ""
        #expect(message.contains("decision 6") && message.contains(worker.tty) && message.contains("Worker: task-1"), "\(message)")
        #expect(!message.contains(lead.tty), "\(message)")
        let unchanged = Self.host(client)
        #expect(unchanged.pid == Int(node.hostPID) && unchanged.build == Self.a, "\(unchanged)")
        // `status` names what blocks it, so the command line says so before its code, by name, and asks nothing.
        let blockers = (Self.status(client)?["switchBlockers"]?.array ?? []).compactMap(\.string)
        #expect(blockers.count == 1 && blockers[0].contains(worker.tty) && blockers[0].contains("Worker: task-1"), "\(blockers)")
        let said = try await node.runOnTerminal(["switch", Self.b, "--long"])
        #expect(said.status == 77 && said.output.contains("switch can't run now: no switch of builds while a worker or verifier runs")
                && said.output.contains(worker.tty) && said.output.contains("Nothing was asked or switched."), "\(said.output)")
        #expect(!said.output.contains("This switches the node") && !said.output.contains("code"), "no confirmation, no code: \(said.output)")

        // The worker ends: with only the lead live, the host hands over to B.
        _ = try HostCall.request(.kill(id: worker.id), socket: node.socket, appKey: nil, timeout: 15)
        #expect(await eventually { Self.host(client).live == 1 })
        #expect(Self.status(client)?["switchBlockers"]?.array == [], "only the lead: nothing blocks it")
        let handed = try #require(WireClient.reply(client.request("build.switch", args: ["commit": .string(Self.b)], timeout: SwitchRequest.longestWait)),
                                  "\(node.said)")
        #expect(handed.ok && handed.result?["outcome"]?.string == "handed-over" && handed.result?["commit"]?.string == Self.b,
                "\(handed)\n\(node.said)")
        let after = Self.host(client)
        #expect(after.pid == Int(node.hostPID) && after.build == Self.b, "\(after)")
        #expect(try node.sessions().contains { $0.id == lead.id && $0.isLive })
        // The rollback's target is A now.
        #expect(Self.status(client)?["builds"]?["rollback"]?["commit"]?.string == Self.a)
    }

    /// A switch waits on every worker and verifier the switch can't park (a real one waited hours): its refusal, `status`'s
    /// switchBlockers and `vibeswitcher status` name each with what it does and since when.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func aSwitchsRefusalAndStatusSayWhoHoldsItAndSinceWhen() async throws {
        let builds = scratch.url("builds")
        let a = try ScratchBuilds.install(commit: Self.a, into: builds)
        try ScratchBuilds.install(commit: Self.b, into: builds)
        let node = try await ScratchNode(scratch, build: a, installRoot: builds)
        defer { node.stop() }
        let lead = try await node.spawn("sleep 600", label: "Lead · project")
        let worker = try await node.spawn("sleep 600", label: "Worker: task-1")
        let client = try WireClient(node)
        #expect(await eventually { Self.host(client).live == 2 })
        let blockers = (Self.status(client)?["switchBlockers"]?.array ?? []).compactMap(\.string)
        #expect(blockers.count == 1 && blockers[0].hasPrefix("\(worker.tty) (Worker: task-1): ") && blockers[0].contains(" since "), "\(blockers)")
        let refused = try #require(WireClient.reply(client.request("build.switch", args: ["commit": .string(Self.b)])))
        let message = refused.error?.message ?? ""
        #expect(message.contains("\(worker.tty) (Worker: task-1): ") && message.contains(" since ") && !message.contains(lead.tty), "\(message)")
        let shown = try await node.run(["status", "--long"])
        #expect(shown.output.contains("a build switch waits now on: \(worker.tty) (Worker: task-1): "), "\(shown.output)")
        let said = try await node.runOnTerminal(["switch", Self.b, "--long"])
        #expect(said.status == 77 && said.output.contains("\(worker.tty) (Worker: task-1): ") && said.output.contains(" since "), "\(said.output)")
        #expect(Self.host(client).build == Self.a)
    }

    /// What a holder is said to be doing: its state since when by the node's scan, else how long it has been live.
    @Test func aHoldersStateIsSaidWithSinceWhen() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let session = StubHost.session(title: "Worker: x", tty: "ttypts4")
        let working = SwitchRequest.doing(session, status: .working, since: started, now: started.addingTimeInterval(37 * 60))
        #expect(working.hasPrefix("working since ") && working.hasSuffix(" (37 min)"), "\(working)")
        #expect(SwitchRequest.doing(session, status: .needsInput, since: started, now: started.addingTimeInterval(30)).hasSuffix("(under a minute)"))
        #expect(SwitchRequest.doing(session, status: .idle, since: started, now: started.addingTimeInterval(3 * 3600 + 5 * 60)).hasSuffix("(3 h 5 min)"))
        #expect(SwitchRequest.doing(session, status: nil, since: nil, now: Date()).hasPrefix("live since "))
    }

    /// The app's `aNewBuildWhoseProbeTakesTwentySecondsIsHandedOverWithNoFalseFailure`: the host holds the handover
    /// before its probe (`--handover-test-hold`) until the test releases it, once the switch has noted its wait past a
    /// request's 15 s. The outcome is handed over, never failed first; the live lead is kept.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func aSwitchWhoseProbeTakesTwentySecondsIsWaitedForWithNoFalseFailure() async throws {
        let builds = scratch.url("builds")
        let a = try ScratchBuilds.install(commit: Self.a, into: builds)
        try ScratchBuilds.install(commit: Self.b, into: builds)
        let hold = try scratch.shortFolder("vsh-hold").appendingPathComponent("release")
        let node = try await ScratchNode(scratch, build: a, hostArguments: ["--handover-test-hold", hold.path], installRoot: builds)
        defer { node.stop() }
        let lead = try await node.spawn("sleep 600", label: "Lead · project")
        let client = try WireClient(node)
        #expect(await eventually { Self.host(client).live == 1 })
        let log = node.root.appendingPathComponent("host.log").path
        func said() -> String { node.said + ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "") }
        async let asked = offPool { WireClient.reply(client.request("build.switch", args: ["commit": .string(Self.b)], timeout: SwitchRequest.longestWait)) }
        #expect(await eventually(timeout: 120) { said().contains("handing over to") }, "\(said())")
        #expect(await eventually(timeout: 60) { said().contains("build.switch: waiting for the new build's probe, 15 s") }, "\(said())")
        #expect(!said().contains("handover failed"), "\(said())")
        FileManager.default.createFile(atPath: hold.path, contents: nil)
        let reply = try #require(await asked, "\(said())")
        #expect(reply.ok && reply.result?["outcome"]?.string == "handed-over" && reply.result?["afterTheWait"]?.bool == false, "\(reply)\n\(said())")
        #expect(!said().contains("handover failed"), "\(said())")
        #expect(try node.sessions().contains { $0.id == lead.id && $0.isLive })
        #expect(Self.host(client).build == Self.b)
    }

    /// The rule on switches past the plan (ST-D15): a worker started while the host probes the target (held there by
    /// `--handover-test-hold`, as a lead's tool server can start one then) refuses the handover in the host's turn that
    /// would execute. The reply names decision 6 and the worker; the host's pid and build are unchanged, and both
    /// sessions are kept.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func aWorkerStartedDuringTheProbeRefusesTheSwitch() async throws {
        let builds = scratch.url("builds")
        let a = try ScratchBuilds.install(commit: Self.a, into: builds)
        try ScratchBuilds.install(commit: Self.b, into: builds)
        let hold = try scratch.shortFolder("vsh-hold").appendingPathComponent("release")
        let node = try await ScratchNode(scratch, build: a, hostArguments: ["--handover-test-hold", hold.path], installRoot: builds)
        defer { node.stop() }
        let lead = try await node.spawn("sleep 600", label: "Lead · project")
        let client = try WireClient(node)
        #expect(await eventually { Self.host(client).live == 1 })
        let log = node.root.appendingPathComponent("host.log").path
        func said() -> String { node.said + ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "") }
        async let asked = offPool { WireClient.reply(client.request("build.switch", args: ["commit": .string(Self.b)], timeout: SwitchRequest.longestWait)) }
        #expect(await eventually(timeout: 120) { said().contains("handing over to") }, "\(said())")
        let worker = try await node.spawn("sleep 600", label: "Worker: task-2")
        FileManager.default.createFile(atPath: hold.path, contents: nil)
        let reply = try #require(await asked, "\(said())")
        #expect(!reply.ok && reply.error?.code == "refused", "\(reply)\n\(said())")
        let message = reply.error?.message ?? ""
        #expect(message.hasPrefix("handover failed: Couldn't hand over: no switch of builds while a worker or verifier runs (decision 6"), "\(message)")
        #expect(message.contains(worker.tty) && message.contains("Worker: task-2") && !message.contains(lead.tty), "\(message)")
        let after = Self.host(client)
        #expect(after.pid == Int(node.hostPID) && after.build == Self.a && after.live == 2, "\(after)")
    }

    /// A switch to a build whose server's bytes differ (the node's every switch between commits; `ScratchBuilds` gives
    /// `B` the built server with one byte more): the new image ends the server child it carried, to start it again from
    /// `B`'s server, but only once that server has reconnected and replied: the reply reaches the command line, and
    /// the server is replaced after it, the lead kept.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func aSwitchToAnotherServerRepliesBeforeTheServerIsReplaced() async throws {
        let builds = scratch.url("builds")
        let a = try ScratchBuilds.install(commit: Self.a, into: builds)
        var bytes = try Data(contentsOf: builtProducts.appendingPathComponent(BuildInfo.server))
        bytes.append(0)
        let padded = scratch.url("padded-server")
        try bytes.write(to: padded)
        try ScratchBuilds.install(commit: Self.b, into: builds, replacing: [BuildInfo.server: padded.path])
        let node = try await ScratchNode(scratch, build: a, installRoot: builds)
        defer { node.stop() }
        let lead = try await node.spawn("sleep 600", label: "Lead · project")
        let client = try WireClient(node)
        #expect(await eventually { Self.host(client).live == 1 })
        let server = try #require(node.serverPID)
        let log = node.root.appendingPathComponent("host.log").path
        func said() -> String { node.said + ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "") }
        let reply = try #require(WireClient.reply(client.request("build.switch", args: ["commit": .string(Self.b)], timeout: SwitchRequest.longestWait)),
                                 "no reply\n\(said())")
        #expect(reply.ok && reply.result?["outcome"]?.string == "handed-over" && reply.result?["commit"]?.string == Self.b, "\(reply)\n\(said())")
        #expect(said().contains("server child pid \(server) carried over from the build before"), "\(said())")
        // Then it is replaced, from B's server: a new server answers.
        let replaced = await eventually(timeout: ServerChild.idleLimit + ServerChild.reconnectGrace + 60) {
            ((try? WireClient(node).hello).map { $0.server.pid != server }) == true
        }
        #expect(replaced, "\(said())")
        #expect(said().contains("server child pid \(server) ended for the new build's server"), "\(said())")
        #expect(try node.sessions().contains { $0.id == lead.id && $0.isLive })
        #expect(Self.host(try WireClient(node)).build == Self.b)
    }

    /// A rollback the host refuses: the node runs `B`, and `A` (the rollback's target in `status`) is a build whose probe
    /// refuses the host's state, as a build of another state format does (its host is `/bin/false`, recorded in its
    /// `build-info`, so the host's target check passes and its probe says no). `B` keeps running, and the reply names
    /// the host's reason.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func aRollbackTheHostRefusesSaysWhy() async throws {
        let builds = scratch.url("builds")
        try ScratchBuilds.install(commit: Self.a, into: builds, replacing: [BuildInfo.host: "/bin/false"])
        let b = try ScratchBuilds.install(commit: Self.b, into: builds)
        let node = try await ScratchNode(scratch, build: b, installRoot: builds)
        defer { node.stop() }
        let client = try WireClient(node)
        let target = try #require(Self.status(client)?["builds"]?["rollback"]?["commit"]?.string)
        #expect(target == Self.a)
        let refused = try #require(WireClient.reply(client.request("build.switch", args: ["commit": .string(target)], timeout: SwitchRequest.longestWait)))
        #expect(!refused.ok && refused.error?.code == "refused", "\(refused)")
        let message = refused.error?.message ?? ""
        // The host's own words: its probe of A's host exited 1 (`HostHandover.probe`).
        #expect(message.hasPrefix("handover failed: Couldn't hand over: the new build can't take over: it exited with status"), "\(message)\n\(node.said)")
        let after = Self.host(client)
        #expect(after.pid == Int(node.hostPID) && after.build == Self.b, "\(after)")
    }


    // MARK: switch and rollback from the command line (S8c)

    /// B's server: the built one with a byte more, so a switch between `A` and `B` replaces the server, as every switch
    /// between commits on the node does (`aSwitchToAnotherServerRepliesBeforeTheServerIsReplaced`).
    private func paddedServer() throws -> String {
        var bytes = try Data(contentsOf: builtProducts.appendingPathComponent(BuildInfo.server))
        bytes.append(0)
        let padded = scratch.url("padded-server")
        try bytes.write(to: padded)
        return padded.path
    }

    /// `A` and `B` installed under a scratch install root (`B`'s server padded when `paddedServer`): the root, and each
    /// build's folder.
    private func twoBuilds(paddedServer padded: Bool) throws -> (root: URL, a: URL, b: URL) {
        let root = scratch.url("builds")
        let a = try ScratchBuilds.install(commit: Self.a, into: root)
        let b = try ScratchBuilds.install(commit: Self.b, into: root, replacing: padded ? [BuildInfo.server: try paddedServer()] : [:])
        return (root, a, b)
    }

    /// The server's and the host's builds as `status --json` names them (`server.commit`, `host.notes.build`).
    private static func named(_ status: [String: Any]) -> (server: String?, host: String?) {
        ((status["server"] as? [String: Any])?["commit"] as? String,
         ((status["host"] as? [String: Any])?["notes"] as? [String: Any])?["build"] as? String)
    }

    /// Whether `status` names `commit` for the server and the host, within the time a switched server is replaced in
    /// (`ServerChild.idleLimit` after its link reconnected, and its new start).
    private static func everythingNames(_ node: ScratchNode, _ commit: String) async -> Bool {
        let deadline = MacTime.real.awake() + ServerChild.idleLimit + ServerChild.reconnectGrace + 90
        while MacTime.real.awake() < deadline {
            if let status = try? await node.statusJSON(), named(status).server == commit, named(status).host == commit { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    /// The lines of the tool servers' logs under the node's root (`MCPLog`, `debug/mcp-<role>-<pid>.log`) for `role`.
    private static func toolServerLogs(_ node: ScratchNode, role: String) -> [String] {
        let folder = node.root.appendingPathComponent("debug")
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("mcp-\(role)-") }.sorted()
            .map { (try? String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8)) ?? "" }
    }

    /// What a tool server logs of the build it runs (`ServerBuild.running`'s label: the commit's first 12 digits).
    private static func source(_ commit: String) -> String { "source: build \(commit.prefix(12))" }

    /// `switch B` on a pty, the code typed: the host hands over to `B`, and `status` names `B` for the host and, once the
    /// server is replaced from `B`'s, for the server; the host said `B`'s start line, with the unit's
    /// `SWIFT_BACKTRACE=enable=no` (ScratchNode gives it as the unit does). A scratch node has no unit to rewrite. Then
    /// `rollback` (its target `A`, shown with its `installs` line) restores all of `A`: on a node started on `B`, since a
    /// scratch host's handover doesn't carry its `--install-root` (stage 2's), so a scratch host hands over as an
    /// installed build only once.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func aSwitchHandsOverToTheInstalledBuildAndEverythingNamesIt() async throws {
        let builds = try twoBuilds(paddedServer: true)
        let node = try await ScratchNode(scratch, build: builds.a, installRoot: builds.root)
        defer { node.stop() }
        #expect(await Self.everythingNames(node, Self.a), "\(node.said)")
        let switched = try await node.runOnTerminal(["switch", Self.b, "--long"])
        #expect(switched.status == 0, "\(switched.output)\n\(node.said)")
        #expect(switched.output.contains("This switches the node from the build of commit \(Self.a) to the build of commit \(Self.b)"), "\(switched.output)")
        #expect(switched.output.contains("handed over") && switched.output.contains("build \(Self.b)"), "\(switched.output)")
        #expect(switched.output.contains("scratch node: no unit to rewrite"), "\(switched.output)")
        #expect(await Self.everythingNames(node, Self.b), "\(node.said)")
        // The host's start line, its pid kept, its build B's, with the unit's SWIFT_BACKTRACE.
        let startedB = HostStartLine.text(pid: node.hostPID, commit: Self.b, backtrace: "enable=no")
        #expect(node.said.contains(startedB), "\(node.said)")
        node.stop()

        // rollback, on a node running B: back to A, the installs record's line shown.
        let onB = try await ScratchNode(scratch, build: builds.b, installRoot: builds.root)
        defer { onB.stop() }
        #expect(await Self.everythingNames(onB, Self.b), "\(onB.said)")
        let installs = try String(contentsOf: builds.root.appendingPathComponent("installs"), encoding: .utf8)
        let lineA = try #require(installs.split(separator: "\n").first { $0.hasPrefix(Self.a) }.map(String.init))
        let back = try await onB.runOnTerminal(["rollback", "--long"])
        #expect(back.status == 0, "\(back.output)\n\(onB.said)")
        #expect(back.output.contains("This rolls the node back from the build of commit \(Self.b) to the build of commit \(Self.a)"), "\(back.output)")
        #expect(back.output.contains(lineA), "\(back.output)")
        #expect(back.output.contains("handed over") && back.output.contains("build \(Self.a)"), "\(back.output)")
        #expect(await Self.everythingNames(onB, Self.a), "\(onB.said)")
        #expect(onB.said.contains(HostStartLine.text(pid: onB.hostPID, commit: Self.a, backtrace: "enable=no")), "\(onB.said)")
        // Nothing before A to roll back to.
        let none = try await onB.runOnTerminal(["rollback", "--long"])
        #expect(none.status == 77 && none.output.contains("no build to roll back to"), "\(none.output)")
    }

    /// The reply reaches the command line before its server is replaced: `switch B` (`B`'s server's bytes differ, so
    /// the server is started again from `B`'s) has the handover named in the reply (never the lost reply's follow-up),
    /// then waits for `B`'s server (2026-11-24, `SwitchSettle`): when it exits 0 the old server was replaced, and the
    /// next command reaches the new one.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func theSwitchsReplyReachesTheCommandLineBeforeTheServerIsReplaced() async throws {
        let builds = try twoBuilds(paddedServer: true)
        let node = try await ScratchNode(scratch, build: builds.a, installRoot: builds.root)
        defer { node.stop() }
        let server = try #require(node.serverPID)
        let ended = "server child pid \(server) ended for the new build's server"
        let switched = try await node.runOnTerminal(["switch", Self.b, "--long"])
        #expect(switched.status == 0, "\(switched.output)\n\(node.said)")
        #expect(switched.output.contains("handed over") && switched.output.contains("build \(Self.b)"), "\(switched.output)")
        #expect(!switched.output.contains("reply was lost"), "the server was replaced before the command line had its reply: \(switched.output)")
        #expect(switched.output.contains("it starts in place of pid \(server)")
                && switched.output.contains("the new build's server answers"), "\(switched.output)")
        let hello = try WireClient(node).hello
        #expect(hello.server.pid != server && hello.server.commit == Self.b, "\(hello.server)")
        #expect(await eventually(timeout: 30) { node.said.contains(ended) }, "\(node.said)")
    }

    /// A new build's server slower than the switch's wait (here the wait cut to a second, as a loaded machine stretches
    /// the replacement past two minutes): the handover happened, so the switch exits 0, says so in a line, and its
    /// follow-up still runs; the new server answers later. The wait polls until the hello (the switch's own test above
    /// returns as soon as it comes).
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func aServerSlowerThanTheWaitIsSaidNotAFailure() async throws {
        let builds = try twoBuilds(paddedServer: true)
        let node = try await ScratchNode(scratch, build: builds.a, installRoot: builds.root)
        defer { node.stop() }
        let server = try #require(node.serverPID)
        let switched = try await node.runOnTerminal(["switch", Self.b, "--test-server-wait", "1", "--long"])
        #expect(switched.status == 0, "\(switched.output)\n\(node.said)")
        #expect(switched.output.contains("handed over to \(Self.b); its server hasn't answered yet after")
                && switched.output.contains("`vibeswitcher status` shows when it does"), "\(switched.output)")
        #expect(switched.output.contains("scratch node: no unit to rewrite"), "the follow-up didn't run: \(switched.output)")
        #expect(await eventually(timeout: ServerChild.idleLimit + ServerChild.reconnectGrace + 120) {
            ((try? WireClient(node).hello).map { $0.server.pid != server && $0.server.commit == Self.b }) == true
        }, "\(node.said)")
    }

    /// No controlling terminal (`setsid --wait`, stdin /dev/null): refused before anything is asked; the server records
    /// no request, and the host's pid and build are unchanged.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(5))) func aSwitchWithNoTerminalIsRefused() async throws {
        let builds = try twoBuilds(paddedServer: false)
        let node = try await ScratchNode(scratch, build: builds.a, installRoot: builds.root)
        defer { node.stop() }
        let ran = try await run(URL(fileURLWithPath: "/usr/bin/setsid"), ["--wait", commandLine.path, "switch", Self.b], environment: node.environment())
        #expect(ran.status == 77, "\(ran.output)\(ran.errors)")
        #expect(ran.errors.contains(TypedOutcome.noTerminal.refusal), "\(ran.errors)")
        let client = try WireClient(node)
        let accepted = (Self.status(client)?["accepted"]?.array ?? []).compactMap { $0["kind"]?.string }
        #expect(!accepted.contains("build.switch"), "\(accepted)")
        let host = Self.host(client)
        #expect(host.pid == Int(node.hostPID) && host.build == Self.a, "\(host)")
    }

    /// The review of S8c: a target whose tool server a worker rewrote (its `build-info` left alone) is refused before
    /// the confirmation and the code, with nothing switched: the host's handover checks only the host's and the
    /// server's images, so `B/bin/vibeswitcher-mcp` would otherwise be every later lead's tool server.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(5))) func aSwitchToATamperedBuildIsRefusedBeforeTheCode() async throws {
        let builds = try twoBuilds(paddedServer: false)
        let mcp = builds.b.appendingPathComponent("bin/vibeswitcher-mcp")
        chmod(mcp.path, 0o755)
        let handle = try FileHandle(forWritingTo: mcp)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        let node = try await ScratchNode(scratch, build: builds.a, installRoot: builds.root)
        defer { node.stop() }
        let switched = try await node.runOnTerminal(["switch", Self.b, "--long"])
        #expect(switched.status == 77, "\(switched.output)\n\(node.said)")
        #expect(switched.output.contains("isn't an installed build") && switched.output.contains("nothing was switched"), "\(switched.output)")
        #expect(!switched.output.contains("This switches the node"), "\(switched.output)")
        let client = try WireClient(node)
        let accepted = (Self.status(client)?["accepted"]?.array ?? []).compactMap { $0["kind"]?.string }
        #expect(!accepted.contains("build.switch"), "\(accepted)")
        let host = Self.host(client)
        #expect(host.pid == Int(node.hostPID) && host.build == Self.a, "\(host)")
    }

    /// The lead's call of 2026-11-16 (the S8c review's finding 5): while the seal holds a change under the builds folder
    /// that nobody accepted, `switch` is refused after its code with "accept the held config first", and the host stays
    /// on `A`; a change in the unit's folder likewise. Once accepted, the same switch hands over.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func aSwitchWhileABuildsFolderChangeIsHeldIsRefused() async throws {
        let builds = try twoBuilds(paddedServer: false)
        let node = try await ScratchNode(scratch, holdFirstLook: true, build: builds.a, installRoot: builds.root)
        defer { node.stop() }
        let repo = node.root.appendingPathComponent("repo")
        try await scratchRepository(repo)
        try EngineEndToEndTests.workflow(repo)
        try await node.acceptConfig(repo)
        func refused(_ name: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let switched = try await node.runOnTerminal(["switch", Self.b, "--long"])
            #expect(switched.status == 77, "\(switched.output)\n\(node.said)", sourceLocation: sourceLocation)
            #expect(switched.output.contains(name) && switched.output.contains(SwitchRequest.acceptFirst), "\(switched.output)",
                    sourceLocation: sourceLocation)
            let host = Self.host(try WireClient(node))
            #expect(host.pid == Int(node.hostPID) && host.build == Self.a, "\(host)", sourceLocation: sourceLocation)
        }

        // The builds folder (in the server's home: the user's node's install root).
        let held = node.home.appendingPathComponent(".vibeswitcher/v2/builds")
        try FileManager.default.createDirectory(at: held, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: held.appendingPathComponent("installs"))
        try await refused("~/.vibeswitcher/v2/builds")
        try await node.acceptConfig(repo)

        // The unit's folder.
        let units = node.home.appendingPathComponent(".config/systemd/user")
        try FileManager.default.createDirectory(at: units, withIntermediateDirectories: true)
        try Data("[Service]\n".utf8).write(to: units.appendingPathComponent("other.service"))
        try await refused("~/.config/systemd/user")
        try await node.acceptConfig(repo)

        let switched = try await node.runOnTerminal(["switch", Self.b, "--long"])
        #expect(switched.status == 0, "\(switched.output)\n\(node.said)")
        #expect(switched.output.contains("handed over") && switched.output.contains("build \(Self.b)"), "\(switched.output)")
    }

    /// A tool server started from `A/bin/vibeswitcher-mcp` before the switch (S9) still runs `A` after it: the same
    /// process, its image `A`'s, answering; its `BinaryWatch` sees no new build (the switch rewrites no build's files),
    /// so it never switches in place, and the build it reported is `A`.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(5))) func aRunningToolServerKeepsItsBuildAcrossASwitch() async throws {
        let builds = try twoBuilds(paddedServer: false)
        let node = try await ScratchNode(scratch, build: builds.a, installRoot: builds.root)
        defer { node.stop() }
        let program = builds.a.appendingPathComponent("bin/vibeswitcher-mcp")
        let identity = BinaryWatch.identity(of: program.path)
        let project = node.root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let tools = try ToolServer(program, root: project, environment: node.environment(), log: node.root.appendingPathComponent("tool-server.err"))
        defer { tools.stop() }
        try tools.send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": ["protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any], "clientInfo": ["name": "SwitchTests", "version": "1"]]])
        try #require(await tools.reply(1, within: 30) != nil, "\(tools.errors)")
        try tools.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        let pid = tools.process.processIdentifier
        let log = node.root.appendingPathComponent("debug/mcp-lead-\(pid).log")
        func logged() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
        #expect(await eventually { logged().contains(Self.source(Self.a)) }, "\(logged())")

        let switched = try await node.runOnTerminal(["switch", Self.b, "--long"])
        try #require(switched.status == 0, "\(switched.output)\n\(node.said)")
        #expect(Self.host(try WireClient(node)).build == Self.b)
        // It answers after the switch, the same process on A's image.
        try tools.send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        #expect(await tools.reply(2, within: 30) != nil, "\(tools.errors)")
        #expect(tools.process.isRunning)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe")) == program.resolvingSymlinksInPath().path)
        #expect(BinaryWatch(path: program.path, running: identity).update() == nil)
        #expect(!logged().contains("switching to the build at"), "\(logged())")
        #expect(logged().contains(Self.source(Self.a)) && !logged().contains(Self.source(Self.b)), "\(logged())")
    }

    /// A node holding its first look, a scratch repository's config and base accepted, room for a team: what a lead
    /// needs to start from the command line (`EngineEndToEndTests`).
    private func leadReadyNode(_ builds: (root: URL, a: URL, b: URL)) async throws -> (node: ScratchNode, repo: URL) {
        let node = try await ScratchNode(scratch, holdFirstLook: true, build: builds.a, installRoot: builds.root)
        let repo = node.root.appendingPathComponent("repo")
        try await scratchRepository(repo)
        try EngineEndToEndTests.workflow(repo)
        try await node.acceptConfig(repo)
        try await node.acceptBase(repo, from: Git.run(["rev-parse", "main"], in: repo.path).output)
        try node.noLoadHold(maxSessions: 10)
        return (node, repo)
    }

    /// The lead `lead FOLDER` starts, once the host lists it.
    private static func startLead(_ node: ScratchNode, _ repo: URL) async throws -> HostSession {
        let started = try await node.runOnTerminal(["lead", repo.path, "--goal", "a switch"])
        try #require(started.status == 0 && started.output.contains("the lead started"), "\(started.output)\n\(node.said)")
        var lead: HostSession?
        _ = await eventually(timeout: 60) {
            lead = (try? node.sessions())?.first { $0.isLive && $0.label.hasPrefix("Lead · ") }
            return lead != nil
        }
        return try #require(lead, "no live lead: \(node.said)")
    }

    /// A lead started after `switch B` (S9), once the server runs `B`'s, has its tool server from `B/bin`, and that
    /// tool server's build is `B`.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func aToolServerStartedAfterASwitchIsTheNewBuilds() async throws {
        let builds = try twoBuilds(paddedServer: true)
        let (node, repo) = try await leadReadyNode(builds)
        defer { node.stop() }
        let switched = try await node.runOnTerminal(["switch", Self.b, "--long"])
        try #require(switched.status == 0, "\(switched.output)\n\(node.said)")
        try #require(await Self.everythingNames(node, Self.b), "\(node.said)")
        let lead = try await Self.startLead(node, repo)
        let command = lead.command ?? ""
        #expect(command.contains("\(Self.b)/bin/vibeswitcher-mcp") && !command.contains("\(Self.a)/bin/"), "\(command.prefix(2000))")
        // Its tool server, started by its first call, is B's.
        let files = node.fake.files(terminal: lead.tty)
        try #require(await eventually(timeout: 60) { EngineEndToEndTests.state(files)["pid"] != nil }, "\(node.said)")
        try files.call("status", [:])
        #expect(await eventually(timeout: 120) { files.calls().count == 1 }, "\(EngineEndToEndTests.state(files))")
        let logs = Self.toolServerLogs(node, role: "lead")
        #expect(logs.contains { $0.contains(Self.source(Self.b)) } && !logs.contains { $0.contains(Self.source(Self.a)) || $0.contains("\(Self.a)/bin/") },
                "\(logs)")
    }

    /// ST-D16: a lead started before the switch keeps starting its workers with the old build's tool server: after
    /// `switch B`, its `start_worker` starts a worker whose MCP config names `A`'s tool server, which reports `A`.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func aWorkerStartedByAPreSwitchLeadKeepsTheOldBuild() async throws {
        // B's server padded, so the server too runs B before the worker starts (the review of S8c): only the lead's own
        // tool server's path then names A.
        let builds = try twoBuilds(paddedServer: true)
        let (node, repo) = try await leadReadyNode(builds)
        defer { node.stop() }
        let lead = try await Self.startLead(node, repo)
        #expect((lead.command ?? "").contains("\(Self.a)/bin/vibeswitcher-mcp"), "\((lead.command ?? "").prefix(2000))")
        let tools = node.fake.files(terminal: lead.tty)
        try #require(await eventually(timeout: 60) { EngineEndToEndTests.state(tools)["pid"] != nil }, "\(node.said)")
        try tools.call("add_task", ["title": "Write the parser", "goal": "Write the parser.", "acceptance": ["it builds"], "auto_advance": false])
        try #require(await eventually(timeout: 120) { tools.calls().count == 1 }, "\(tools.calls())")

        // The switch, with only the lead live.
        let switched = try await node.runOnTerminal(["switch", Self.b, "--long"])
        try #require(switched.status == 0, "\(switched.output)\n\(node.said)")
        try #require(await Self.everythingNames(node, Self.b), "\(node.said)")

        try tools.call("start_worker", ["task": "write-the-parser"])
        let worker = try await EngineEndToEndTests.connected(node, label: "Worker: Write the parser", calling: "progress",
                                                             ["task": "write-the-parser", "text": "starting"])
        try #require(await eventually(timeout: 120) { tools.calls().count == 2 }, "\(tools.calls())")
        #expect(tools.text(of: tools.calls()[1]).contains("Worker started on write-the-parser"), "\(tools.calls()[1])")
        let command = worker.command ?? ""
        #expect(command.contains("\(Self.a)/bin/vibeswitcher-mcp") && !command.contains("\(Self.b)/bin/"), "\(command.prefix(2000))")
        // Its tool server (and the keeper in front of it, whose log names the program it keeps) are A's.
        let logs = Self.toolServerLogs(node, role: "worker")
        #expect(logs.contains { $0.contains(Self.source(Self.a)) } && !logs.contains { $0.contains(Self.source(Self.b)) || $0.contains("\(Self.b)/bin/") },
                "\(logs)")
    }
}
