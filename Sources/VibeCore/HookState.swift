import Foundation

/// The latest known facts about the agent running in one terminal, as recorded by the hook binary.
/// Facts only; the app turns them into a `SessionStatus` (see `StatusRules`).
public struct HookState: Codable, Equatable, Sendable {
    public var agent: Agent
    public var tty: String
    public var agentPid: Int32?
    public var sessionId: String?
    public var cwd: String?
    public var lastEvent: String
    public var lastEventAt: Double
    public var toolName: String?
    public var notificationType: String?
    public var notice: String?
    public var lastPrompt: String?
    public var lastMessage: String?
    /// What the running tool call is doing ("npm test", "Edit Package.swift") and when it started.
    public var toolDetail: String?
    public var toolStartedAt: Double?
    /// First thing the user asked in this session; a fallback label when the tab has no useful title.
    public var firstPrompt: String?
    /// What the session is asking you right now: its question, the command it wants to run, its plan.
    public var request: String?
    /// The agent's own transcript of this session (Claude Code and Codex pass it to every hook).
    /// Not trusted as-is: `TranscriptReader.checkedURL` validates it before anything reads it.
    public var transcriptPath: String?
    /// A question Codex asked without waiting (`request_user_input_async`): the turn goes on or ends, the question
    /// stays open until you answer.
    public var openQuestion: String?
    /// Where the session was when a manual compaction started (Codex sends PreCompact/PostCompact for `/compact` and
    /// no Stop after), so PostCompact can put it back.
    public var eventBeforeCompact: String?
    public var eventBeforeCompactAt: Double?

    public init(agent: Agent, tty: String, lastEvent: String, lastEventAt: Double) {
        self.agent = agent
        self.tty = tty
        self.lastEvent = lastEvent
        self.lastEventAt = lastEventAt
    }

