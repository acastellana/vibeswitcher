import Foundation
import VibeCore

/// The app's launch presets on the node (the parity table's row, 2026-11-20): what `vibeswitcher new FOLDER --preset
/// NAME` and the page's New session form offer. They are read where the app keeps them, the node's `presets.json`
/// (`VibePaths.presetsFile` under the node's root: `LaunchPresets`, shared with the app), with the app's built-in
/// Claude, Codex and Shell when there is none; a folder's own presets and its default come first, as the app's New
/// Session lists them. Never written here, nor a `.corrupt` copy made: the node only reads them.
///
/// What a preset runs on the node keeps EN-D13: Claude is the program the node's `claude` link names, never a word a
/// shell looks up, so a Claude preset's command must be `claude` and then plain words (its arguments), each passed
/// quoted; Codex isn't on the node yet; a shell is the host's own. Its environment may not name what the host refuses
/// a spawn (`Platform.Tools.spawnEnvironmentRefused`) nor VibeSwitcher's own `VIBESWITCHER_*`. What the user is shown
/// is bound to what starts by the preset's `digest`: a preset changed in between is refused, nothing started.
public enum SessionPresets {
    /// A preset as the node lists it.
    public struct Listed: Equatable, Sendable {
        public var preset: LaunchPreset
        /// One of the folder's own presets (else a global one).
        public var project: Bool
        /// The folder's default (the first listed).
        public var isDefault: Bool
        /// Why the node can't start it, or nil.
        public var refusal: String?
    }

    /// The presets the node's `root` keeps, and a line for each thing in the file that couldn't be read (the file as a
    /// whole too: the built-ins then).
    public static func load(root: URL) -> (presets: LaunchPresets, problems: [String]) {
        let url = root.appendingPathComponent(VibePaths.presetsFile.lastPathComponent)
        let builtIns = LaunchPresets.builtIns()
        guard let data = try? Data(contentsOf: url) else { return (builtIns, []) }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return (builtIns, []) }
        // The lenient decode skips what it can't read (`LaunchPresets.init(from:)`).
        guard var presets = try? JSONDecoder().decode(LaunchPresets.self, from: data) else {
            return (builtIns, ["\(url.lastPathComponent) isn't readable JSON, so the built-in presets are used"])
        }
        if presets.global.isEmpty { presets.global = builtIns.global }
        return (presets, [])
    }

    /// The presets for `folder` (absolute), as the app's New Session lists them: the default of the nearest project
    /// folder that has presets (the folder itself or one it is in) first, then that project's own, then the global ones.
    public static func list(_ presets: LaunchPresets, folder: String?) -> [Listed] {
        let project = folder.flatMap { projectRoot(of: $0, in: presets) }
        let own = Set((project.flatMap { presets.byProject[$0] } ?? []).map(\.id))
        let listed = presets.presets(for: project)
        return listed.enumerated().map { index, preset in
            Listed(preset: preset, project: own.contains(preset.id), isDefault: index == 0 && project.flatMap { presets.defaults[$0] } == preset.id,
                   refusal: refusal(preset))
        }
    }

    /// The nearest folder at or above `folder` that `presets` keeps presets or a default for.
    static func projectRoot(of folder: String, in presets: LaunchPresets) -> String? {
        let standard = (folder as NSString).standardizingPath
        let tidy = { (key: String) in (key as NSString).standardizingPath }
        return Set(presets.byProject.keys).union(presets.defaults.keys).filter { key in
            let root = tidy(key)
            return standard == root || standard.hasPrefix(root == "/" ? "/" : root + "/")
        }.max { tidy($0).count < tidy($1).count }
    }

    /// The preset `name` names among `listed`: the same name, else the same ignoring case; the first such (the
    /// folder's own come first).
    public static func named(_ name: String, in listed: [Listed]) -> Listed? {
        listed.first { $0.preset.name == name } ?? listed.first { $0.preset.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Why the node can't start `preset` (nil: it can): Codex, a name that is a role's, a Claude command that isn't
    /// `claude` and plain words, an environment variable the host refuses.
    public static func refusal(_ preset: LaunchPreset) -> String? {
        if preset.kind == .codex { return "Codex doesn't run on this node yet" }
        if LeadTeams.role(label: preset.name) != nil {
            return "its name is a lead's or a team member's label, which only a lead's start gives"
        }
        if preset.kind == .claude, case .failure(let why) = arguments(preset) { return why.message }
        let names = preset.env.keys.sorted()
        if let bad = names.first(where: { !LaunchPlan.validEnvName($0) }) {
            return "its environment names \(ConfigSeal.inert(bad, limit: 64)), which isn't a variable's name"
        }
        let refused = Platform.Tools.spawnEnvironmentRefused(names) + names.filter { $0.hasPrefix("VIBESWITCHER_") }
        if !refused.isEmpty { return "its environment sets \(refused.joined(separator: ", ")), which a session can't be started with" }
        if preset.env.values.contains(where: { $0.contains("\u{0}") }) { return "an environment value holds a NUL" }
        return nil
    }

    struct Refusal: Error { let message: String }

    /// The words after `claude` in a Claude preset's command (none: plain `claude`), or why it can't run on the node.
    static func arguments(_ preset: LaunchPreset) -> Result<[String], Refusal> {
        let words = preset.command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = words.first else { return .success([]) }
        guard first == "claude" else {
            return .failure(Refusal(message: "its command starts \(ConfigSeal.inert(first, limit: 64)), and on this node a Claude preset's command is "
                                    + "`claude` and its arguments (the node runs the claude its link names, never one a shell finds)"))
        }
        let rest = Array(words.dropFirst())
        if let odd = rest.first(where: { $0.range(of: #"^[A-Za-z0-9_./:=,+@%\[\]-]+$"#, options: .regularExpression) == nil }) {
            return .failure(Refusal(message: "its command has \(ConfigSeal.inert(odd, limit: 64)), and on this node a Claude preset's arguments are "
                                    + "plain words (letters, digits and _ . / : = , + @ % [ ] -): no quotes, variables or shell syntax"))
        }
        return .success(rest)
    }

    /// The command line the host runs for `preset` (nil: the host's plain shell), Claude run as `program`.
    public static func command(_ preset: LaunchPreset, program: String) -> String? {
        guard preset.kind == .claude, case .success(let rest) = arguments(preset) else { return nil }
        return ([program] + rest).map(RecentProjects.shellQuote).joined(separator: " ")
    }

    /// What binds the preset the user was shown to the one started: its name, kind, command, environment (names and
    /// values) and whether a shell stays.
    public static func digest(_ preset: LaunchPreset) -> String {
        let env = preset.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let parts = [preset.name, preset.kind.rawValue, preset.command, preset.keepShell ? "keep" : "-"] + env
        return LeadVaultV2.digest(parts.joined(separator: "\u{0}"))
    }

    /// A preset as the wire carries it (`session.presets`): its name, kind, command and the names of its environment's
    /// variables (never their values: a key may be among them), whether a shell stays, where it is from, and why the
    /// node can't start it.
    public static func value(_ listed: Listed) -> NodeWire.Value {
        let preset = listed.preset
        return .object([
            "name": .string(preset.name), "kind": .string(preset.kind.rawValue), "command": .string(preset.command),
            "env": .array(preset.env.keys.sorted().map(NodeWire.Value.string)), "keepShell": .bool(preset.keepShell),
            "project": .bool(listed.project), "default": .bool(listed.isDefault),
            "digest": .string(digest(preset)), "refused": listed.refusal.map(NodeWire.Value.string) ?? .null,
        ])
    }
}
