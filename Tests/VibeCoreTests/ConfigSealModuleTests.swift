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
}
