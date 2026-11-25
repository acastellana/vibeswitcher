import Foundation

/// The model a task's workers were launched on, by the session host's record of each one's launch command, for the
/// floor that keeps audits off the workers' model (`LeadToolset.auditModel`). The project's default (Claude Code's
/// model, the command's or `~/.claude/settings.json`'s: `LeadRuntime.workerModel`) is the workers' model only for a
/// task whose workers were started without a `--model`: a task on `model: opus` has its workers run on Opus whatever
/// the default is, and a Fable default then never keeps its audit off Fable.
///
/// Only the host's record counts here, never the board: board.json's model and `launchedModels` can be written by any
/// session of the team, so they only ever add a model to keep an audit off (`LeadWorkflow.auditModel`). The host
/// started each session with its command, and no session changes that record.
extension LeadToolset {
    /// The model every one of `task`'s worker sessions (its worker, and a team's members' workers) was launched with,
    /// as the host recorded its command (`LeadRuntime.launchCommand`); nil, so the project's default applies, when
    /// there's no task, a worker the host doesn't know, one started with no `--model` or a name that doesn't say which
    /// model it is, or workers on different models.
    func launchedWorkersModel(_ task: LeadTask?) -> String? {
        guard let task else { return nil }
        let sessions = ([task.worker] + (task.team ?? []).map(\.worker)).compactMap { $0 }.filter { !$0.isEmpty }
        guard !sessions.isEmpty else { return nil }
        var found: String?
        for session in sessions {
            guard let command = runtime.launchCommand(of: session), let model = Self.launchModel(command: command),
                  LeadReviewFloor.knownModel(model) else { return nil }
            if let found, !LeadReviewFloor.sameModel(found, model) { return nil }
            found = found ?? model
        }
        return found
    }

    /// The `--model` a session's launch command passes before its `--` (what follows is the start message, whose
    /// words are the brief's, never options); nil when it passes none.
    static func launchModel(command: String) -> String? {
        let words = command.split(whereSeparator: \.isWhitespace)
        let options = words.prefix { $0 != "--" }.joined(separator: " ")
        return LeadWorkflow.claudeModel(command: options)
    }
}

public extension LeadRuntime {
    /// No host record by default (a runtime that keeps none): the project's default applies.
    func launchCommand(of session: String) -> String? { nil }
}
