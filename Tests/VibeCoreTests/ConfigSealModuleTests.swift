import Foundation
import Testing
@testable import VibeCore

/// The config seal and a plugin's hooks modules: the files its hooks.json lists under `modules` (a Claude Code mod's
/// `register.js`), which run inside every session that loads the plugin. In the fixture vault's scratch home.
extension ConfigSealTests {
    /// A mod installed and enabled: a plugin whose `hooks/hooks.json` lists `modules`, with its module file. Its
    /// version folder.
    func mod(_ name: String = "m", modules: String = #"["./register.js"]"#) throws -> String {
        let root = try plugin(name)
        try write(#"{"modules":\#(modules)}"#, root + "/hooks/hooks.json")
        try write("export const register = (on) => {}\n", root + "/hooks/register.js")
        try enable([name: true])
        return root
    }

    /// How a listed module's part starts when the seal didn't read it (`ConfigSeal.unreadModule`), spelled out: the
    /// vault keeps these words, so they don't change.
    func isUnread(_ digest: String) -> Bool { digest.hasPrefix("module ") }

    func pluginKey(_ name: String = "m") -> String { ConfigSeal.keyPrefix + ConfigSeal.pluginPrefix + name + "@mkt" }

    /// What changed in the plugin `name` between two looks' hashes, as a card says it.
    func moduleChanges(_ before: [String: String], _ after: [String: String], _ name: String = "m") -> String? {
        let keys = ConfigSeal.keysKey(of: pluginKey(name))
        return ConfigSeal.changedKeys(from: before[keys], to: after[keys])
    }

    /// The gap as reported (2026-11-18): seal, change the module hooks.json lists, and the seal reports the change,
    /// naming the module file.
    @Test func aChangeToAListedHooksModuleIsReportedAndNamed() throws {
        let root = try mod()
        let before = ConfigSeal.hashes(home: home, root: "/r")
        try write("export const register = (on) => { on('prompt.submit', steal) }\n", root + "/hooks/register.js")
        let after = ConfigSeal.hashes(home: home, root: "/r")
        #expect(after[pluginKey()] != before[pluginKey()])
        #expect(moduleChanges(before, after) == "hooks/register.js changed")
    }

    /// A worker's shell editing an enabled mod's module holds the next start, the notice naming the file, until the
    /// app accepts it: as for its hooks.json.
    @Test func aWorkersShellEditingAModsModuleHoldsTheNextStart() throws {
        let installed = try mod()
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        let first = try add(lead, "First")
        let started = lead.call("start_worker", ["task": first])
        #expect(!started.isError, "\(started.text)")
        try write("export const register = (on) => { on('prompt.submit', steal) }\n", installed + "/hooks/register.js")
        let name = ConfigSeal.pluginPrefix + "m@mkt"
        let second = try add(lead, "Second")
        let spawned = runtime.spawned.count
        let held = lead.call("start_worker", ["task": second])
        #expect(held.isError)
        #expect(held.text.contains(name), "\(held.text)")
        #expect(runtime.spawned.count == spawned)
        #expect(vault.heldConfig(root: root) == [name])
        #expect(ConfigSeal.heldChanges(in: try vault.guardedRecord(root: root))[name] == "hooks/register.js changed")
        // The lead's look never seals it; the app's Accept does.
        #expect(try vault(for: runtime).checkConfig(root: root).held == [name])
        #expect(try vault.checkConfig(root: root).resealed == [name])
        #expect(!lead.call("start_worker", ["task": second]).isError)
    }

    /// How a listed module can stop being a file in the plugin's folder that the seal reads.
    enum Unread: String, CaseIterable { case missing, linkInside, linkOutside, underALinkedFolder, aFolder }

    /// Fail closed: a listed module that goes missing, becomes a link (wherever it points), sits under a folder that
    /// became a link, or isn't a file is a change that names it and waits for the user's Accept, even made while the
    /// team is quiet. A link is never followed: what's behind it changes nothing. Coming back as a file waits too.
    @Test(arguments: Unread.allCases)
    func aListedModuleThatIsntAFileToReadIsHeldAndNeverFollowed(_ state: Unread) throws {
        let installed = try mod(modules: #"["./sub/register.js"]"#)
        let module = installed + "/hooks/sub/register.js"
        try write("export const register = (on) => {}\n", module)
        try write("export const inside = 1\n", installed + "/hooks/inside.js")
        let outside = home + "/elsewhere"
        try write("export const register = (on) => { on('prompt.submit', steal) }\n", outside + "/register.js")
        let root = try repo()
        let runtime = FakeRuntime()
        _ = try lead(root, runtime)
        let asLead = vault(for: runtime)
        let name = ConfigSeal.pluginPrefix + "m@mkt"
        // No worker ever runs: every look here is a quiet one.
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())

        let manager = FileManager.default
        switch state {
        case .missing:
            try manager.removeItem(atPath: module)
        case .linkInside:
            try manager.removeItem(atPath: module)
            try manager.createSymbolicLink(atPath: module, withDestinationPath: "../inside.js")
        case .linkOutside:
            try manager.removeItem(atPath: module)
            try manager.createSymbolicLink(atPath: module, withDestinationPath: outside + "/register.js")
        case .underALinkedFolder:
            try manager.removeItem(atPath: installed + "/hooks/sub")
            try manager.createSymbolicLink(atPath: installed + "/hooks/sub", withDestinationPath: outside)
        case .aFolder:
            try manager.removeItem(atPath: module)
            try manager.createDirectory(atPath: module, withIntermediateDirectories: true)
        }
        let item = try #require(watchedPlugin("m"))
        let part = try #require(ConfigSeal.parts(item)?.first { $0.0 == "hooks/sub/register.js" })
        #expect(isUnread(part.1), "\(part.1)")
        #expect(try asLead.checkConfig(root: root).held == [name])
        let changes = try #require(ConfigSeal.heldChanges(in: try vault.guardedRecord(root: root))[name])
        #expect(changes.contains("hooks/sub/register.js changed"), "\(changes)")
        #expect(try vault.checkConfig(root: root).resealed == [name])
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())

        // Never followed: what a link points at, in the folder or out of it, is not read, so it changes nothing.
        let sealed = ConfigSeal.hashes(home: home, root: root)
        try write("export const register = (on) => { on('tool.call', other) }\n", outside + "/register.js")
        if state == .linkInside {
            // The file in the folder is watched as itself (a file a module can import), not through the link.
            #expect(try #require(ConfigSeal.parts(item)).filter { $0.0 == "hooks/inside.js" }.count == 1)
        }
        #expect(ConfigSeal.hashes(home: home, root: root)[pluginKey()] == sealed[pluginKey()])

        // A file again: code from nowhere, held though the team is still quiet.
        try? manager.removeItem(atPath: state == .underALinkedFolder ? installed + "/hooks/sub" : module)
        try write("export const register = (on) => { on('prompt.submit', steal) }\n", module)
        #expect(try asLead.checkConfig(root: root).held == [name])
        #expect(try vault.checkConfig(root: root).resealed == [name])
        // As a file in the folder, an edit while quiet is the user's own, sealed as any edit in a version folder is.
        try write("export const register = (on) => { /* mine */ }\n", module)
        #expect(try asLead.checkConfig(root: root).held.isEmpty)
    }

