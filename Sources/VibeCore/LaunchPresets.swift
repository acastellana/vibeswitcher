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

    /// A preset needs a name and a kind it knows; anything else that's missing or unreadable (a hand-added preset
    /// without `env`, a newer app's `place`) falls back to its default and is noted, rather than failing the file.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        func field<T: Decodable>(_ key: CodingKeys, or fallback: T) -> T {
            do { return try container.decodeIfPresent(T.self, forKey: key) ?? fallback } catch {
                decoder.notePresetProblem("“\(name)”: its \(key.stringValue) couldn't be read, so it's back to the default")
                return fallback
            }
        }
        self.init(id: field(.id, or: UUID()), name: name, kind: try container.decode(Kind.self, forKey: .kind),
                  command: field(.command, or: ""), env: field(.env, or: [:]), keepShell: field(.keepShell, or: false),
                  place: field(.place, or: .window))
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

    /// Skips the presets (and project entries) it can't read instead of failing the whole file, noting each one.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func readable(_ items: [Skippable<LaunchPreset>], in place: String) -> [LaunchPreset] {
            items.enumerated().compactMap { index, item in
                if let error = item.error {
                    decoder.notePresetProblem("\(place), preset \(index + 1): \(LaunchPresets.describe(error)); left out")
                }
                return item.value
            }
        }
        var global: [LaunchPreset] = []
        do {
            global = readable(try container.decodeIfPresent([Skippable<LaunchPreset>].self, forKey: .global) ?? [],
                              in: "Global presets")
        } catch { decoder.notePresetProblem("The global presets couldn't be read; left out") }
        var byProject: [String: [LaunchPreset]] = [:]
        do {
            let projects = try container.decodeIfPresent([String: Skippable<[Skippable<LaunchPreset>]>].self,
                                                         forKey: .byProject) ?? [:]
            for (root, list) in projects.sorted(by: { $0.key < $1.key }) {
                guard let items = list.value else {
                    decoder.notePresetProblem("The presets for \(root) couldn't be read; left out")
                    continue
                }
                byProject[root] = readable(items, in: root)
            }
        } catch { decoder.notePresetProblem("The project presets couldn't be read; left out") }
        var defaults: [String: UUID] = [:]
        do {
            let entries = try container.decodeIfPresent([String: Skippable<UUID>].self, forKey: .defaults) ?? [:]
            for (root, entry) in entries.sorted(by: { $0.key < $1.key }) {
                if let id = entry.value { defaults[root] = id } else {
                    decoder.notePresetProblem("The default preset for \(root) couldn't be read; left out")
                }
            }
        } catch { decoder.notePresetProblem("The project defaults couldn't be read; left out") }
        self.init(global: global, byProject: byProject, defaults: defaults)
    }

    /// A decoding error in a few words: which field, and what was wrong with it.
    static func describe(_ error: Error) -> String {
        switch error as? DecodingError {
        case .keyNotFound(let key, _)?: return "it has no \(key.stringValue)"
        case .typeMismatch(_, let context)?, .valueNotFound(_, let context)?, .dataCorrupted(let context)?:
            return context.codingPath.last.map { "its \($0.stringValue) couldn't be read" } ?? "it couldn't be read"
        default: return "it couldn't be read"
        }
    }

    /// What `load` found in the file, and what it couldn't read.
    public struct Loaded: Sendable {
        public var presets: LaunchPresets
        /// One line per thing left out or reset; empty when the file read cleanly (or there was none).
        public var problems: [String] = []
        /// A copy of the file as it was, made before anything is saved over it.
        public var backup: URL?
        /// False when the file couldn't be read and couldn't be kept either: saving over it would lose it.
        public var canSave = true

        /// The one message the user sees about it, nil when there's nothing to say.
        public var notice: String? {
            guard !problems.isEmpty else { return nil }
            var lines = problems.map { "• \($0)" }
            if let backup {
                lines.append("\nThe file as it was is kept in \(backup.path).")
            } else if !canSave {
                lines.append("\nIt couldn't be copied aside, so preset changes won't be saved until it can be read.")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Saved presets, or the built-ins (from the old two commands) when there are none or the file is unreadable.
    public static func load(from url: URL, claudeCommand: String, codexCommand: String) -> LaunchPresets {
        loadChecked(from: url, claudeCommand: claudeCommand, codexCommand: codexCommand).presets
    }

    /// Like `load`, keeping what it could read. When something couldn't be read, the file is copied aside first
    /// (`presets.json.corrupt`), so the next save can't lose what's in it.
    public static func loadChecked(from url: URL, claudeCommand: String, codexCommand: String) -> Loaded {
        let builtIns = builtIns(claudeCommand: claudeCommand, codexCommand: codexCommand)
        guard FileManager.default.fileExists(atPath: url.path) else { return Loaded(presets: builtIns) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            return Loaded(presets: builtIns, problems: ["\(url.lastPathComponent) couldn't be opened: \(error.localizedDescription)"],
                          canSave: false)
        }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return Loaded(presets: builtIns) }
        let problems = PresetProblems()
        let decoder = JSONDecoder()
        decoder.userInfo[.presetProblems] = problems
        var loaded: Loaded
        do {
            loaded = Loaded(presets: try decoder.decode(LaunchPresets.self, from: data), problems: problems.lines)
        } catch {
            loaded = Loaded(presets: builtIns, problems: ["\(url.lastPathComponent) isn't readable JSON, so the built-in presets are used"])
        }
        if loaded.presets.global.isEmpty { loaded.presets.global = builtIns.global }
        guard !loaded.problems.isEmpty else { return loaded }
        loaded.backup = try? keepAside(data, of: url)
        loaded.canSave = loaded.backup != nil
        return loaded
    }

    /// `presets.json.corrupt`, or a timestamped name beside it when that already holds something else.
    static func keepAside(_ data: Data, of url: URL) throws -> URL {
        var backup = url.appendingPathExtension("corrupt")
        if let existing = try? Data(contentsOf: backup) {
            if existing == data { return backup }
            backup = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
        }
        try data.write(to: backup, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        return backup
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// What a lenient presets decode left out or reset, gathered through the decoder's `userInfo`.
final class PresetProblems: @unchecked Sendable {
    var lines: [String] = []
}

extension CodingUserInfoKey {
    static let presetProblems = CodingUserInfoKey(rawValue: "dev.vibeswitcher.presetProblems")!
}

extension Decoder {
    func notePresetProblem(_ line: String) { (userInfo[.presetProblems] as? PresetProblems)?.lines.append(line) }
}

/// One element that may fail to decode without failing the list (or dictionary) around it.
struct Skippable<Value: Decodable>: Decodable {
    let value: Value?
    let error: Error?

    init(from decoder: Decoder) throws {
        do { value = try Value(from: decoder); error = nil } catch { value = nil; self.error = error }
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
