import Foundation

/// The model families a task's worker sessions were launched on, as the session host saw each one when the lead bound
/// a worker's role to it (`LeadVault.Request.bind`): every `--model` on the command the host itself started that
/// session with (never what the request says), or Claude Code's default at that moment (`~/.claude/settings.json`'s
/// "model" in the host's home) for a launch that passed none. Kept in the vault's record of the task
/// (`Team.launchedFamilies`), which only the host writes, by the task the vault's own grant names (a team member's
/// under its member slug), never trimmed and never cleared, not even at retire (the branch may outlive it).
///
/// These only ever ADD to what an audit is kept off under the floor that keeps audits off the workers' model
/// (`excluded`): the workers' model (the floor's worker_model, the user's word, else Claude Code's default) stays
/// excluded as before, with the board's task model and launched model. Nothing here unlocks a model: argv isn't proof
/// of what ran (a decoy bind, Claude Code's own precedence, `/model` mid-session). A name that isn't a known family
/// adds nothing and removes nothing. The lead's own model was never part of the rule and isn't here (the security
/// architecture's open list: a lead that writes a task's code itself, and `--advisor`).
public enum WorkerLaunch {
    /// What the host saw of a session it binds a role to: the command it started it with (nil: a plain shell).
    public struct Seen: Equatable, Sendable {
        public var command: String?
        public init(command: String?) { self.command = command }
    }

    static let families = ["mythos", "fable", "opus", "sonnet", "haiku"]

    /// `model`'s family when it names one; nil for an alias (default, best, opusplan), a custom id or anything else.
    public static func family(of model: String?) -> String? {
        guard let name = model?.lowercased() else { return nil }
        return families.first { name.contains($0) }
    }

    /// The `--model` (or `--model=`) a launch command passes before its `--` (what follows is the start message: the
    /// brief's words, never options): the last one, as Claude Code's own option parsing takes it; nil when none. The
    /// command split as a shell splits it (`words`).
    public static func launchModel(command: String) -> String? {
        let options = words(command).prefix { $0 != "--" }
        var found: String?
        for (index, word) in options.enumerated() {
            if word == "--model", index + 1 < options.count { found = options[options.startIndex + index + 1] }
            if word.hasPrefix("--model=") { found = String(word.dropFirst("--model=".count)) }
        }
        return found.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `command`'s words as a POSIX shell splits them: single quotes literal, double quotes with `\` escaping `"`, `\`,
    /// `$` and `` ` ``, a bare `\` escaping the next character (`RecentProjects.shellQuote`'s `'\''` among them).
    static func words(_ command: String) -> [String] {
        var words: [String] = []
        var word = "", inWord = false
        var characters = command.makeIterator()
        while let character = characters.next() {
            switch character {
            case "'":
                inWord = true
                while let next = characters.next(), next != "'" { word.append(next) }
            case "\"":
                inWord = true
                while let next = characters.next(), next != "\"" {
                    if next == "\\", let escaped = characters.next() {
                        if !"\"\\$`".contains(escaped) { word.append(next) }
                        word.append(escaped)
                    } else {
                        word.append(next)
                    }
                }
            case "\\":
                inWord = true
                if let escaped = characters.next() { word.append(escaped) }
            case _ where character.isWhitespace:
                if inWord { words.append(word) }
                word = ""
                inWord = false
            default:
                inWord = true
                word.append(character)
            }
        }
        if inWord { words.append(word) }
        return words
    }

    /// The family a launch adds (`seen` nil: the host didn't know the session, none): its `--model`'s, or with none,
    /// Claude Code's default's as `home` holds it now. An unknown name adds nothing.
    public static func families(seen: Seen?, home: String) -> [String] {
        guard let seen else { return [] }
        let model = seen.command.flatMap(launchModel(command:)) ?? LeadWorkflow.claudeModel(command: "", home: home)
        return family(of: model).map { [$0] } ?? []
    }

    /// What a task's audit is kept off under the floor, and the line that says so: the workers' model (`floorModel`,
    /// the floor's worker_model, else `projectDefault`, Claude Code's default) and the families the vault recorded for
    /// the task's launches (`launched`, nil: no record).
    public static func excluded(floorModel: String?, projectDefault: String?, launched: [String]?) -> (workers: [String?], text: String) {
        let base = floorModel.map { "workers' model \(shown($0)) by your review floor" }
            ?? "Claude Code's default \(projectDefault.map(shown) ?? "(Claude's own, counted as opus)")"
        let record = launched.flatMap { $0.isEmpty ? nil : $0 }.map { " and launched on \($0.joined(separator: " and ")) by the host's record" }
            ?? ", no launch record"
        return ([floorModel ?? projectDefault] + (launched ?? []), "kept off " + base + record)
    }

    /// A model as the line says it: its family when known.
    static func shown(_ model: String) -> String { family(of: model) ?? model }
}

extension LeadVault {
    /// The families the host recorded for `task`'s worker launches and its team members' (`WorkerLaunch`); nil: none
    /// kept, or the vault couldn't be asked (an older host).
    public func launchedFamilies(root: String, task: String) -> [String]? {
        guard case .families(let families)? = try? call(.launchedFamilies(root: root, task: task)) else { return nil }
        return families
    }
}