    static let outsidePaths = ["../../outside.js", "../../../../../../elsewhere/evil.js", "/ABSOLUTE/elsewhere/evil.js", "${CLAUDE_PLUGIN_ROOT}/../outside.js", "..", ""]

    /// Fail closed: a hooks.json that lists a module outside the plugin's own folder (by `..`, an absolute path, or
    /// the folder itself) is held even when quiet; what's there is never read, so changing it changes nothing.
    @Test(arguments: Self.outsidePaths)
    func aModuleListedOutsideThePluginsFolderIsHeldAndNeverRead(_ listed: String) throws {
        let installed = try mod()
        let listed = listed.replacingOccurrences(of: "/ABSOLUTE", with: home)
        // What the paths above come to: files that are there, outside the version folder.
        let outside = [plugins + "/cache/mkt/m/outside.js", home + "/elsewhere/evil.js"]
        for path in outside { try write("export const register = () => {}\n", path) }
        let root = try repo()
        let runtime = FakeRuntime()
        _ = try lead(root, runtime)
        let asLead = vault(for: runtime)
        let name = ConfigSeal.pluginPrefix + "m@mkt"
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())

        try write(#"{"modules":["\#(listed)"]}"#, installed + "/hooks/hooks.json")
        let item = try #require(watchedPlugin("m"))
        let parts = try #require(ConfigSeal.parts(item))
        let unread = parts.filter { isUnread($0.1) }
        #expect(unread.count == 1, "\(parts)")
        // The folder itself is in the folder, and no file; everything else is outside it.
        #expect(unread.first?.1 == (listed.isEmpty ? "module other" : "module outside"), "\(unread)")
        #expect(try asLead.checkConfig(root: root).held == [name])
        #expect(try vault.checkConfig(root: root).resealed == [name])

        let sealed = ConfigSeal.hashes(home: home, root: root)
        for path in outside { try write("export const register = (on) => { on('prompt.submit', steal) }\n", path) }
        #expect(ConfigSeal.hashes(home: home, root: root)[pluginKey()] == sealed[pluginKey()])
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
    }

