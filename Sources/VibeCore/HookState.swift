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

/// An exclusive `flock` that gives up instead of waiting for ever: the hook's locks (its state file, the steer inbox)
/// are held by other hooks, and one stuck holding it mustn't hold every other event of the session too.
public enum HookLock {
    /// Whether the lock on `fd` was had within `seconds` (tried every 10 ms).
    public static func exclusive(_ fd: Int32, within seconds: TimeInterval) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(seconds, 0) * 1e9)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, DispatchTime.now().uptimeNanoseconds < deadline else { return false }
            usleep(10_000)
        }
        return true
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
        case "Interrupt", "SubagentStart", "SubagentStop":
            break
        default:
            // Not an event the installer installs (`HookInstaller`), so a malformed or forged call: the state stays.
            return .ignore
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

    /// Reads only the text's head (`head(_:units:)`, 4 UTF-16 units per character kept, and never under 1 KB, so a
    /// shorter text comes out as it always did): a 5 MB prompt costs what a short one does, where masking all of it
    /// took seconds, inside the hook's lock (docs/eval/open-2026-10-19.md, R4).
    static func clip(_ text: String?, to limit: Int = 280) -> String? {
        guard let text else { return nil }
        let head = head(text, units: max(4 * limit, 1024))
        let cut = head.endIndex < text.endIndex
        // Cut in its first word: all of the head is a word that may be a secret, and not recognisable as one without
        // its end.
        guard !cut || head.utf16.contains(where: { !isBreak($0) }) else { return Redaction.mask + "…" }
        // One line of plain text: drop newlines and the markdown emphasis agents like to use.
        let flat = Redaction.secrets(in: String(head)).split(whereSeparator: \.isNewline).joined(separator: " ")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !flat.isEmpty else { return nil }
        return flat.count > limit || cut ? String(flat.prefix(limit)) + "…" : flat
    }

    /// The text's first `units` UTF-16 units, without the word the cut goes through: back to the last space (or `*`,
    /// backtick: what `clip` drops). What's left of a secret cut in two may not be recognised as one, and once
    /// newlines and emphasis are dropped it could be among what's shown.
    static func head(_ text: String, units: Int) -> Substring {
        let utf16 = text.utf16
        // Step by step: an offset into a long text would first index all of it.
        var cut = utf16.startIndex
        for _ in 0..<units where cut < utf16.endIndex { cut = utf16.index(after: cut) }
        guard cut < utf16.endIndex else { return text[...] }
        var end = cut
        while end > utf16.startIndex, !isBreak(utf16[end]) {
            let before = utf16.index(before: end)
            if isBreak(utf16[before]) { break }
            end = before
        }
        return text[..<end]
    }

    /// Where a word ends for `head`: white space as `Redaction` takes it, `*` and the backtick.
    static func isBreak(_ c: UInt16) -> Bool {
        if c < 128 { return c == 32 || (c &- 9) < 5 || c == 42 || c == 96 }
        return c == 0x85 || c == 0xA0 || c == 0x1680 || (c &- 0x2000) < 11 || c == 0x2028 || c == 0x2029 || c == 0x202F
            || c == 0x205F || c == 0x3000
    }
}
