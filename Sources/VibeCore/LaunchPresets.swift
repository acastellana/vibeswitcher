import Foundation

/// A way to start a session: which agent, its exact command, extra environment, and where it runs.
public struct LaunchPreset: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case claude, codex, shell

        public var label: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            case .shell: return "Shell"
            }
        }
    }

    public enum Place: String, Codable, CaseIterable, Sendable {
        /// VibeSwitcher's window (the session host).
        case window
        /// A new Terminal.app window, as before.
        case terminal
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// What runs, e.g. `claude --model opus`. Ignored for a shell.
    public var command: String
    public var env: [String: String]
    /// When the agent exits, keep a shell open in the session.
    public var keepShell: Bool
    public var place: Place

    public var agent: Agent? {
        switch kind {
        case .claude: return .claude
        case .codex: return .codex
        case .shell: return nil
        }
    }

    public init(id: UUID = UUID(), name: String, kind: Kind, command: String, env: [String: String] = [:],
                keepShell: Bool = false, place: Place = .window) {
        self.id = id
        self.name = name
        self.kind = kind
        self.command = command
        self.env = env
        self.keepShell = keepShell
        self.place = place
    }
}

/// All presets: global ones, ones that belong to a project, and each project's default.
public struct LaunchPresets: Codable, Equatable, Sendable {
    public var global: [LaunchPreset]
    /// By project root.
    public var byProject: [String: [LaunchPreset]]
    /// Each project's default preset, by project root.
    public var defaults: [String: UUID]

    public init(global: [LaunchPreset], byProject: [String: [LaunchPreset]] = [:], defaults: [String: UUID] = [:]) {
        self.global = global
        self.byProject = byProject
        self.defaults = defaults
    }

    /// Fixed ids, so a project's default survives the built-ins being recreated.
    static let claudeID = UUID(uuidString: "00000000-0000-0000-0000-00000000C1A0")!
    static let codexID = UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!
    static let shellID = UUID(uuidString: "00000000-0000-0000-0000-000000005E11")!

    /// Claude, Codex and Shell, using the commands from the old "Launch Commands…" setting.
    public static func builtIns(claudeCommand: String = "claude", codexCommand: String = "codex") -> LaunchPresets {
        func or(_ command: String, _ fallback: String) -> String {
            let trimmed = command.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? fallback : trimmed
        }
        return LaunchPresets(global: [
            LaunchPreset(id: claudeID, name: "Claude", kind: .claude, command: or(claudeCommand, "claude")),
            LaunchPreset(id: codexID, name: "Codex", kind: .codex, command: or(codexCommand, "codex")),
            LaunchPreset(id: shellID, name: "Shell", kind: .shell, command: ""),
        ])
    }

    /// The project's default first, then its own presets, then the global ones.
    public func presets(for root: String?) -> [LaunchPreset] {
        var list = (root.flatMap { byProject[$0] } ?? []) + global
        if let root, let id = defaults[root], let index = list.firstIndex(where: { $0.id == id }) {
            list.insert(list.remove(at: index), at: 0)
        }
        return list
    }

    public func defaultPreset(for root: String?) -> LaunchPreset? { presets(for: root).first }

    public func preset(id: UUID) -> LaunchPreset? {
        (global + byProject.values.flatMap { $0 }).first { $0.id == id }
    }

    /// Saved presets, or the built-ins (from the old two commands) when there are none or the file is unreadable.
    public static func load(from url: URL, claudeCommand: String, codexCommand: String) -> LaunchPresets {
        guard let data = try? Data(contentsOf: url),
              let presets = try? JSONDecoder().decode(LaunchPresets.self, from: data), !presets.global.isEmpty
        else { return builtIns(claudeCommand: claudeCommand, codexCommand: codexCommand) }
        return presets
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Building what a preset runs.
public enum LaunchPlan {
    /// What the session host runs; nil for a shell.
    public static func command(for preset: LaunchPreset) -> String? {
        guard preset.kind != .shell else { return nil }
        let command = preset.command.trimmingCharacters(in: .whitespaces)
        return command.isEmpty ? preset.kind.rawValue : command
    }

    /// For Terminal.app: `cd '<folder>' && NAME='value' … <command>`; a shell preset only changes folder.
    public static func terminalLine(for preset: LaunchPreset, in directory: String) -> String {
        guard let command = command(for: preset) else { return "cd \(RecentProjects.shellQuote(directory))" }
        let env = preset.env.filter { validEnvName($0.key) }.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(RecentProjects.shellQuote($0.value)) " }.joined()
        return RecentProjects.shellCommand(cd: directory, run: env + command)
    }

    /// Picks up an ended session where it left off: `claude … --resume <id>` / `codex … resume <id>`.
    public static func resumeCommand(base: String?, agent: Agent, sessionID: String) -> String {
        let trimmed = base?.trimmingCharacters(in: .whitespaces) ?? ""
        let command = trimmed.isEmpty ? agent.rawValue : trimmed
        let id = RecentProjects.shellQuote(sessionID)
        switch agent {
        case .claude: return "\(command) --resume \(id)"
        case .codex: return "\(command) resume \(id)"
        }
    }

    /// Shell variable names: an ASCII letter or underscore, then ASCII letters, digits, underscores.
    public static func validEnvName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first.isASCII, first == "_" || CharacterSet.letters.contains(first)
        else { return false }
        return name.unicodeScalars.allSatisfy { $0.isASCII && ($0 == "_" || CharacterSet.alphanumerics.contains($0)) }
    }
}