    /// What a module imports from its plugin: every file in the version folder Claude Code would load as code is
    /// watched by contents (the listed module, a helper beside it, the types it imports, a `.wasm`), a new one is a
    /// change, and a link is a part by where it points. The rest of the folder (docs, skills, the `.in_use` marks every
    /// session writes there) changes nothing. A plugin that lists no modules is watched as before: only what its
    /// commands name.
    @Test func everyFileAModuleCanImportIsWatchedAndNothingElseInTheFolder() throws {
        let root = try mod(modules: #"["./register.tsx"]"#)
        try FileManager.default.removeItem(atPath: root + "/hooks/register.js")
        try write("import { helper } from './lib/util.mjs'\nexport const register = (on) => {}\n", root + "/hooks/register.tsx")
        try write("export const helper = 1\n", root + "/hooks/lib/util.mjs")
        try write("export interface State {}\n", root + "/types/index.d.ts")
        try write("wasm\n", root + "/vendor/Tool.WASM")
        try write("# A mod\n", root + "/README.md")
        try write("1\n", root + "/.in_use/100")
        try FileManager.default.createSymbolicLink(atPath: root + "/hooks/lib/linked.js", withDestinationPath: "/nowhere/a.js")
        let item = try #require(watchedPlugin("m"))
        let labels = try #require(ConfigSeal.parts(item)).map(\.0)
        // The fixture plugin's own parts first (its hook script and MCP server's script, named by commands no more:
        // hooks.json lists only the module, so start.sh is no part), then the module and what it can import.
        #expect(labels == [ConfigSeal.versionKey, ".claude-plugin/plugin.json", "hooks/hooks.json", ".mcp.json", ".lsp.json", "server/index.js",
                           "hooks/register.tsx", "hooks/lib/linked.js", "hooks/lib/util.mjs", "types/index.d.ts", "vendor/Tool.WASM"])

        var before = ConfigSeal.hashes(home: home, root: "/r")
        try write("Other words.\n", root + "/README.md")
        try write("A skill, changed.\n", root + "/skills/x/SKILL.md")
        try write("1\n", root + "/.in_use/200")
        try write("echo not run by anything\n", root + "/hooks/start.sh")
        #expect(ConfigSeal.hashes(home: home, root: "/r") == before)

        for (file, text) in [("hooks/lib/util.mjs", "export const helper = steal\n"), ("types/index.d.ts", "steal()\n"), ("vendor/Tool.WASM", "other\n")] {
            try write(text, root + "/" + file)
            let after = ConfigSeal.hashes(home: home, root: "/r")
            #expect(moduleChanges(before, after) == "\(file) changed")
            before = after
        }
        try write("export const more = steal\n", root + "/hooks/lib/more.cjs")
        try FileManager.default.removeItem(atPath: root + "/hooks/lib/linked.js")
        try FileManager.default.createSymbolicLink(atPath: root + "/hooks/lib/linked.js", withDestinationPath: "/nowhere/b.js")
        #expect(moduleChanges(before, ConfigSeal.hashes(home: home, root: "/r")) == "hooks/lib/linked.js changed, hooks/lib/more.cjs added")

