import Foundation
import Testing
@testable import VibeCore

struct LaunchPresetsTests {
    @Test func builtInsCarryTheOldLaunchCommands() {
        let presets = LaunchPresets.builtIns(claudeCommand: "claude --model opus", codexCommand: " ")
        #expect(presets.global.map(\.name) == ["Claude", "Codex", "Shell"])
        #expect(presets.global[0].command == "claude --model opus")
        #expect(presets.global[1].command == "codex")
        #expect(presets.global.allSatisfy { $0.place == .window })
    }

    @Test func aProjectsDefaultComesFirstThenItsOwnThenGlobal() {
        var presets = LaunchPresets.builtIns()
        let own = LaunchPreset(name: "Opus", kind: .claude, command: "claude --model opus")
        presets.byProject["/p"] = [own]
        #expect(presets.presets(for: "/p").map(\.name) == ["Opus", "Claude", "Codex", "Shell"])
        presets.defaults["/p"] = presets.global[1].id
        #expect(presets.presets(for: "/p").map(\.name) == ["Codex", "Opus", "Claude", "Shell"])
        #expect(presets.defaultPreset(for: "/p")?.name == "Codex")
        #expect(presets.presets(for: "/other").map(\.name) == ["Claude", "Codex", "Shell"])
        #expect(presets.presets(for: nil).first?.name == "Claude")
        #expect(presets.preset(id: own.id) == own)
    }

    @Test func commandsForTheHost() {
        #expect(LaunchPlan.command(for: LaunchPreset(name: "S", kind: .shell, command: "ignored")) == nil)
        #expect(LaunchPlan.command(for: LaunchPreset(name: "C", kind: .codex, command: "  ")) == "codex")
        #expect(LaunchPlan.command(for: LaunchPreset(name: "C", kind: .claude, command: " claude -c ")) == "claude -c")
    }

