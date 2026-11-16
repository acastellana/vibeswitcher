import Foundation
import Testing
@testable import VibeCore
import VibeNode

/// `switch` and `rollback` between installed builds (the start plan's S8a to S8c; the security architecture document's
/// S8, the rule on switches, and S9). S8a's cases: the plan the server makes of a switch (`SwitchPlan`, the app's
/// `HostClientPlanTests`, port-map row 99), the rollback's target from `<prefix>/installs`, the confirmations
/// (`NodeTexts.switch`, `rollback`; the app's `HostRestartTests`' first case, row 100), and the command line's
/// follow-up after the host handed over (`SwitchFollowUp`), driven in process on a unit `NodeUnit` wrote, a scratch
/// prefix and a recording `systemctl`. The plan and the texts are pure (the Mac runs them); the follow-up's cases are
/// Linux's.
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
    /// `current` naming `A`, and the unit `NodeUnit.text` wrote for `A`.
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
            try StartCommandTests.makeBuild(prefix: prefix, commit: SwitchTests.a)
            try StartCommandTests.makeBuild(prefix: prefix, commit: SwitchTests.b)
            try FileManager.default.createSymbolicLink(atPath: prefix.appendingPathComponent("current").path, withDestinationPath: SwitchTests.a)
            unit = NodeUnit.Inputs(prefix: prefix.path, commit: SwitchTests.a, home: home.path,
                                   swiftBin: home.appendingPathComponent(".local/share/swiftly/bin").path,
                                   nodeBin: home.appendingPathComponent(".nvm/versions/node/v22.1.0/bin").path)
            try NodeUnit.text(unit).get().write(to: manager.unitFile, atomically: true, encoding: .utf8)
        }

        static let hostPid: pid_t = 4242

        /// The follow-up to `commit`, the host seen by `seen` (its pid unchanged and on `commit` by default).
        func apply(_ commit: String, seen: SwitchFollowUp.Host? = nil, hostCheck: (() -> Result<SwitchFollowUp.Host, StartRefusal>)? = nil) -> Result<Void, StartRefusal> {
            SwitchFollowUp.apply(tools: manager.tools, prefix: prefix.path, commit: commit, hostPid: Self.hostPid,
                                 hostCheck: hostCheck ?? { .success(seen ?? SwitchFollowUp.Host(pid: Self.hostPid, build: commit)) })
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
    }

    /// ST-D23: after the follow-up in a scratch home, the seal's entries for the builds folder and the unit folder both
    /// changed, so the next look holds every team until `config accept`.
    ///
    /// The entries are the ones S7's `LinuxSealList.homeEntries` lists (`.vibeswitcher/v2/builds`,
    /// `.config/systemd/user`). `LinuxSealList` is S7's, not yet in this lane (2026-11-16): the case fingerprints them
    /// as `.folder`s, as today's `ConfigSeal` reads them; once S7 lands it takes `LinuxSealList.watched(home:uid:)`'s
    /// entries for those names.
    @Test(NodeTraits.linuxOnly) func aSwitchLeavesTheSealHoldingUntilAccepted() throws {
        let world = try World(scratch)
        let entries = [".vibeswitcher/v2/builds", ".config/systemd/user"].map {
            ConfigSeal.Watched(name: "~/" + $0, path: world.home.appendingPathComponent($0).path, kind: .folder)
        }
        let before = entries.map(ConfigSeal.fingerprint)
        #expect(before.allSatisfy { $0 != nil })
        #expect(entries.map(ConfigSeal.fingerprint) == before)
        try world.apply(Self.b).get()
        let after = entries.map(ConfigSeal.fingerprint)
        for (index, entry) in entries.enumerated() {
            #expect(after[index] != nil && after[index] != before[index], "\(entry.name) unchanged")
        }
    }
}
