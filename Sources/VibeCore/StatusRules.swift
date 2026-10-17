import Foundation

public enum TitleActivity: Equatable, Sendable {
    case busy   // spinner glyph: Claude is mid-turn
    case idle   // ✳ glyph: Claude is waiting at its prompt
    case none   // no recognizable glyph (Codex, plain shells, custom titles)
}

public enum StatusRules {
    /// Tools that block on the human, so a PreToolUse for them means "needs input", not "working".
    public static let questionTools: Set<String> = ["AskUserQuestion", "ExitPlanMode", "request_user_input", asyncQuestionTool]
    /// Codex's question that doesn't block the turn: it stays open (`HookState.openQuestion`) after the call and the turn.
    public static let asyncQuestionTool = "request_user_input_async"

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
        case "Stop":
            return state.openQuestion != nil ? .needsInput : .done
        case "Interrupt":
            return .done
        case "PostToolUse" where state.toolName == asyncQuestionTool && state.openQuestion != nil:
            return .needsInput
        default: // UserPromptSubmit, PostToolUse, PreCompact, …
            return .working
        }
    }

    /// Combines hook facts with the terminal title glyph.
    ///
    /// Hooks are authoritative, but they miss some transitions: Claude fires no Stop hook when you
    /// press Esc, and resumes on its own after background tasks. The title glyph catches both, but
    /// only once the hook data is a few seconds old, so a fresh hook event always wins.
    ///
    /// Without hooks the title is all there is, and ✳ alone can't tell a finished turn from a session that never
    /// ran one (sitting at the trust prompt or an empty input): `seenBusy` says a spinner was seen first (see
    /// `TurnWitness`). Only then is it "done"; otherwise it's idle.
    public static func resolve(hook: HookState?, title: TitleActivity, now: Double,
                               graceSeconds: Double = 4, seenBusy: Bool = false) -> SessionStatus {
        guard let hook else {
            switch title {
            case .busy: return .working
            case .idle: return seenBusy ? .done : .idle
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

/// Which sessions have been seen mid-turn (a spinner in the title) since this process started on its terminal,
/// so a title-only ✳ is "done" only after a busy → idle transition was actually observed.
public struct TurnWitness: Sendable {
    private var busyPid: [String: Int32] = [:]

    public init() {}

    /// Records what `tty`'s title shows now; returns whether that process has been seen busy.
    public mutating func observe(tty: String, pid: Int32, title: TitleActivity) -> Bool {
        // A new process on the terminal starts over.
        if let seen = busyPid[tty], seen != pid { busyPid[tty] = nil }
        if title == .busy { busyPid[tty] = pid }
        return busyPid[tty] == pid
    }

    /// Forgets terminals that no longer run a session.
    public mutating func prune(liveTTYs: Set<String>) {
        busyPid = busyPid.filter { liveTTYs.contains($0.key) }
    }
}

/// Background work a Claude Code session is still waiting on after its turn ended (background shells,
/// tasks, monitors). Claude shows it in its footer, e.g. "⏵⏵ bypass permissions on · 1 shell · ← 2 agents";
/// the session resumes by itself when that work reports back. "← N agents" is only a hint for switching
/// to agent views (it shows on sessions idle for hours), so it doesn't count.
public enum BackgroundWork {
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?:^|·)\s*(←)?[^0-9A-Za-z·←]*(\d+)\s+(shells?|agents?|background tasks?|monitors?)(?=\s*(?:·|$))"#,
        options: [.caseInsensitive])

    /// Summary like "1 shell · 2 agents" from the last lines of the terminal, or nil if nothing is running.
    /// Only the footer (last few non-empty lines) is inspected so conversation text can't match.
    public static func summary(fromScreen screen: String, footerLines: Int = 6) -> String? {
        let lines = screen.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(footerLines)
        var parts: [String] = []
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            for match in pattern.matches(in: line, range: range) {
                guard match.range(at: 1).location == NSNotFound,
                      let count = Range(match.range(at: 2), in: line), let kind = Range(match.range(at: 3), in: line),
                      Int(line[count]) ?? 0 > 0 else { continue }
                parts.append("\(line[count]) \(line[kind].lowercased())")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
