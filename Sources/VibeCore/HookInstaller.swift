import Foundation

/// Adds/removes VibeSwitcher's entries in `~/.claude/settings.json` and `~/.codex/hooks.json`.
/// Other hooks are left untouched; our entries are recognised by the hook binary name in `command`.
public enum HookInstaller {
    public static let marker = "vibeswitcher-hook"

    static let claudeEvents = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                               "PermissionRequest", "Notification", "Stop", "PreCompact"]
    static let codexEvents = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                              "PermissionRequest", "Stop", "Interrupt", "PreCompact"]
    static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PermissionRequest"]

    public static func configURL(for agent: Agent) -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        switch agent {
        case .claude: return home.appendingPathComponent(".claude/settings.json")
        case .codex: return home.appendingPathComponent(".codex/hooks.json")
        }
    }

    public static func command(for agent: Agent, hookBinary: String = VibePaths.hookBinary.path) -> String {
        "\(hookBinary) \(agent.rawValue)"
    }

    // MARK: Pure transforms (tested)

    public static func isInstalled(in config: [String: Any]) -> Bool {
        guard let hooks = config["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { groups in
            (groups as? [[String: Any]])?.contains(where: groupIsOurs) ?? false
        }
    }

    public static func removingOurs(from config: [String: Any]) -> [String: Any] {
        var config = config
        guard var hooks = config["hooks"] as? [String: Any] else { return config }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.filter { !groupIsOurs($0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        config["hooks"] = hooks.isEmpty ? nil : hooks
        return config
    }

    public static func addingOurs(to config: [String: Any], agent: Agent,
                                  hookBinary: String = VibePaths.hookBinary.path) -> [String: Any] {
        var config = removingOurs(from: config)
        var hooks = config["hooks"] as? [String: Any] ?? [:]
        let events = agent == .claude ? claudeEvents : codexEvents
        for event in events {
            var handler: [String: Any] = ["type": "command", "command": command(for: agent, hookBinary: hookBinary)]
            handler["timeout"] = 5
            var group: [String: Any] = ["hooks": [handler]]
            // Claude wants an explicit catch-all matcher on tool events; Codex matchers are regexes
            // and treat an omitted matcher as "match everything".
            if agent == .claude, toolEvents.contains(event) { group["matcher"] = "*" }
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(group)
            hooks[event] = groups
        }
        config["hooks"] = hooks
        return config
    }

    static func groupIsOurs(_ group: [String: Any]) -> Bool {
        guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
        return handlers.contains { ($0["command"] as? String)?.contains(marker) ?? false }
    }

    // MARK: File IO

    public static func isInstalled(agent: Agent) -> Bool {
        isInstalled(in: readConfig(configURL(for: agent)) ?? [:])
    }

    /// Installs (or reinstalls) our hooks. The previous file is kept once as `<name>.vibeswitcher-backup`.
    public static func install(agent: Agent) throws {
        let url = configURL(for: agent)
        let current = try readConfigThrowing(url)
        try backupOnce(url)
        try writeConfig(addingOurs(to: current, agent: agent), to: url)
    }

    public static func uninstall(agent: Agent) throws {
        let url = configURL(for: agent)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let current = try readConfigThrowing(url)
        try writeConfig(removingOurs(from: current), to: url)
    }

    static func readConfig(_ url: URL) -> [String: Any]? { try? readConfigThrowing(url) }

    static func readConfigThrowing(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return object
    }

    static func backupOnce(_ url: URL) throws {
        let backup = url.appendingPathExtension("vibeswitcher-backup")
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: url, to: backup)
        }
    }

    static func writeConfig(_ config: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: config,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }
}
