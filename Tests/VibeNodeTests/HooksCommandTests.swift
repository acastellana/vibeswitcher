import Foundation
import Testing
import VibeCore

/// `vibeswitcher hooks install|remove`, run as built in a scratch home, with the agents' config folders given by
/// CLAUDE_CONFIG_DIR and CODEX_HOME inside it: never the user's own ~/.claude, ~/.codex or ~/.vibeswitcher.
struct HooksCommandTests {
    private let scratch = Scratch()

    /// Claude Code's events the hook listens to (`HookInstaller.claudeEvents`).
    static let claudeEvents: Set<String> = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                                            "PermissionRequest", "Notification", "Stop", "PreCompact"]

    /// A scratch folder and its environment, with Claude Code's config folder at `claude-config` in it.
    private func setUp() throws -> (folder: URL, environment: [String: String], settings: URL) {
        let folder = scratch.url("hooks")
        let config = folder.appendingPathComponent("claude-config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("home"), withIntermediateDirectories: true)
        return (folder, scratchEnvironment(folder, ["CLAUDE_CONFIG_DIR": config.path]), config.appendingPathComponent("settings.json"))
    }

    private func object(_ url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// Every handler's command in `config`'s hooks, by event.
    private func commands(_ config: [String: Any]) -> [String: [String]] {
        var found: [String: [String]] = [:]
        for (event, groups) in config["hooks"] as? [String: Any] ?? [:] {
            for group in groups as? [[String: Any]] ?? [] {
                for handler in group["hooks"] as? [[String: Any]] ?? [] {
                    found[event, default: []].append(handler["command"] as? String ?? "")
                }
            }
        }
        return found
    }

    @Test func installWritesOurHandlersIntoTheConfigFolderGiven() async throws {
        let (folder, environment, settings) = try setUp()
        let ran = try await run(commandLine, ["hooks", "install", "--agent", "claude"], environment: environment)
        #expect(ran.status == 0, "\(ran.output)\(ran.errors)")

        let hook = URL(fileURLWithPath: environment["VIBESWITCHER_HOME"]!).appendingPathComponent("bin/vibeswitcher-hook").path
        let found = commands(try object(settings))
        #expect(Set(found.keys) == Self.claudeEvents)
        for event in Self.claudeEvents { #expect(found[event] == ["\(hook) claude"], "\(event)") }
        // Nothing in the home's own folders: the config folder given is the one.
        let home = folder.appendingPathComponent("home")
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path))
    }

    @Test func installCopiesBothBinariesExecutable() async throws {
        let (_, environment, _) = try setUp()
        let ran = try await run(commandLine, ["hooks", "install", "--agent", "claude"], environment: environment)
        #expect(ran.status == 0, "\(ran.output)\(ran.errors)")

        let bin = URL(fileURLWithPath: environment["VIBESWITCHER_HOME"]!).appendingPathComponent("bin")
        for name in ["vibeswitcher-hook", "vibeswitcher-mcp"] {
            let installed = bin.appendingPathComponent(name)
            let mode = try #require(try FileManager.default.attributesOfItem(atPath: installed.path)[.posixPermissions] as? Int, "\(name)")
            #expect(mode & 0o777 == 0o755, "\(name): \(String(mode, radix: 8))")
            #expect(try Data(contentsOf: installed) == Data(contentsOf: builtProducts.appendingPathComponent(name)), "\(name)")
        }
        // Nothing half-written left beside them.
        #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path).sorted() == ["vibeswitcher-hook", "vibeswitcher-mcp"])
    }

    @Test func removeLeavesTheUsersOwnHandlers() async throws {
        let (_, environment, settings) = try setUp()
        let own = "/usr/local/bin/notify-me done"
        try """
        {
          "model": "sonnet",
          "hooks": {
            "Stop": [{"hooks": [{"type": "command", "command": "\(own)"}]}]
          }
        }
        """.write(to: settings, atomically: true, encoding: .utf8)

        let install = try await run(commandLine, ["hooks", "install", "--agent", "claude"], environment: environment)
        #expect(install.status == 0, "\(install.output)\(install.errors)")
        #expect(commands(try object(settings))["Stop"]?.count == 2)
        let remove = try await run(commandLine, ["hooks", "remove", "--agent", "claude"], environment: environment)
        #expect(remove.status == 0, "\(remove.output)\(remove.errors)")

        let config = try object(settings)
        #expect(commands(config) == ["Stop": [own]])
        #expect(config["model"] as? String == "sonnet")
    }

    /// With no `--agent`, both agents' hooks go in, Codex's into CODEX_HOME's hooks.json.
    @Test func withNoAgentBothAreInstalledEachInItsOwnFolder() async throws {
        let (folder, given, settings) = try setUp()
        let codex = folder.appendingPathComponent("codex-home")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let environment = given.merging(["CODEX_HOME": codex.path]) { $1 }
        let ran = try await run(commandLine, ["hooks", "install"], environment: environment)
        #expect(ran.status == 0, "\(ran.output)\(ran.errors)")

        let hook = URL(fileURLWithPath: environment["VIBESWITCHER_HOME"]!).appendingPathComponent("bin/vibeswitcher-hook").path
        #expect(commands(try object(settings))["Stop"] == ["\(hook) claude"])
        #expect(commands(try object(codex.appendingPathComponent("hooks.json")))["Stop"] == ["\(hook) codex"])
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("home/.codex").path))

        let removed = try await run(commandLine, ["hooks", "remove"], environment: environment)
        #expect(removed.status == 0, "\(removed.output)\(removed.errors)")
        #expect(commands(try object(settings)).isEmpty)
        #expect(commands(try object(codex.appendingPathComponent("hooks.json"))).isEmpty)
    }

    @Test func aWrongCommandSaysHowAndChangesNothing() async throws {
        let (folder, environment, settings) = try setUp()
        for arguments in [["hooks"], ["hooks", "add"], ["hooks", "install", "--agent", "gemini"], ["hooks", "install", "--agent"]] {
            let ran = try await run(commandLine, arguments, environment: environment)
            #expect(ran.status == 64, "\(arguments)")
            #expect(ran.errors.contains("usage: vibeswitcher hooks install|remove"), "\(arguments): \(ran.errors)")
        }
        #expect(!FileManager.default.fileExists(atPath: settings.path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("vibeswitcher/bin").path))
    }
}