    @Test func terminalLineQuotesFolderAndEnvironment() {
        let preset = LaunchPreset(name: "C", kind: .claude, command: "claude",
                                  env: ["B": "two words", "A": "it's", "9X": "bad"])
        #expect(LaunchPlan.terminalLine(for: preset, in: "/tmp/my dir")
                == "cd '/tmp/my dir' && A='it'\\''s' B='two words' claude")
        #expect(LaunchPlan.terminalLine(for: LaunchPreset(name: "S", kind: .shell, command: ""), in: "/x") == "cd '/x'")
    }

    @Test func resumeCommands() {
        #expect(LaunchPlan.resumeCommand(base: "claude --model opus", agent: .claude, sessionID: "abc")
                == "claude --model opus --resume 'abc'")
        #expect(LaunchPlan.resumeCommand(base: nil, agent: .codex, sessionID: "x-1") == "codex resume 'x-1'")
    }

    @Test func envNames() {
        #expect(LaunchPlan.validEnvName("ANTHROPIC_MODEL"))
        #expect(LaunchPlan.validEnvName("_x1"))
        #expect(!LaunchPlan.validEnvName("1A"))
        #expect(!LaunchPlan.validEnvName("A-B"))
        #expect(!LaunchPlan.validEnvName(""))
        #expect(!LaunchPlan.validEnvName("É"))
    }

    @Test func loadFallsBackToBuiltInsAndSaveRoundTrips() throws {
        let dir = scratchRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("presets.json")
        #expect(LaunchPresets.load(from: file, claudeCommand: "claude -c", codexCommand: "codex") ==
                LaunchPresets.builtIns(claudeCommand: "claude -c", codexCommand: "codex"))
        try Data("not json".utf8).write(to: file)
        #expect(LaunchPresets.load(from: file, claudeCommand: "claude", codexCommand: "codex").global.count == 3)
        var presets = LaunchPresets.builtIns()
        presets.byProject["/p"] = [LaunchPreset(name: "Mine", kind: .shell, command: "", keepShell: true, place: .terminal)]
        try presets.save(to: file)
        #expect(LaunchPresets.load(from: file, claudeCommand: "", codexCommand: "") == presets)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    /// E-01: one bad field used to drop the whole file for the built-ins, and the next edit saved them over it.
    @Test func aBadFieldKeepsTheRestAndTheFileIsCopiedAsideFirst() throws {
        let dir = scratchRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("presets.json")
        let opus = UUID()
        let text = """
        {"global": [
           {"id": "\(opus.uuidString)", "name": "Opus", "kind": "claude", "command": "claude --model opus"},
           {"name": "Phone", "kind": "codex", "command": "codex", "env": {}, "keepShell": false, "place": "phone"},
           {"name": "Broken", "kind": "robot", "command": "x"},
           {"kind": "shell"}
         ],
         "byProject": {"/p": [{"name": "Mine", "kind": "shell", "keepShell": "yes"}], "/q": 7},
         "defaults": {"/p": "\(opus.uuidString)", "/q": "not a uuid"}}
        """
        try Data(text.utf8).write(to: file)

        let loaded = LaunchPresets.loadChecked(from: file, claudeCommand: "claude", codexCommand: "codex")
        // A hand-added preset without env/keepShell/place reads with the defaults; a newer app's place resets.
        #expect(loaded.presets.global.map(\.name) == ["Opus", "Phone"])
        #expect(loaded.presets.global[0].id == opus && loaded.presets.global[0].command == "claude --model opus")
        #expect(loaded.presets.global[1].place == .window)
        #expect(loaded.presets.byProject["/p"]?.map(\.name) == ["Mine"])
        #expect(loaded.presets.byProject["/p"]?.first?.keepShell == false)
        #expect(loaded.presets.byProject["/q"] == nil)
        #expect(loaded.presets.defaults == ["/p": opus])
        #expect(loaded.problems == [
            "“Phone”: its place couldn't be read, so it's back to the default",
            "Global presets, preset 3: its kind couldn't be read; left out",
            "Global presets, preset 4: it has no name; left out",
            "“Mine”: its keepShell couldn't be read, so it's back to the default",
            "The presets for /q couldn't be read; left out",
            "The default preset for /q couldn't be read; left out",
        ])
        // The file as it was is kept before anything can be saved over it, and the notice says where.
        #expect(loaded.canSave)
        let backup = try #require(loaded.backup)
        #expect(backup.lastPathComponent == "presets.json.corrupt")
        #expect(try Data(contentsOf: backup) == Data(text.utf8))
        #expect(try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int == 0o600)
        let notice = try #require(loaded.notice)
        #expect(notice.contains("• Global presets, preset 3") && notice.contains(backup.path))

        // Loading again (no edit in between) keeps the one copy; a different bad file gets its own.
        #expect(LaunchPresets.loadChecked(from: file, claudeCommand: "", codexCommand: "").backup == backup)
        try Data("not json".utf8).write(to: file)
        let other = LaunchPresets.loadChecked(from: file, claudeCommand: "claude", codexCommand: "codex")
        #expect(other.presets == LaunchPresets.builtIns())
        #expect(other.problems == ["presets.json isn't readable JSON, so the built-in presets are used"])
        #expect(try other.backup.map { try Data(contentsOf: $0) } == Data("not json".utf8))
        #expect(other.backup != backup)
        #expect(try Data(contentsOf: backup) == Data(text.utf8))
    }

    @Test func aCleanFileHasNothingToSay() throws {
        let dir = scratchRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("presets.json")
        #expect(LaunchPresets.loadChecked(from: file, claudeCommand: "", codexCommand: "").notice == nil)
        try LaunchPresets.builtIns().save(to: file)
        let loaded = LaunchPresets.loadChecked(from: file, claudeCommand: "", codexCommand: "")
        #expect(loaded.notice == nil && loaded.backup == nil && loaded.canSave)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["presets.json"])
    }
}
