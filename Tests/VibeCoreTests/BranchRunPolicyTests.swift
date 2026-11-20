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
        return Team(account: account, root: root, shared: shared, lead: lead, worker: try seat("worker-add-b", runtime))
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

    @Test func aRunSeesSwiftlysFoldersAndNoOtherVariableFromOutsideTheAllowList() throws {
        // Short, so it all fits in the output's end the refusal shows: swiftly's lines, then every name on one line.
        let team = try team { _ in "env | grep ^SWIFTLY_; printf names:; env | cut -d= -f1 | paste -sd, -; exit 1" }
        let swiftly = team.account + "/.local/share/swiftly"
        for folder in ["bin", "toolchains"] { try FileManager.default.createDirectory(atPath: swiftly + "/" + folder, withIntermediateDirectories: true) }
        try "{}\n".write(toFile: swiftly + "/config.json", atomically: true, encoding: .utf8)
        try write([("sandbox_read", "~/.local/share/swiftly")], in: team, accept: true)
        let ran = report(team)
        #expect(ran.isError)
        var seen: [String: String] = [:]
        let lines = ran.text.split(separator: "\n")
        for line in lines where line.hasPrefix("SWIFTLY_") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            seen[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        let names = try #require(lines.last { $0.hasPrefix("names:") }, "\(ran.text)").dropFirst("names:".count).split(separator: ",").map(String.init)
        #expect(names.contains("PATH") && names.contains("HOME"), "\(ran.text)")
        for name in names where seen[name] == nil { seen[name] = "" }
        let real = SandboxPolicy.resolved(swiftly)
        // Each the folder swiftly would use outside: the tool server's own value where it has one (one this test's
        // runner may have names the account's real swiftly, which this scratch box doesn't show, so the run is told
        // nothing of it), else swiftly's default under the (scratch) account's home, which the box shows.
        let given = ProcessInfo.processInfo.environment.filter { $0.value.hasPrefix("/") }
        let home = given["SWIFTLY_HOME_DIR"] ?? (given["XDG_DATA_HOME"] ?? team.account + "/.local/share") + "/swiftly"
        let folders = ["SWIFTLY_HOME_DIR": home, "SWIFTLY_BIN_DIR": given["SWIFTLY_BIN_DIR"] ?? home + "/bin",
                       "SWIFTLY_TOOLCHAINS_DIR": given["SWIFTLY_TOOLCHAINS_DIR"] ?? home + "/toolchains"]
        for (name, spelled) in folders {
            let folder = SandboxPolicy.resolved(spelled)
            #expect(seen[name] == (folder == real || folder.hasPrefix(real + "/") ? folder : nil), "\(name): \(ran.text)")
        }
        if given["SWIFTLY_HOME_DIR"] == nil && given["XDG_DATA_HOME"] == nil {
            #expect(seen["SWIFTLY_HOME_DIR"] == real, "\(ran.text)")
        }
        // What the tool server's own environment has outside the allow-list doesn't reach the run. (XDG_DATA_DIRS is
        // the login shell's own: /etc/profile sets it, inside as outside.)
        let allowed = SandboxPlanner.allowed.union(["HOME", "PATH", "SHELL", "TMPDIR", "VIBESWITCHER_ROLE", "CFFIXED_USER_HOME", "PWD", "SHLVL", "_",
                                                    "OLDPWD", "XDG_DATA_DIRS", TestLock.heldVariable, TestLock.coresVariable, TestLock.directoryVariable])
        let outside = ProcessInfo.processInfo.environment.keys.filter { name in
            !allowed.contains(name) && !["LC_", "VIBESWITCHER_HEAVY_", "SWIFTLY_"].contains { name.hasPrefix($0) }
        }
        #expect(!outside.isEmpty)
        for name in outside { #expect(seen[name] == nil, "\(name) reached a branch run") }
    }
}
