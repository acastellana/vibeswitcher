import Foundation
import Testing
@testable import VibeCore

/// team_plugins: workers and verifiers load none of the user's Claude Code plugins but those it names; the lead keeps
/// the user's. Each role's own `--settings` file turns the rest off (`enabledPlugins: {id: false}`, which Claude Code
/// takes over the user's settings for that process alone); nothing under the scratch home's `.claude` is written.
struct TeamPluginsTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    static let alpha = "alpha@market"
    static let beta = "beta@other-market"

    /// A scratch home whose Claude Code record lists plugins A and B as installed (and enabled in its user settings),
    /// each install pointing at a folder that isn't there: only the ids are read.
    func home() throws -> String {
        let home = temp.url("home").path
        let plugins = home + "/.claude/plugins"
        try FileManager.default.createDirectory(atPath: plugins, withIntermediateDirectories: true)
        let record: [String: Any] = ["version": 2, "plugins": [
            Self.alpha: [["scope": "user", "installPath": home + "/.claude/plugins/cache/market/alpha/1.0.0", "version": "1.0.0"]],
            Self.beta: [["scope": "user", "installPath": home + "/.claude/plugins/cache/other-market/beta/2.0.0", "version": "2.0.0"]],
        ]]
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: URL(fileURLWithPath: plugins + "/installed_plugins.json"))
        let settings: [String: Any] = ["enabledPlugins": [Self.alpha: true, Self.beta: true]]
        try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]).write(to: URL(fileURLWithPath: home + "/.claude/settings.json"))
        return home
    }

    /// Every file under `home`'s `.claude`, with its contents.
    func snapshot(_ home: String) -> [String: Data] {
        let base = home + "/.claude"
        var files: [String: Data] = [:]
        for case let path as String in FileManager.default.enumerator(atPath: base)?.allObjects ?? [] {
            if let data = FileManager.default.contents(atPath: base + "/" + path) { files[path] = data }
        }
        return files
    }

    func root() throws -> String {
        let url = temp.url("launch")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    func settings(_ launch: LeadLaunch.Prepared) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: launch.settingsFile))) as? [String: Any])
    }

    @Test func workersAndVerifiersTurnOffEveryPluginTeamPluginsDoesNotName() throws {
        let home = try home()
        let root = try root()
        let before = snapshot(home)
        for role in [LeadLaunch.Role.worker, .verifier] {
            let name = "\(role.rawValue)-x"
            // team_plugins empty: both off, in the session's own settings.
            let none = try LeadLaunch.prepare(role: role, root: root, task: "x", base: "claude", prompt: "p", start: "Go.", server: "/s",
                                              name: name, folder: temp.url("run-none-\(role.rawValue)"), home: home)
            #expect(try settings(none)["enabledPlugins"] as? [String: Bool] == [Self.alpha: false, Self.beta: false], "\(role)")
            #expect(none.command.contains("--settings '\(none.settingsFile)'"))
            // team_plugins: A (by its whole id, or by its plugin name alone): only B off.
            for allowed in [Self.alpha, "alpha"] {
                let some = try LeadLaunch.prepare(role: role, root: root, task: "x", base: "claude", prompt: "p", start: "Go.", server: "/s",
                                                  name: name, folder: temp.url("run-\(allowed)-\(role.rawValue)"), home: home, teamPlugins: [allowed])
                #expect(try settings(some)["enabledPlugins"] as? [String: Bool] == [Self.beta: false], "\(role) \(allowed)")
            }
            // Both named: nothing to turn off, and no key at all.
            let both = try LeadLaunch.prepare(role: role, root: root, task: "x", base: "claude", prompt: "p", start: "Go.", server: "/s",
                                              name: name, folder: temp.url("run-both-\(role.rawValue)"), home: home, teamPlugins: ["alpha", Self.beta])
            #expect(try settings(both)["enabledPlugins"] == nil)
            // VibeSwitcher's own hooks and tool server don't come from a plugin: still there.
            let hooks = try #require(try settings(none)["hooks"] as? [String: Any])
            #expect(hooks["PermissionRequest"] != nil && hooks["PreToolUse"] != nil, "\(role): \(hooks.keys.sorted())")
            let mcp = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: none.mcpFile))) as? [String: Any])
            #expect((mcp["mcpServers"] as? [String: Any])?["vibeswitcher"] != nil)
        }
        // The lead's launch is as before: no enabledPlugins, whatever team_plugins says.
        for allowed in [[], ["alpha"]] {
            let lead = try LeadLaunch.prepare(role: .lead, root: root, task: nil, base: "claude", prompt: "p", start: "Go.", server: "/s",
                                              name: "lead-x", folder: temp.url("run-lead-\(allowed.count)"), home: home, teamPlugins: allowed)
            #expect(try settings(lead)["enabledPlugins"] == nil)
        }
        // Nothing under the home's .claude was written.
        #expect(snapshot(home) == before)
    }

    @Test func theKnownPluginsAreTheRecordsIdsAndTheWorktreesOwnEnabledOnes() throws {
        let home = try home()
        let cwd = try root()
        #expect(LeadLaunch.knownPlugins(home: home, cwd: cwd) == [Self.alpha, Self.beta])
        // One the worktree's own project settings enable (on or off) is turned off too.
        try FileManager.default.createDirectory(atPath: cwd + "/.claude", withIntermediateDirectories: true)
        try #"{"enabledPlugins": {"gamma@market": true}}"#.write(toFile: cwd + "/.claude/settings.json", atomically: true, encoding: .utf8)
        try #"{"enabledPlugins": {"delta@market": false}}"#.write(toFile: cwd + "/.claude/settings.local.json", atomically: true, encoding: .utf8)
        #expect(LeadLaunch.knownPlugins(home: home, cwd: cwd) == [Self.alpha, Self.beta, "delta@market", "gamma@market"])
        // No record: none of the home's.
        #expect(LeadLaunch.knownPlugins(home: temp.url("empty-home").path, cwd: cwd) == ["delta@market", "gamma@market"])
        #expect(LeadLaunch.pluginsOff(role: .lead, allowed: [], known: [Self.alpha]).isEmpty)
        #expect(LeadLaunch.pluginsOff(role: .worker, allowed: ["beta@market"], known: [Self.beta]) == [Self.beta: false])
        // Names as team_plugins takes them.
        for good in ["alpha", "alpha@market", "swift-lsp@claude-plugins-official", "a.b_c"] { #expect(LeadLaunch.isPluginName(good), "\(good)") }
        for bad in ["", "@market", "alpha@", "a@b@c", "two words", "a/b", "a\"b"] { #expect(!LeadLaunch.isPluginName(bad), "\(bad)") }
    }

    @Test func claudeCodesOwnListingIsReadByIdOnly() throws {
        let listing = #"""
        login shell says hi
        [
          {"id": "alpha@market", "version": "1.0.0", "scope": "user", "enabled": true, "installPath": "/nowhere/alpha"},
          {"id": "design@synced", "enabled": true, "scope": "synced"},
          {"id": "prompt-cache-control@skills-dir", "enabled": true}
        ]
        """#
        #expect(LeadLaunch.pluginIDs(json: Data(listing.utf8)) == [Self.alpha, "design@synced", "prompt-cache-control@skills-dir"])
        #expect(LeadLaunch.pluginIDs(json: Data("[]".utf8)) == [])
        #expect(LeadLaunch.pluginIDs(json: Data("error: no such command".utf8)) == nil)
        // A login shell's own lines that start with "[" (before the list, or after it) aren't the list.
        let noisy = "[oh-my-zsh] would you like to update? [Y/n]\n[\n  {\"id\": \"alpha@market\", \"mcpServers\": [\"a\"]}\n]\n[done]\n"
        #expect(LeadLaunch.pluginIDs(json: Data(noisy.utf8)) == [Self.alpha])
        #expect(LeadLaunch.pluginIDs(json: Data("[warn] slow\n[{\"id\": \"x@y\"}]".utf8)) == ["x@y"])
        #expect(LeadLaunch.pluginIDs(json: Data("[warn] slow\n[not json]\n".utf8)) == nil)
        // The listing's ids join the record's.
        let home = try home()
        #expect(LeadLaunch.knownPlugins(home: home, cwd: try root(), listed: ["design@synced", Self.alpha]) == [Self.alpha, Self.beta, "design@synced"])
        // A program that isn't Claude Code lists nothing.
        let folder = temp.url("vibe").appendingPathComponent("tmp/plugins", isDirectory: true)
        let fake = temp.url("not-claude").path
        try "#!/bin/sh\necho not json\n".write(toFile: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake)
        #expect(LeadLaunch.listedPlugins(command: "FOO=1 '\(fake)' --model opus", folder: folder) == nil)
        // Claude Code's lists, run in the neutral folder: the folder it ran in is recorded outside it.
        let lister = temp.url("lists").path
        let ranIn = temp.url("ran-in").path
        try "#!/bin/sh\npwd -P > '\(ranIn)'\n[ \"$1 $2 $3\" = 'plugin list --json' ] && echo '[{\"id\": \"x@y\"}]'\n"
            .write(toFile: lister, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lister)
        #expect(LeadLaunch.listedPlugins(command: "'\(lister)' --model opus", folder: folder) == ["x@y"])
        #expect(try String(contentsOfFile: ranIn, encoding: .utf8) == Self.real(folder.path) + "\n")
        // The folder is made private, and stays empty.
        #expect(SessionTemp.isPrivate(folder))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        // Anything in it (project settings a worker could have put there): not listed at all.
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.removeItem(atPath: ranIn)
        #expect(LeadLaunch.listedPlugins(command: "'\(lister)'", folder: folder) == nil)
        #expect(!FileManager.default.fileExists(atPath: ranIn), "not run")
    }

    /// The listing the lead's runtime makes for a worker's or verifier's start runs in VibeSwitcher's folder, never in
    /// the task's worktree (whose project settings a worker wrote and a verifier deliberately never loads).
    @Test func theAppsListingNeverRunsInTheWorktree() throws {
        let root = try repo()
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        let lister = temp.url("lists").path
        let ranIn = temp.url("ran-in").path
        try "#!/bin/sh\npwd -P > '\(ranIn)'\necho '[]'\n".write(toFile: lister, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lister)
        // The runtime's call (`HostRuntime.pluginIDs`) takes no folder: the listing runs in its own, VibeSwitcher's
        // (`pluginListFolder`, under the sessions' temporary root; a scratch one of the same shape here, so the test
        // leaves nothing in that root).
        #expect(LeadLaunch.pluginListFolder == SessionTemp.root.appendingPathComponent("plugins", isDirectory: true))
        let folder = temp.url("vibe").appendingPathComponent("tmp/plugins", isDirectory: true)
        #expect(LeadLaunch.listedPlugins(command: "'\(lister)'", folder: folder) == [])
        let ran = try String(contentsOfFile: ranIn, encoding: .utf8).trimmingCharacters(in: .newlines)
        #expect(ran == Self.real(folder.path))
        #expect(!ran.hasPrefix(Self.real(worktree)) && !ran.hasPrefix(Self.real(root)), "\(ran)")
    }

    /// `path` as `pwd -P` prints it (/tmp is /private/tmp; Foundation's resolvingSymlinksInPath goes the other way).
    static func real(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    @Test func teamPluginsIsReadFromTheWorkflow() {
        #expect(LeadWorkflow.parse("---\nmax_workers: 2\n---\n").teamPlugins == [])
        #expect(LeadWorkflow.parse("---\nteam_plugins: alpha@market, beta ,\n---\n").teamPlugins == ["alpha@market", "beta"])
        #expect(LeadWorkflow.parse(LeadWorkflow.template).teamPlugins == [])
        #expect(LeadWorkflow.configurable.contains("team_plugins"))
    }

    func repo() throws -> String {
        let url = temp.url("repo")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    /// configure sets it, status says it in one line, and the worker and verifier the lead starts get it in their
    /// settings; the worker's brief says nothing of it.
    @Test func configureSetsItAndTheLeadsWorkersAndVerifiersGetIt() throws {
        let root = try repo()
        let home = try home()
        let runtime = FakeRuntime()
        // Claude Code's own listing also has one synced from the account, which its record of installs doesn't.
        runtime.plugins = [Self.alpha, "gamma@synced"]
        let lead = try lead(root, runtime)
        lead.power = { nil }
        lead.claudeHome = home
        // Before any start, nothing is listed: no count, and configure doesn't list them itself.
        let start = lead.call("configure", [:]).text
        #expect(start.contains("- team_plugins: none of the user's plugins (team_plugins empty); the lead and"), "\(start)")
        // Status says nothing of them in the default state (none wanted, no listing failed): configure shows it.
        #expect(!lead.call("status", [:]).text.contains("Team sessions' plugins"))
        #expect(runtime.pluginLists.isEmpty)
        #expect(lead.call("configure", ["team_plugins": "alpha, two words"]).isError)
        let set = lead.call("configure", ["team_plugins": " alpha ,, ", "merge_policy": "auto"])
        #expect(!set.isError, "\(set.text)")
        #expect(lead.workflow.teamPlugins == ["alpha"])
        let status = lead.call("status", [:]).text
        #expect(status.contains("Team sessions' plugins (workers, verifiers): alpha only; the lead and the user's own sessions keep theirs"), "\(status)")
        #expect(!lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]]).isError)
        let started = lead.call("start_worker", ["task": "add-b"])
        #expect(!started.isError, "\(started.text)")
        let folder = vault.runFolder(root: root, name: "worker-add-b")
        let worker = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("settings.json"))) as? [String: Any])
        #expect(worker["enabledPlugins"] as? [String: Bool] == [Self.beta: false, "gamma@synced": false])
        // Listed once, with the project's own Claude command; status and configure then say what it left off.
        #expect(runtime.pluginLists == [runtime.claude])
        #expect(lead.call("configure", [:]).text.contains("- team_plugins: alpha only; 2 of the user's 3 off in their sessions"))
        #expect(lead.call("status", [:]).text.contains("alpha only; 2 of the user's 3 off in their sessions"))
        #expect(runtime.pluginLists.count == 1, "configure and status list nothing")
        let prompt = try String(contentsOf: folder.appendingPathComponent("prompt.md"), encoding: .utf8)
        #expect(!prompt.contains("plugin"), "the brief says nothing new")
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try "bee\n".write(toFile: worktree + "/b.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "b.txt"], in: worktree)
        Git.run(["commit", "-q", "-m", "add b"], in: worktree)
        let reported = try seat("worker-add-b", runtime).call("report", doneReport("added"))
        #expect(!reported.isError, "\(reported.text)")
        let audit = lead.call("audit", ["task": "add-b"])
        #expect(!audit.isError, "\(audit.text)")
        let verifier = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: vault.runFolder(root: root, name: "verify-add-b")
            .appendingPathComponent("settings.json"))) as? [String: Any])
        #expect(verifier["enabledPlugins"] as? [String: Bool] == [Self.beta: false, "gamma@synced": false])
        // A listing that fails: status says some plugins may still load, not that none do.
        runtime.plugins = nil
        #expect(lead.listPlugins(command: runtime.claude, role: .verifier) == nil)
        let failed = lead.call("status", [:]).text
        #expect(failed.contains("alpha only wanted, but Claude Code's plugin list failed at the last team session's start: some of the user's plugins"), "\(failed)")
        #expect(failed.contains("may still load there"))
        // With team_plugins empty again, the failed listing is still news; once a listing works, status is quiet.
        #expect(!lead.call("configure", ["team_plugins": ""]).isError)
        #expect(lead.call("status", [:]).text.contains("Team sessions' plugins (workers, verifiers): none of the user's plugins (team_plugins empty) wanted, but Claude Code's plugin list failed"))
        runtime.plugins = [Self.alpha]
        #expect(lead.listPlugins(command: runtime.claude, role: .verifier) == [Self.alpha])
        #expect(!lead.call("status", [:]).text.contains("Team sessions' plugins"))
    }
}
