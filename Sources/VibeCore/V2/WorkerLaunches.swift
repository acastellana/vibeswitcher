import Foundation

/// The model families a task's worker sessions were launched on, as the session host saw each one when the lead bound
/// a worker's role to it (`LeadVault.Request.bind`): every `--model` on the command the host itself started that
/// session with (never what the request says), or Claude Code's default at that moment (`~/.claude/settings.json`'s
/// "model" in the host's home) for a launch that passed none. Kept in the vault's record of the task
/// (`Team.launchedFamilies`), which only the host writes, by the task the vault's own grant names (a team member's
/// under its member slug), never trimmed and never cleared, not even at retire (the branch may outlive it).
///
/// These only ever ADD to what an audit is kept off under the floor that keeps audits off the workers' model
/// (`excluded`): Claude Code's default and the lead's model stay excluded as before, with the board's task model and
/// launched model. Nothing here unlocks a model: argv isn't proof of what ran (a decoy bind, Claude Code's own
/// precedence, `/model` mid-session). A name that isn't a known family adds nothing and removes nothing.
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

    /// Every `--model` (or `--model=`) a launch command passes before its `--` (what follows is the start message: the
    /// brief's words, never options), in order.
    public static func launchModels(command: String) -> [String] {
        let words = command.split(whereSeparator: \.isWhitespace).prefix { $0 != "--" }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
        var found: [String] = []
        for (index, word) in words.enumerated() {
            if word == "--model", index + 1 < words.count, !words[index + 1].isEmpty { found.append(words[index + 1]) }
            if word.hasPrefix("--model="), word.count > "--model=".count { found.append(String(word.dropFirst("--model=".count))) }
        }
        return found
    }

    /// The families a launch adds (`seen` nil: the host didn't know the session, none): each `--model`'s, or with none,
    /// Claude Code's default's as `home` holds it now. Unknown names add nothing.
    public static func families(seen: Seen?, home: String) -> [String] {
        guard let seen else { return [] }
        let models = seen.command.map(launchModels(command:)) ?? []
        let named: [String?] = models.isEmpty ? [LeadWorkflow.claudeModel(command: "", home: home)] : models
        return Array(Set(named.compactMap(family(of:)))).sorted()
    }

    /// What a task's audit is kept off under the floor, and the line that says so: Claude Code's default
    /// (`projectDefault`), the lead's model(s), and the families the vault recorded for the task's launches
    /// (`launched`, nil: no record).
    public static func excluded(projectDefault: String?, lead: [String?], launched: [String]?) -> (workers: [String?], text: String) {
        let leads = Array(Set(lead.compactMap { $0 }.map(LeadReviewFloor.workersModel).map(shown))).sorted()
        var parts = ["Claude Code's default \(projectDefault.map(shown) ?? "(Claude's own, counted as opus)")"]
        if !leads.isEmpty { parts.append("the lead's \(leads.joined(separator: " and "))") }
        if let launched, !launched.isEmpty {
            parts.append("workers launched on \(launched.joined(separator: " and ")) by the host's record")
        } else {
            parts.append("no launch record")
        }
        return ([projectDefault] + lead + (launched ?? []), "kept off the workers' models: " + parts.joined(separator: "; "))
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
