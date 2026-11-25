import Foundation

/// The model each of a task's worker sessions was launched on, as the session host recorded it when the lead bound the
/// worker's role to the session (`LeadVault.Request.bind`): the `--model` on the command the host itself started that
/// session with (never what the request says), and Claude Code's default at that moment (`~/.claude/settings.json`'s
/// "model" in the host's home), for a launch that passed none. Kept in the vault's record of the task
/// (`Team.launches`), which only the host writes, across every worker session the task had (a rework's, one that ended
/// or was parked), until the task is retired.
///
/// The floor that keeps audits off the workers' model judges a task's audit by these (`basis`): the union of what every
/// one of its worker sessions ran on. With no record (a worker started before this build, a vault that started over, a
/// session the host couldn't tell), the project's default counts as before. The board's model and `launchedModels`
/// never take a model off: any session of the team can write them.
public struct WorkerLaunch: Codable, Equatable, Sendable {
    public var session: String
    /// The `--model` its launch command passed, before the start message's `--`; nil: none.
    public var model: String?
    /// Claude Code's default then; nil: none set (Claude's own default).
    public var defaultModel: String?
    /// The host knew the session's command; false: nothing to judge by (counts as no record).
    public var known: Bool
    public var at: Double

    public init(session: String, model: String?, defaultModel: String?, known: Bool, at: Double) {
        self.session = session
        self.model = model
        self.defaultModel = defaultModel
        self.known = known
        self.at = at
    }

    /// What the host saw of a session it binds a role to: the command it started it with (nil: a plain shell).
    public struct Seen: Equatable, Sendable {
        public var command: String?
        public init(command: String?) { self.command = command }
    }

    /// The launch of `session` as the host saw it (`seen` nil: it doesn't know the session), Claude Code's default
    /// read from `home`.
    public static func recorded(session: String, seen: Seen?, home: String, at: Double = Date().timeIntervalSince1970) -> WorkerLaunch {
        guard let seen else { return WorkerLaunch(session: session, model: nil, defaultModel: nil, known: false, at: at) }
        let model = seen.command.flatMap(launchModel(command:))
        return WorkerLaunch(session: session, model: model, defaultModel: model == nil ? LeadWorkflow.claudeModel(command: "", home: home) : nil,
                            known: true, at: at)
    }

    /// The model it ran on: its `--model`, else the default then, else Claude's own (which the floor counts as opus);
    /// nil when the host didn't know it.
    public var ran: String? {
        guard known else { return nil }
        return model ?? defaultModel ?? "opus"
    }

    /// The `--model` a launch command passes before its `--` (what follows is the start message: the brief's words,
    /// never options); nil when it passes none.
    public static func launchModel(command: String) -> String? {
        let options = command.split(whereSeparator: \.isWhitespace).prefix { $0 != "--" }.joined(separator: " ")
        return LeadWorkflow.claudeModel(command: options)
    }

    /// The most kept per task: the newest.
    static let kept = 50

    /// The workers' models a task's audit is kept off (`launches` the task's record, nil: none), and what they were
    /// judged by, for the audit's line. Every launch known: what each ran on. Else the project's default
    /// (`projectDefault`, nil: Claude's own) with what is known.
    public static func basis(_ launches: [WorkerLaunch]?, projectDefault: String?) -> (workers: [String?], text: String) {
        let launches = launches ?? []
        let ran = launches.compactMap(\.ran)
        if !launches.isEmpty, ran.count == launches.count {
            var families: [String] = []
            for model in ran where !families.contains(where: { LeadReviewFloor.sameModel($0, model) }) { families.append(model) }
            return (families, "workers ran on \(families.map(shown).joined(separator: " and ")) by the host's record")
        }
        return ([projectDefault] + ran, "no launch record: Claude Code's default counts as the workers' model")
    }

    /// A model as the line says it: its family when known.
    static func shown(_ model: String) -> String {
        ["mythos", "fable", "opus", "sonnet", "haiku"].first { model.lowercased().contains($0) } ?? model
    }
}

extension LeadVault {
    /// The task's worker launches as the host recorded them (`WorkerLaunch`); nil: none kept, or the vault couldn't be
    /// asked (an older host).
    public func launches(root: String, task: String) -> [WorkerLaunch]? {
        guard case .launches(let launches)? = try? call(.launches(root: root, task: task)) else { return nil }
        return launches
    }
}
