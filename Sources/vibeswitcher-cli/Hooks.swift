import Foundation
import VibeCore

/// `vibeswitcher hooks install|remove [--agent claude|codex]`: puts VibeSwitcher's hooks into the agents' configs, or
/// takes them out, for one agent or (with no `--agent`) both. What the app's `HookSetup` and `HookBinary` do on the
/// Mac, without the vault's seal: there is no session host on Linux yet, and from the engine on its install step seals
/// the write.
///
/// Install copies `vibeswitcher-hook` and `vibeswitcher-mcp` from beside this program into `VibePaths.binDir` (each
/// written whole, 0755, and renamed into place, so a hook running meanwhile never sees half of one), then adds the
/// hooks (`HookInstaller.install`). Remove takes only the hooks out (`HookInstaller.uninstall`); the user's own
/// handlers stay in both. Each agent's config is where the agent reads it: `$CLAUDE_CONFIG_DIR/settings.json` and
/// `$CODEX_HOME/hooks.json` when those are set, else `~/.claude/settings.json` and `~/.codex/hooks.json`.
enum HooksCommand {
    static let usage = "usage: vibeswitcher hooks install|remove [--agent claude|codex]"

    /// The programs an agent's session runs that install puts in `VibePaths.binDir`.
    static let programs = ["vibeswitcher-hook", "vibeswitcher-mcp"]

    static func run(_ arguments: [String]) -> Int32 {
        guard let action = arguments.first, ["install", "remove"].contains(action) else { return misuse() }
        var agents = Agent.allCases
        switch Array(arguments.dropFirst()) {
        case []: break
        case let words where words.count == 2 && words[0] == "--agent":
            guard let agent = Agent(rawValue: words[1]) else { return misuse() }
            agents = [agent]
        default: return misuse()
        }

        let environment = ProcessInfo.processInfo.environment
        var failed = false
        if action == "install" {
            do {
                try installPrograms()
            } catch {
                say("The hook's programs couldn't be put in \(VibePaths.binDir.path): \(error.localizedDescription)", error: true)
                return 1
            }
        }
        for agent in agents {
            let url = configURL(for: agent, environment: environment)
            do {
                if action == "install" {
                    try HookInstaller.install(agent: agent, at: url)
                    say("\(agent.displayName): hooks installed in \(url.path)")
                    if agent == .codex {
                        say("  Codex asks to trust new hooks: run /hooks in Codex and trust the vibeswitcher-hook entries.")
                    }
                } else {
                    try HookInstaller.uninstall(agent: agent, at: url)
                    say("\(agent.displayName): hooks removed from \(url.path)")
                }
            } catch {
                say("\(agent.displayName): \(url.path): \(error.localizedDescription)", error: true)
                failed = true
            }
        }
        return failed ? 1 : 0
    }

    /// Where `agent` reads its hooks: the folder its own variable names when that's an absolute path, else the
    /// installer's place in the home (`HookInstaller.configURL`).
    static func configURL(for agent: Agent, environment: [String: String]) -> URL {
        let variable = agent == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"
        guard let folder = environment[variable], folder.hasPrefix("/") else { return HookInstaller.configURL(for: agent) }
        return URL(fileURLWithPath: folder).appendingPathComponent(agent == .claude ? "settings.json" : "hooks.json")
    }

    /// Copies each of `programs` from beside this executable into `VibePaths.binDir`, unless the copy there is
    /// already the same.
    static func installPrograms() throws {
        guard let own = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "this program's own folder couldn't be found"])
        }
        let bin = VibePaths.binDir
        try VibePaths.ensurePrivate(bin)
        for name in programs {
            let source = own.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: source) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "\(source.path) couldn't be read"])
            }
            let target = bin.appendingPathComponent(name)
            if (try? Data(contentsOf: target)) == data,
               (try? FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int) == 0o755 { continue }
            let temporary = bin.appendingPathComponent(".\(name).\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try VibePaths.writePrivate(data, to: temporary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
            guard rename(temporary.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    private static func misuse() -> Int32 {
        say(usage, error: true)
        return 64
    }

    private static func say(_ line: String, error: Bool = false) {
        try? (error ? FileHandle.standardError : FileHandle.standardOutput).write(contentsOf: Data((line + "\n").utf8))
    }
}