    public static func load(from url: URL) -> HookState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HookState.self, from: data)
    }

    /// Written readable by you only: it holds your last prompt and the agent's last message.
    public func save(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum HookUpdate: Equatable {
    case write(HookState)
    case delete
    case ignore
}

extension HookState {
    /// Notification types that change what the user has to do. Others (e.g. `auth_success`) are ignored.
    static let meaningfulNotifications: Set<String> = ["permission_prompt", "elicitation_dialog", "idle_prompt"]

    /// Folds one hook payload (the JSON Claude Code / Codex pipe to the hook on stdin) into the stored state.
    /// `rolloutQuestion`: at a Codex Stop, an async question still open in its rollout (`TranscriptReader.openAsyncQuestion`).
    public static func reduce(current: HookState?, payload: [String: Any], agent: Agent, tty: String,
                              agentPid: Int32?, now: Double, rolloutQuestion: String? = nil) -> HookUpdate {
        guard let event = payload["hook_event_name"] as? String else { return .ignore }
        // A subagent's events (they carry its `agent_id`) are part of the main session's turn: they don't start,
        // end or finish it, and its session id and transcript aren't the session's.
        let subagent = !((payload["agent_id"] as? String) ?? "").isEmpty
        if subagent, ["SessionStart", "SessionEnd", "UserPromptSubmit", "Stop"].contains(event) { return .ignore }
        if event == "SessionEnd" { return .delete }
        if let current, current.agent == agent {
            // Claude's own compaction between turns (idle compaction, 2.1.299+: a long conversation left idle about 54
            // minutes is compacted before its prompt cache expires; trigger "auto") isn't work: the session stays done,
            // idle or waiting on you, since when it was.
            if event == "PreCompact" || event == "PostCompact", payload["trigger"] as? String != "manual",
               current.lastEvent != "PreCompact", [.done, .idle, .needsInput].contains(StatusRules.status(for: current)) { return .ignore }
            // Claude restarts its hooks' session after every compaction (SessionStart, source "compact"): the turn goes
            // on, or the session stays where it was.
            if event == "SessionStart", payload["source"] as? String == "compact" { return .ignore }
        }
        // A subagent that finishes after the turn did doesn't make it work again.
        if event == "SubagentStop", let current, ["Stop", "Interrupt"].contains(current.lastEvent) { return .ignore }

        let sessionId = subagent ? nil : payload["session_id"] as? String
        var state: HookState
        if let current, current.agent == agent,
           sessionId == nil || current.sessionId == nil || current.sessionId == sessionId,
           agentPid == nil || current.agentPid == nil || current.agentPid == agentPid {
            state = current
        } else {
            state = HookState(agent: agent, tty: tty, lastEvent: event, lastEventAt: now)
            // A fork carries on the conversation it came from (Codex `/fork`, `codex fork`): keep its label.
            if event == "SessionStart", payload["source"] as? String == "fork", let current, current.agent == agent,
               agentPid == nil || current.agentPid == agentPid {
                state.firstPrompt = current.firstPrompt
            }
        }
        state.sessionId = sessionId ?? state.sessionId
        state.agentPid = agentPid ?? state.agentPid
        if !subagent {
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty { state.cwd = cwd }
            if let path = payload["transcript_path"] as? String, !path.isEmpty, path.utf8.count <= 1024 {
                state.transcriptPath = path
            }
        }

        switch event {
        case "Notification":
            let message = payload["message"] as? String
            guard let type = (payload["notification_type"] as? String) ?? inferNotificationType(message),
                  meaningfulNotifications.contains(type) else { return .ignore }
            // Claude sends idle_prompt ~60s after Stop. It adds nothing and would reset "unseen" timing.
            if type == "idle_prompt", ["Stop", "Interrupt"].contains(state.lastEvent) { return .ignore }
            state.notificationType = type
            state.notice = message
        case "SessionStart":
            state.openQuestion = nil
        case "UserPromptSubmit":
            state.notice = nil
            state.request = nil
            // Your next message is the answer.
            state.openQuestion = nil
            // Background-task notices also arrive as prompts; they start a turn but aren't what you asked.
            let prompt = payload["prompt"] as? String ?? ""
            if !SessionNaming.isSystemPrompt(prompt) {
                state.lastPrompt = clip(prompt)
                state.firstPrompt = state.firstPrompt ?? state.lastPrompt
                state.lastMessage = nil
            }
        case "PreToolUse":
            let tool = payload["tool_name"] as? String
            state.toolName = tool
            state.toolDetail = tool.map { ToolActivity.describe(toolName: $0, input: payload["tool_input"] as? [String: Any] ?? [:]) }
            state.toolStartedAt = now
            state.request = tool.flatMap { Self.question(toolName: $0, input: payload["tool_input"] as? [String: Any] ?? [:]) }
            if tool == StatusRules.asyncQuestionTool { state.openQuestion = state.request ?? "Asked you something" }
        case "PostToolUse":
            state.toolName = payload["tool_name"] as? String
            state.toolStartedAt = nil
            state.request = state.toolName == StatusRules.asyncQuestionTool ? state.openQuestion : nil
        case "PermissionRequest":
            let tool = payload["tool_name"] as? String
            state.toolName = tool
            state.notice = tool.map { "Wants permission to use \($0)" } ?? "Wants permission"
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            // Question tools also raise a permission request; what you're asked is still the question.
            if let tool, StatusRules.questionTools.contains(tool) {
                state.request = Self.question(toolName: tool, input: input) ?? state.request
            } else {
                state.request = tool.map { Self.permission(toolName: $0, input: input) }
            }
        case "Stop":
            state.openQuestion = rolloutQuestion ?? state.openQuestion
            state.request = state.openQuestion
            state.lastMessage = clip(payload["last_assistant_message"] as? String) ?? state.lastMessage
        case "PreCompact":
            if payload["trigger"] as? String == "manual", state.lastEvent != "PreCompact" {
                (state.eventBeforeCompact, state.eventBeforeCompactAt) = (state.lastEvent, state.lastEventAt)
            }
        case "PostCompact":
            // `/compact` between turns: back to where it was (done, idle), not "working" until the next prompt.
            if payload["trigger"] as? String == "manual", let before = state.eventBeforeCompact,
               let at = state.eventBeforeCompactAt, state.lastEvent == "PreCompact" {
                (state.eventBeforeCompact, state.eventBeforeCompactAt) = (nil, nil)
                state.lastEvent = before
                state.lastEventAt = at
                return .write(state)
            }
        default:
            break
        }
        if event != "PreCompact" { (state.eventBeforeCompact, state.eventBeforeCompactAt) = (nil, nil) }
        if event != "PreToolUse", event != "PermissionRequest", event != "Notification" { state.toolStartedAt = nil }
        state.lastEvent = event
        state.lastEventAt = now
        return .write(state)
    }

    /// The question behind tools that stop and ask you something; nil for every other tool.
    static func question(toolName: String, input: [String: Any]) -> String? {
        switch toolName {
        case "AskUserQuestion", "request_user_input", StatusRules.asyncQuestionTool:
            // request_user_input_async names each question `title` (codex-app-server-protocol 0.163.0,
            // `AsyncUserInputQuestion { title, options }`).
            let questions = (input["questions"] as? [[String: Any]] ?? []).compactMap { $0["question"] as? String ?? $0["title"] as? String }
            guard let first = clip(questions.first, to: 200) else { return nil }
            return questions.count > 1 ? "\(first) (+\(questions.count - 1) more)" : first
        case "ExitPlanMode":
            // The plan's first line is usually its title ("# Plan: …").
            let plan = (input["plan"] as? String ?? "").split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces)) }
                .first { !$0.isEmpty }
            return "Plan ready: " + (clip(plan, to: 160) ?? "review it")
        default:
            return nil
        }
    }

    /// What a permission prompt is about: the exact command for shells (what you actually approve,
    /// rather than the agent's description of it), a short description for everything else.
    static func permission(toolName: String, input: [String: Any]) -> String {
        let command = (input["command"] as? String) ?? (input["command"] as? [String])?.joined(separator: " ")
            ?? (input["cmd"] as? String)
        if ["Bash", "shell", "local_shell", "exec_command", "container.exec"].contains(toolName),
           let command = clip(command, to: 200) {
            return "Run: " + command
        }
        return "Allow: " + ToolActivity.describe(toolName: toolName, input: input)
    }

    /// Older Claude Code versions send no `notification_type`; fall back to the message text.
    static func inferNotificationType(_ message: String?) -> String? {
        guard let message = message?.lowercased() else { return nil }
        if message.contains("permission") { return "permission_prompt" }
        if message.contains("waiting for your input") { return "idle_prompt" }
        return nil
    }

    static func clip(_ text: String?, to limit: Int = 280) -> String? {
        guard let text else { return nil }
        // One line of plain text: drop newlines and the markdown emphasis agents like to use.
        let flat = Redaction.secrets(in: text).split(whereSeparator: \.isNewline).joined(separator: " ")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !flat.isEmpty else { return nil }
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}
