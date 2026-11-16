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
@Suite
struct SwitchTests {
    private let scratch = Scratch()

    static let a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    static let b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    static let c = "0123456789abcdef0123456789abcdef01234567"

    // MARK: The plan (the app's HostClientPlanTests, row 99)

    /// The app's `theBundledBuildIsUsed` and `noRestartIsOfferedWithoutAnOutdatedHost`: the build that runs is the one
    /// asked for, so nothing is switched (asked of a host already on it, with live teams or none).
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
        let text = NodeTexts.switch(from: Self.a, to: Self.b)
        #expect(text.contains(Self.a) && text.contains(Self.b), "\(text)")
        #expect(text.contains("keeps every session"), "\(text)")
        let count = try Regex("\\b[0-9]+ sessions?\\b")
        #expect(!text.contains("ends") && !text.contains(count), "\(text)")
        #expect(text.contains("a running team keeps its build until its lead restarts"), "\(text)")
        // ST-D16: who runs the old build's tool server after the switch (no worker is live at one: ST-D15).
        #expect(text.contains("a lead started before the switch keeps starting its workers with the old build's tool server"), "\(text)")
        #expect(text.contains("the seal holds every team until `vs config accept`") && text.contains("builds folder") && text.contains("unit"), "\(text)")
        // The code is still typed (EN-D5): `build.switch` is a state change in the user's voice.
        #expect(NodeWire.kinds["build.switch"] == .user && NodeWire.changesState("build.switch"))
    }

    /// `rollback`'s confirmation names where it goes and the `installs` line it read, which any worker can edit, so
    /// the user reads it before typing the code; the rest is the switch's.
    @Test func aRollbackSaysWhereItGoes() {
        let line = "\(Self.a) 2026-11-16T10:00:00Z"
        let text = NodeTexts.rollback(from: Self.b, to: Self.a, line: line)
        #expect(text.contains(Self.a) && text.contains(Self.b) && text.contains(line), "\(text)")
        #expect(text.contains("keeps every session") && text.contains("the seal holds every team until `vs config accept`"), "\(text)")
        // A line holding a control character is shown inert.
        let odd = NodeTexts.rollback(from: Self.b, to: Self.a, line: "\(Self.a) \u{1b}[2Jx")
        #expect(!odd.contains("\u{1b}"), "\(odd)")
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

    /// A link on a stand-in host whose pid is 31589 and whose notes name build `A`, a scratch install root holding
    /// `A` and `B` (folders only: the stand-in never runs them), and a switch on it whose notes are kept.
    final class StubWorld: @unchecked Sendable {
        let stub: StubHost
        let link: HostLink
        let installRoot: URL
        let notes = Locked<[String]>([])

        init(_ scratch: Scratch, onHandover: StubHost.OnHandover) async throws {
            stub = try StubHost(scratch, capabilities: [HostProtocol.Capability.inputUnits, HostProtocol.Capability.vaultV2,
                                                        HostProtocol.Capability.hostNotes, HostProtocol.Capability.handover])
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
        case .done(let value)?: return value["said"]?.string
        case .refused(_, let why)?: return why
        case nil: return nil
        }
    }

    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(2))) func aHandoverInPlaceIsHandedOver() async throws {
        let world = try await StubWorld(scratch, onHandover: .reExec(build: Self.b))
        let answer = await Self.answer(world.run())
        guard case .done(let value)? = answer else { Issue.record("\(String(describing: answer))"); return }
        #expect(value["outcome"]?.string == "handed-over" && value["commit"]?.string == Self.b && value["pid"]?.int == 31589, "\(value)")
        #expect(value["from"]?.string == Self.a && value["afterTheWait"]?.bool == false, "\(value)")
        #expect(world.handover == ["build.switch: handed over (pid 31589, build \(Self.b))"], "\(world.notes.value)")
    }

    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(2))) func theOldBuildAnsweringIsAFailure() async throws {
        let world = try await StubWorld(scratch, onHandover: .fallBack)
        let answer = await Self.answer(world.run())
        let failed = "handover failed: the old build answered (pid 31589, build \(Self.a); asked for \(Self.b))"
        #expect(answer == .refused(.refused, failed))
        #expect(world.handover == ["build.switch: " + failed], "\(world.notes.value)")
    }

    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(2))) func aDifferentHostAnsweringIsAFailure() async throws {
        let world = try await StubWorld(scratch, onHandover: .replacedBy(pid: 40000, build: Self.b))
        let answer = await Self.answer(world.run())
        let failed = "handover failed: a different host answered (pid 40000, build \(Self.b); was pid 31589)"
        #expect(answer == .refused(.refused, failed))
        #expect(world.handover == ["build.switch: " + failed], "\(world.notes.value)")
    }

    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(2))) func aHostThatGoesAwayIsAFailure() async throws {
        let world = try await StubWorld(scratch, onHandover: .quit)
        let answer = await Self.answer(world.run())
        let failed = "handover failed: the host (pid 31589) went away and no build answered"
        #expect(answer == .refused(.refused, failed))
        #expect(world.handover == ["build.switch: " + failed], "\(world.notes.value)")
        let link = world.link
        #expect(link.queue.sync { link.sessions.allSatisfy { !$0.isLive } })
    }

    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(2))) func aRefusalIsAFailure() async throws {
        let world = try await StubWorld(scratch, onHandover: .refuse("Couldn't hand over: probe failed."))
        let answer = await Self.answer(world.run())
        #expect(answer == .refused(.refused, "handover failed: Couldn't hand over: probe failed."))
        #expect(world.handover == ["build.switch: handover failed: Couldn't hand over: probe failed."], "\(world.notes.value)")
        // The host carried on: the link was never dropped.
        let link = world.link
        #expect(link.queue.sync { link.welcomes } == 1)
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
        #expect(value["said"]?.string == "handed over after the wait (pid 31589, build \(Self.b))" && value["afterTheWait"]?.bool == true, "\(value)")
        #expect(world.waiting == ["build.switch: waiting for the new build's probe, 1 s",
                                  "build.switch: no answer in 2 s; the connection stays open 60 s more"], "\(world.notes.value)")
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

        // The worker ends: with only the lead live, the host hands over to B.
        _ = try HostCall.request(.kill(id: worker.id), socket: node.socket, appKey: nil, timeout: 15)
        #expect(await eventually { Self.host(client).live == 1 })
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

    /// The app's `aNewBuildWhoseProbeTakesTwentySecondsIsHandedOverWithNoFalseFailure`: the host holds the handover
    /// before its probe (`--handover-test-hold`) until the test releases it, 20 s after the host said it hands over. The
    /// switch waits past a request's 15 s, saying so, and the outcome is handed over; the live lead is kept.
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
        try await Task.sleep(nanoseconds: 20_000_000_000)
        FileManager.default.createFile(atPath: hold.path, contents: nil)
        let reply = try #require(await asked, "\(said())")
        #expect(reply.ok && reply.result?["outcome"]?.string == "handed-over" && reply.result?["afterTheWait"]?.bool == false, "\(reply)\n\(said())")
        #expect(said().contains("build.switch: waiting for the new build's probe, 15 s"), "\(said())")
        #expect(!said().contains("handover failed"), "\(said())")
        #expect(try node.sessions().contains { $0.id == lead.id && $0.isLive })
        #expect(Self.host(client).build == Self.b)
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
}
