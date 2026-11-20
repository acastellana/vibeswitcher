import Foundation
import Testing
@testable import VibeCore

/// A run the tool server starts gets its project's settings for its box (the session sandbox plan's SB-D16, SB6), as the
/// user accepted them in the vault: the hook site end to end. Each run here is a worker's pre-done check (`report`
/// done, `LeadToolset.doneCheck`), started by its tool server through the built tool server as the launcher (named, as
/// `BranchRunHostTests` names it), into a real box.
///
/// Every box is planned over scratch folders: a scratch account home (a key in its `.ssh`, a shared folder outside any
/// repository, a stand-in for swiftly's folder), the project in it, the vault beside it. The machine's own paths are
/// only looked at.
@Suite(.enabled(if: !Platform.CodeIdentity.isAvailable && Platform.Sandbox.probe().why == nil,
                "needs a box: \(Platform.Sandbox.probe().why ?? "the Mac has none")"), .timeLimit(.minutes(10)))
struct BranchRunPolicyTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    static let launcher = SandboxPolicy.resolved(builtProducts.appendingPathComponent("vibeswitcher-mcp").path)
    /// What a run with `sandbox: off` says first (`BranchRun.plainNotice`), spelled out so this compiles without it.
    static let plainNotice = "vibeswitcher: this branch run is in no box: the project's workflow.md says sandbox: off, as the user accepted it."

    /// The scratch account and its project: task "add-b" started and committed, its pre-done check `check`.
    struct Team {
        let account: String
        let root: String
        let shared: String
        let lead: LeadToolset
        let worker: LeadToolset
        let runtime: FakeRuntime
        var workflowPath: String { root + "/.vibeswitcher/workflow.md" }
        var scope: BranchRun.Scope { BranchRun.Scope(launcher: BranchRunPolicyTests.launcher, accountHome: account) }
    }

    /// `check`: the pre-done check, given the account's home.
    func team(check: (String) -> String) throws -> Team {
        let files = FileManager.default
        let made = temp.url("account")
        try files.createDirectory(at: made, withIntermediateDirectories: true)
        let account = SandboxPolicy.resolved(made.path)
        let root = account + "/projects/app", shared = account + "/shared"
        for folder in [account + "/.ssh", shared, root] { try files.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        try "a key\n".write(toFile: account + "/.ssh/id_ed25519", atomically: true, encoding: .utf8)
        try "shared secret\n".write(toFile: shared + "/notes.txt", atomically: true, encoding: .utf8)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["merge_policy": "auto", "test_command": "true", "done_check_command": check(account)]).isError)
        #expect(!lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]]).isError)
        let started = lead.call("start_worker", ["task": "add-b"])
        #expect(!started.isError, "\(started.text)")
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try "bee\n".write(toFile: worktree + "/b.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "b.txt"], in: worktree)
        Git.run(["commit", "-q", "-m", "add b"], in: worktree)
        return Team(account: account, root: root, shared: shared, lead: lead, worker: try seat("worker-add-b", runtime), runtime: runtime)
    }

    /// Writes `changes` into the project's workflow.md, as anyone of the team could; `accept`: and records them in the
    /// vault as the user's, as `config accept` does.
    func write(_ changes: [(key: String, value: String)], in team: Team, accept: Bool) throws {
        let current = FileManager.default.contents(atPath: team.workflowPath) ?? Data()
        try LeadWorkflow.write(LeadWorkflow.updating(current, with: changes), to: team.workflowPath)
        guard accept else { return }
        let written = LeadWorkflow.load(from: team.workflowPath)
        try vault.setGuardedSettings(LeadVault.guardedHashes(written).filter { key, _ in changes.contains { $0.key == key } }, root: team.root)
    }

    /// The worker's done report, its pre-done check started by its tool server with the built launcher.
    func report(_ team: Team) -> MCPToolResult {
        BranchRun.with(team.scope) { team.worker.call("report", doneReport("added b.txt")) }
    }

    @Test func aRunsBoxShowsWhatTheAcceptedSandboxReadListsAndNothingAnEditNamesUnaccepted() throws {
        let team = try team { "cat \(RecentProjects.shellQuote($0))/shared/notes.txt" }
        // The standard box: the shared folder isn't there.
        let standard = report(team)
        #expect(standard.isError && standard.text.contains("No such file"), "\(standard.text)")

        // Named in workflow.md but not accepted (the vault's record is still "unset"): the run is as before.
        try write([("sandbox_read", team.shared)], in: team, accept: false)
        let unaccepted = report(team)
        #expect(unaccepted.isError && unaccepted.text.contains("No such file"), "\(unaccepted.text)")

        // Accepted: the run reads it.
        try write([("sandbox_read", team.shared)], in: team, accept: true)
        let accepted = report(team)
        #expect(!accepted.isError && accepted.text.contains("Its pre-done check passed"), "\(accepted.text)")
    }

    @Test func anEditAfterTheAcceptGivesTheRunNothingItNames() throws {
        let team = try team { "cat \(RecentProjects.shellQuote($0))/other/more.txt" }
        let other = team.account + "/other"
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        try "more\n".write(toFile: other + "/more.txt", atomically: true, encoding: .utf8)
        try write([("sandbox_read", team.shared)], in: team, accept: true)
        // A worker adds a folder to the accepted list: not the user's, so it widens nothing.
        try write([("sandbox_read", team.shared + ", " + other)], in: team, accept: false)
        let edited = report(team)
        #expect(edited.isError && edited.text.contains("No such file"), "\(edited.text)")
    }

    @Test func aKeyNamingAHiddenFolderFailsTheRunClosedSayingWhichKey() throws {
        let team = try team { _ in "touch ran.txt" }
        try write([("sandbox_read", "~/.ssh")], in: team, accept: true)
        let refused = report(team)
        #expect(refused.isError && refused.text.contains("wasn't started") && refused.text.contains("sandbox_read")
                    && refused.text.contains(".ssh"), "\(refused.text)")
        // Nothing of it ran.
        #expect(!FileManager.default.fileExists(atPath: Worktrees.path(root: team.root, slug: "add-b") + "/ran.txt"))
    }

    @Test func sandboxOffRunsTheWrapperPlainAndSaysSoFirst() throws {
        let team = try team { "cat \(RecentProjects.shellQuote($0))/shared/notes.txt; exit 1" }
        try write([("sandbox", "off")], in: team, accept: true)
        let ran = report(team)
        // Plain: the shared folder is read with no sandbox_read; and its output says so first.
        #expect(ran.isError && ran.text.contains("shared secret"), "\(ran.text)")
        let notice = try #require(ran.text.range(of: BranchRunPolicyTests.plainNotice), "\(ran.text)")
        #expect(notice.upperBound <= (ran.text.range(of: "shared secret")?.lowerBound ?? ran.text.startIndex), "\(ran.text)")
    }

    /// A made-up tool installed in the account (a folder of its own, its data and a program in its `bin`), and another
    /// the settings don't name.
    func install(in team: Team) throws -> (tool: String, other: String) {
        let tool = team.account + "/tools/made-up", other = team.account + "/tools/other"
        for (folder, program, says) in [(tool, "made-up", "made-up ran"), (other, "other-tool", "other ran")] {
            try FileManager.default.createDirectory(atPath: folder + "/bin", withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: folder + "/share", withIntermediateDirectories: true)
            try "#!/bin/sh\necho '\(says)'\n".write(toFile: folder + "/bin/" + program, atomically: true, encoding: .utf8)
            chmod(folder + "/bin/" + program, 0o755)
        }
        try "the tool's data\n".write(toFile: tool + "/share/data.txt", atomically: true, encoding: .utf8)
        return (tool, other)
    }

    /// What the check of `aMadeUpTool…` runs: through the variable and the PATH only, saying what it finds.
    static let toolCheck = "cat \"$MADE_UP_HOME/share/data.txt\"; made-up; command -v other-tool || echo 'no other-tool'; exit 1"

    /// The general case: any tool the user installed in the account, shown read-only by `sandbox_read` and told where it
    /// is by `sandbox_env` (`~` the account's home), its `bin` first on the PATH; one the settings don't name isn't
    /// found. Boxed, and with no box (a run on a scratch home already hides the account's installs).
    @Test func aMadeUpToolIsFoundThroughTheVariableAndPathTheAcceptedSettingsName() throws {
        let team = try team { _ in BranchRunPolicyTests.toolCheck }
        _ = try install(in: team)
        try write([("sandbox_read", "~/tools/made-up"), ("sandbox_env", "MADE_UP_HOME=~/tools/made-up, PATH=~/tools/made-up/bin")], in: team, accept: true)
        // Boxed.
        let boxed = report(team)
        // Unboxed: no launcher, the scratch account's home for `~`.
        let plain = BranchRun.with(BranchRun.Scope(accountHome: team.account)) { team.worker.call("report", doneReport("added b.txt")) }
        for ran in [boxed, plain] {
            #expect(ran.isError && ran.text.contains("the tool's data") && ran.text.contains("made-up ran") && ran.text.contains("no other-tool")
                        && !ran.text.contains("other ran"), "\(ran.text)")
        }
    }

    @Test func aValueUnderAHiddenFolderFailsTheRunClosedNamingTheKey() throws {
        let team = try team { _ in "touch ran.txt" }
        try write([("sandbox_env", "KEY=~/.ssh/id_ed25519")], in: team, accept: true)
        for ran in [report(team), BranchRun.with(BranchRun.Scope(accountHome: team.account)) { team.worker.call("report", doneReport("added b.txt")) }] {
            #expect(ran.isError && ran.text.contains("wasn't started") && ran.text.contains("sandbox_env") && ran.text.contains(".ssh"), "\(ran.text)")
            #expect(!FileManager.default.fileExists(atPath: Worktrees.path(root: team.root, slug: "add-b") + "/ran.txt"))
        }
    }

    @Test func anUnacceptedSandboxEnvChangesNothing() throws {
        let team = try team { _ in "echo \"home=[$MADE_UP_HOME]\"; exit 1" }
        _ = try install(in: team)
        try write([("sandbox_env", "MADE_UP_HOME=~/tools/made-up")], in: team, accept: false)
        for ran in [report(team), BranchRun.with(BranchRun.Scope(accountHome: team.account)) { team.worker.call("report", doneReport("added b.txt")) }] {
            #expect(ran.isError && ran.text.contains("home=[]"), "\(ran.text)")
        }
    }

    /// A run sees the variables its settings name and none other from outside beyond the box's allow-list.
    @Test func aRunSeesTheVariablesItsSettingsNameAndNoOtherFromOutside() throws {
        // Short, so it all fits in the output's end the refusal shows: every name on one line.
        let team = try team { _ in "echo \"made=$MADE_UP_HOME\"; printf names:; env | cut -d= -f1 | paste -sd, -; exit 1" }
        let (tool, _) = try install(in: team)
        try write([("sandbox_read", "~/tools/made-up"), ("sandbox_env", "MADE_UP_HOME=~/tools/made-up")], in: team, accept: true)
        let ran = report(team)
        #expect(ran.isError && ran.text.contains("made=" + SandboxPolicy.resolved(tool) + "\n"), "\(ran.text)")
        let lines = ran.text.split(separator: "\n")
        let names = Set(try #require(lines.last { $0.hasPrefix("names:") }, "\(ran.text)").dropFirst("names:".count).split(separator: ",").map(String.init))
        #expect(names.contains("PATH") && names.contains("HOME") && names.contains("MADE_UP_HOME"), "\(ran.text)")
        // What the tool server's own environment has outside the allow-list doesn't reach the run. (XDG_DATA_DIRS is
        // the login shell's own: /etc/profile sets it, inside as outside.)
        let allowed = SandboxPlanner.allowed.union(["HOME", "PATH", "SHELL", "TMPDIR", "VIBESWITCHER_ROLE", "CFFIXED_USER_HOME", "PWD", "SHLVL", "_",
                                                    "OLDPWD", "XDG_DATA_DIRS", TestLock.heldVariable, TestLock.coresVariable, TestLock.directoryVariable])
        let outside = ProcessInfo.processInfo.environment.keys.filter { name in
            !allowed.contains(name) && !["LC_", "VIBESWITCHER_HEAVY_"].contains { name.hasPrefix($0) }
        }
        #expect(!outside.isEmpty)
        for name in outside { #expect(!names.contains(name), "\(name) reached a branch run") }
    }

    /// A verifier's commands are started by its own Claude Code through its shell prefix, not by the tool server: the
    /// settings are fixed when the tool server starts the verifier, read as for its own runs, and carried in the
    /// verifier's settings and environment (`BranchRun.policyVariable`), which the prefix boxes each command by
    /// (`BranchRunHostTests.aVerifiersCommandIsBoxedByTheSettingsItWasStartedWith`).
    @Test func aVerifierIsStartedCarryingTheAcceptedSettingsForItsCommandsBoxes() throws {
        let team = try team { _ in "true" }
        try write([("sandbox_read", team.shared), ("sandbox_env", "MADE_UP_HOME=~/shared")], in: team, accept: true)
        #expect(!report(team).isError)
        // The scratch account's home for `~`; no launcher, so the audit's own run is plain.
        let audit = BranchRun.with(BranchRun.Scope(accountHome: team.account)) { team.lead.call("audit", ["task": "add-b"]) }
        #expect(!audit.isError, "\(audit.text)")
        let spawn = try #require(team.runtime.spawned.last { $0.command.contains("--name 'verify-add-b'") }, "\(team.runtime.spawned)")
        func read(_ carried: String?) -> (read: [String], environment: [String: String])? {
            guard let data = carried?.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let policy = object["policy"] as? [String: Any] else { return nil }
            return (policy["read"] as? [String] ?? [], policy["environment"] as? [String: String] ?? [:])
        }
        let variable = "VIBESWITCHER_BRANCH_RUN_POLICY", shared = SandboxPolicy.resolved(team.shared)
        let given = read(team.runtime.environments[spawn.id]?[variable])
        #expect(given?.read == [shared] && given?.environment == ["MADE_UP_HOME": shared], "\(team.runtime.environments[spawn.id] ?? [:])")
        let settings = try LaunchArguments.json("--settings", in: spawn.command)
        #expect(read((settings["env"] as? [String: Any])?[variable] as? String)?.read == [shared], "\(settings)")
    }
}