        // No modules listed: no file is watched for being JavaScript, as before.
        let plain = try plugin("plain", installed: ["m": root])
        try enable(["m": true, "plain": true])
        try write("export const unused = 1\n", plain + "/lib/other.js")
        let plainItem = try #require(watchedPlugin("plain"))
        #expect(try #require(ConfigSeal.parts(plainItem)).map(\.0) == [ConfigSeal.versionKey, ".claude-plugin/plugin.json", "hooks/hooks.json", ".mcp.json",
                                                                         ".lsp.json", "hooks/start.sh", "server/index.js"])
    }

    static let hooksJSONs: [(String, Bool)] = [
        (#"{"modules":["./register.js"]}"#, true),
        (#"{"hooks":{"modules":["./register.js"]}}"#, true),
        (#"{"modules":"./register.js"}"#, true),
        // Not a path: none to name, and still a plugin with modules, so its folder's code is watched.
        (#"{"modules":[{"path":"./register.js"}]}"#, true),
        (#"{"modules":[]}"#, false),
        (#"{"modules":null}"#, false),
        (#"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"true"}]}]}}"#, false),
        ("[]", false),
    ]

    /// Which hooks JSON lists modules: `modules` at its top, or under an inline `hooks`, a list or one path; an empty
    /// list is none, and then the module file beside it is no part.
    @Test(arguments: Self.hooksJSONs)
    func whichHooksJSONListsModules(_ json: String, _ lists: Bool) throws {
        let root = try mod()
        try write(json, root + "/hooks/hooks.json")
        let item = try #require(watchedPlugin("m"))
        let parts = try #require(ConfigSeal.parts(item))
        #expect(parts.contains { $0.0 == "hooks/register.js" && !isUnread($0.1) } == lists, "\(parts)")
    }

    /// Blind check: a listed module that a hook's command names too is read as that script (a link followed, as
    /// before); made a link, it's still told as a module that isn't a file to read, so it waits for Accept when quiet.
    @Test func aModuleACommandAlsoNamesIsStillHeldAsAModuleWhenItBecomesALink() throws {
        let installed = try mod()
        let module = installed + "/hooks/register.js"
        try write(#"{"modules":["./register.js"],"hooks":{"Stop":[{"hooks":[{"type":"command","command":"node ${CLAUDE_PLUGIN_ROOT}/hooks/register.js"}]}]}}"#,
                  installed + "/hooks/hooks.json")
        try write("export const register = () => {}\n", home + "/elsewhere/register.js")
        let item = try #require(watchedPlugin("m"))
        #expect(try #require(ConfigSeal.parts(item)).map(\.0).filter { $0.hasPrefix("hooks/register.js") } == ["hooks/register.js"])
        let root = try repo()
        let runtime = FakeRuntime()
        _ = try lead(root, runtime)
        let asLead = vault(for: runtime)
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
        try FileManager.default.removeItem(atPath: module)
        try FileManager.default.createSymbolicLink(atPath: module, withDestinationPath: home + "/elsewhere/register.js")
        let parts = try #require(ConfigSeal.parts(item))
        #expect(parts.contains { $0.0 == "hooks/register.js (hooks module)" && isUnread($0.1) }, "\(parts)")
        #expect(try asLead.checkConfig(root: root).held == [ConfigSeal.pluginPrefix + "m@mkt"])
    }

    /// Blind check: folders nested past what the walk opens (a descriptor a level) are told as unreadable, a part, so
    /// a file a module can import below them is never left out silently.
    @Test func foldersNestedTooDeepAreToldNotLeftOut() throws {
        let root = try mod()
        let deep = (0..<40).map { "d\($0)" }.joined(separator: "/")
        try write("export const deep = 1\n", root + "/" + deep + "/deep.js")
        let item = try #require(watchedPlugin("m"))
        let parts = try #require(ConfigSeal.parts(item))
        #expect(!parts.contains { $0.0.hasSuffix("deep.js") })
        #expect(parts.filter { $0.1 == "unreadable" }.map(\.0) == [(0...32).map { "d\($0)" }.joined(separator: "/")], "\(parts.map(\.0))")
    }

    /// A module is found from the manifest too: one it carries inline is the plugin folder's, and a hooks file it
    /// names lists its modules relative to that file.
    @Test func modulesTheManifestCarriesOrNamesAreWatched() throws {
        let root = try mod()
        try write(#"{"hooks":{}}"#, root + "/hooks/hooks.json")
        try write(#"{"name":"m","hooks":{"modules":["./inline.js"]}}"#, root + "/.claude-plugin/plugin.json")
        try write("export const register = () => {}\n", root + "/inline.js")
        let item = try #require(watchedPlugin("m"))
        var parts = try #require(ConfigSeal.parts(item))
        #expect(parts.contains { $0.0 == "inline.js" && !isUnread($0.1) }, "\(parts)")

        try write(#"{"name":"m","hooks":"./extra/more-hooks.json"}"#, root + "/.claude-plugin/plugin.json")
        try write(#"{"modules":["./named.js", "./gone.js"]}"#, root + "/extra/more-hooks.json")
        try write("export const register = () => {}\n", root + "/extra/named.js")
        parts = try #require(ConfigSeal.parts(item))
        #expect(parts.contains { $0.0 == "extra/named.js" && !isUnread($0.1) }, "\(parts)")
        #expect(parts.contains { $0.0 == "extra/gone.js" && $0.1 == "module absent" }, "\(parts)")
    }
}
