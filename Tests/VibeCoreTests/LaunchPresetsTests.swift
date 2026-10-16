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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
}
