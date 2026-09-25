import Foundation

public enum TitleActivity: Equatable, Sendable {
    case busy   // spinner glyph: Claude is mid-turn
    case idle   // ✳ glyph: Claude is waiting at its prompt
    case none   // no recognizable glyph (Codex, plain shells, custom titles)
}

public enum StatusRules {
    /// Tools that block on the human, so a PreToolUse for them means "needs input", not "working".
    public static let questionTools: Set<String> = ["AskUserQuestion", "ExitPlanMode", "request_user_input"]

    /// Status implied by the last hook event alone.
    public static func status(for state: HookState) -> SessionStatus {
        switch state.lastEvent {
        case "SessionStart":
            return .idle
        case "PermissionRequest":
            return .needsInput
        case "Notification":
            return state.notificationType == "idle_prompt" ? .done : .needsInput
        case "PreToolUse":
            return questionTools.contains(state.toolName ?? "") ? .needsInput : .working
        case "Stop", "Interrupt":
            return .done
        default: // UserPromptSubmit, PostToolUse, PreCompact, …
            return .working
        }
    }

    /// Combines hook facts with the terminal title glyph.
    ///
    /// Hooks are authoritative, but they miss some transitions: Claude fires no Stop hook when you
    /// press Esc, and resumes on its own after background tasks. The title glyph catches both, but
    /// only once the hook data is a few seconds old, so a fresh hook event always wins.
    public static func resolve(hook: HookState?, title: TitleActivity, now: Double,
                               graceSeconds: Double = 4) -> SessionStatus {
        guard let hook else {
            switch title {
            case .busy: return .working
            case .idle: return .done
            case .none: return .unknown
            }
        }
        let fromHook = status(for: hook)
        let settled = now - hook.lastEventAt > graceSeconds
        if settled, fromHook == .working, title == .idle { return .done }
        if settled, fromHook == .done || fromHook == .idle, title == .busy { return .working }
        return fromHook
    }

    static let idleGlyphs: Set<Character> = ["✳"]
    static let busyGlyphs: Set<Character> = ["◐", "◓", "◑", "◒", "·", "✢", "✶", "✻", "✽", "*"]

    /// Splits a Terminal tab title like "◐ Fix login bug" into its activity glyph and text.
    public static func parseTitle(_ raw: String) -> (activity: TitleActivity, text: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return (.none, "") }
        let rest = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        if idleGlyphs.contains(first) { return (.idle, rest) }
        let isBraille = first.unicodeScalars.first.map { (0x2800...0x28FF).contains($0.value) } ?? false
        if (busyGlyphs.contains(first) || isBraille), trimmed.dropFirst().first == " " { return (.busy, rest) }
        return (.none, trimmed)
    }
}
