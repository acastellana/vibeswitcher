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
    /// What the host saw of a session it binds a role to: the command it started it with (nil: a plain shell), and the
    /// folder it started in (its project settings' model and `env` are read there: they only add).
    public struct Seen: Equatable, Sendable {
        public var command: String?
        public var cwd: String?
        public init(command: String?, cwd: String? = nil) {
            self.command = command
            self.cwd = cwd
        }
    }

    static let families = ["mythos", "fable", "opus", "sonnet", "haiku"]

    /// `model`'s family when it names one; nil for an alias (default, best, opusplan), a custom id or anything else.
    public static func family(of model: String?) -> String? {
        guard let name = model?.lowercased() else { return nil }
        return families.first { name.contains($0) }
    }

    /// Each family's current model id, as this build knows it (kept in step with `LeadPrices.table`'s newest): what a
    /// worker under the floor is launched with in place of the family's alias, and what every team session's
    /// `--settings` pins the aliases to (`pins`), so a worktree's settings `env` can't remap one.
    public static let currentIDs: [String: String] = [
        "fable": "claude-fable-5-2", "mythos": "claude-mythos-5-2", "opus": "claude-opus-5-5", "sonnet": "claude-sonnet-5-5",
        "haiku": "claude-haiku-5-5",
    ]

    /// `model` as its full id when it is a family's bare alias (`opus`, `Fable`, `opus[1m]` keeps its `[1m]`); any other
    /// name (an id already, or a name this doesn't know) as it is.
    public static func fullID(_ model: String) -> String {
        let lowered = model.lowercased()
        let bare = lowered.hasSuffix("[1m]") ? String(lowered.dropLast(4)) : lowered
        guard let id = currentIDs[bare] else { return model }
        return id + (bare == lowered ? "" : "[1m]")
    }

    /// The `env` every team session's `--settings` carries: each family's alias pinned to its id
    /// (ANTHROPIC_DEFAULT_<FAMILY>_MODEL), and ANTHROPIC_MODEL to the model the session is launched with (`model`, as
    /// its id; none without one). Whether a project's or a worktree's settings `env` can still win key by key is
    /// unverified (the security architecture's open list).
    public static func pins(model: String?) -> [String: String] {
        var pins = Dictionary(uniqueKeysWithValues: currentIDs.map { ("ANTHROPIC_DEFAULT_\($0.key.uppercased())_MODEL", $0.value) })
        if let model { pins["ANTHROPIC_MODEL"] = fullID(model) }
        return pins
    }

    /// A name that says which one model it is: a family's or its claude-… id (`opusplan` is two, `best` none).
    public static func namesOne(_ model: String) -> Bool { LeadReviewFloor.knownModel(model) && runsOn(model).count == 1 }

    /// The families a model name a launch passed may run on: its own, `best` Opus, `opusplan` Opus and Sonnet (Claude
    /// Code's aliases); none for anything else (`default` is read as no `--model` by the caller).
    static func runsOn(_ model: String) -> [String] {
        switch model.lowercased() {
        case "best": return ["opus"]
        case "opusplan": return ["opus", "sonnet"]
        default: return family(of: model).map { [$0] } ?? []
        }
    }

    /// The model names a session's project settings in `cwd` give Claude Code (their "model", and their `env`'s
    /// ANTHROPIC_MODEL and ANTHROPIC_DEFAULT_*_MODEL): branch content, read only to add.
    static func projectModels(cwd: String?) -> [String] {
        guard let cwd else { return [] }
        var found: [String] = []
        for file in [".claude/settings.json", ".claude/settings.local.json"] {
            let path = (cwd as NSString).appendingPathComponent(file)
            guard let data = FileManager.default.contents(atPath: path), data.count < 1 << 20,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if let model = object["model"] as? String { found.append(model) }
            for (key, value) in object["env"] as? [String: Any] ?? [:]
            where key == "ANTHROPIC_MODEL" || (key.hasPrefix("ANTHROPIC_DEFAULT_") && key.hasSuffix("_MODEL")) {
                if let value = value as? String { found.append(value) }
            }
        }
        return found
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

    /// The families a launch adds (`seen` nil: the host didn't know the session, none): its `--model`'s (`runsOn`), or
    /// with none (or `default`), Claude Code's default's as `home` holds it now, and with no default set either, Claude's
    /// own, which the floor counts as Opus (`LeadReviewFloor.workersModel`); and whatever its project settings name
    /// (`projectModels`). An unknown name adds nothing.
    public static func families(seen: Seen?, home: String) -> [String] {
        guard let seen else { return [] }
        let passed = seen.command.flatMap(launchModel(command:)).flatMap { $0.lowercased() == "default" ? nil : $0 }
        let ran = passed.map(runsOn) ?? [LeadReviewFloor.workersModel(LeadWorkflow.claudeModel(command: "", home: home))].flatMap(runsOn)
        return Array(Set(ran + projectModels(cwd: seen.cwd).flatMap(runsOn))).sorted()
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
