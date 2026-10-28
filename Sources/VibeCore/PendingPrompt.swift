import Foundation

/// The prompt a role session waits on (a permission, a question, a plan to approve), in full, as the lead is told it:
/// the witness's "is waiting for input", read_session's "Waiting on:", and the "waiting for input (N min)" of sessions
/// and status. The hooks keep it cut to a line (`HookState.request`, the detail a window row shows); the transcript
/// has the call that raised it whole (`TranscriptTail.pending`), so the lead can tell the user what to approve.
public struct PendingPrompt: Equatable, Sendable {
    /// What it asks: "Run: <the command>", its questions with their options, "Allow: <the tool> <its input>".
    public var text: String
    /// Since when it waits, when known.
    public var since: Double?

    /// Past this many characters the text is cut, with a note.
    public static let limit = 2_000
    /// A text on one line up to this long is quoted inline; a longer one, or one on several lines, in a fenced block.
    public static let inlineLimit = 200

    public init(text: String, since: Double? = nil) {
        self.text = text
        self.since = since
    }

    /// What it waits on, from what's known: the transcript's pending call in full, else what its hooks or its program
    /// said (`asked`, cut to a line), else that it's a question or a permission.
    public static func waiting(asked: String?, pending: PendingPrompt?, since: Double?) -> PendingPrompt {
        PendingPrompt(text: pending?.text ?? asked ?? "a question or a permission", since: since ?? pending?.since)
    }

    /// The prompt a tool call raises, in full: the exact command for shells (what is approved), the questions with
    /// their options, the plan, or else the tool and its input.
    public static func text(toolName: String, input: [String: Any]) -> String {
        switch toolName {
        case "Bash", "shell", "local_shell", "exec_command", "container.exec":
            let command = (input["command"] as? String) ?? (input["command"] as? [String])?.joined(separator: " ") ?? (input["cmd"] as? String)
            if let command, !command.isEmpty { return "Run: " + command }
        case "AskUserQuestion", "request_user_input", StatusRules.asyncQuestionTool:
            let questions = (input["questions"] as? [[String: Any]] ?? []).compactMap { question -> String? in
                guard let text = question["question"] as? String ?? question["title"] as? String else { return nil }
                let options = (question["options"] as? [Any] ?? []).compactMap { option -> String? in
                    if let label = option as? String { return "  - \(label)" }
                    guard let option = option as? [String: Any], let label = option["label"] as? String else { return nil }
                    return "  - \(label)" + ((option["description"] as? String).map { ": \($0)" } ?? "")
                }
                return ([text] + options).joined(separator: "\n")
            }
            if !questions.isEmpty { return questions.joined(separator: "\n") }
        case "ExitPlanMode":
            if let plan = input["plan"] as? String, !plan.isEmpty { return "Plan ready:\n" + plan }
        default:
            break
        }
        let what = "Allow: " + ToolActivity.describe(toolName: toolName, input: input)
        guard !input.isEmpty, let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return what }
        return what + "\n" + json
    }

    /// Told of each text `quoted` builds and whether on the main thread, for tests: the app's witness builds none
    /// there (masking a long one took up to a second of a refresh, hang-20261027-201145).
    public static var quoting: ((String, Bool) -> Void)? {
        get { quotingLock.lock(); defer { quotingLock.unlock() }; return quotingHook }
        set { quotingLock.lock(); quotingHook = newValue; quotingLock.unlock() }
    }
    private static let quotingLock = NSLock()
    nonisolated(unsafe) private static var quotingHook: ((String, Bool) -> Void)?

    /// The text as the lead reads it, credentials masked: inline (“…”) when it's short and on one line, otherwise in
    /// a fenced block; past `limit` characters cut at a word, with a note saying how much more there is.
    public var quoted: String {
        Self.quoting?(text, Thread.isMainThread)
        let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var shown = whole
        var note = ""
        if whole.count > Self.limit {
            // At a word: a secret cut in two may not be recognised as one (see `HookState.head`).
            let head = HookState.head(whole, units: whole.prefix(Self.limit).utf16.count)
            shown = head.isEmpty ? Redaction.mask : String(head)
            note = "\n(cut at \(Self.limit) characters; \(whole.count - shown.count) more not shown)"
        }
        shown = Redaction.secrets(in: shown)
        if note.isEmpty, shown.count <= Self.inlineLimit, !shown.contains(where: \.isNewline) { return "“\(shown)”" }
        // Longer than any run of backticks inside, so the text can't close it.
        var longest = 0, run = 0
        for character in shown { run = character == "`" ? run + 1 : 0; longest = max(longest, run) }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)\n\(shown)\n\(fence)" + note
    }

    /// "since 09:52 (6 min)"; nil when it isn't known.
    public func waited(now: Date) -> String? {
        since.map { "since \(LeadBoard.clock($0)) (\(Self.minutes($0, now: now)))" }
    }

    /// "waiting for input (6 min)", for sessions and status.
    public func marker(now: Date) -> String {
        "waiting for input" + (since.map { " (\(Self.minutes($0, now: now)))" } ?? "")
    }

    /// The text on one line, cut to `limit` characters, credentials masked (as the hooks clip a request).
    public func line(_ limit: Int) -> String {
        HookState.clip(text, to: limit) ?? ""
    }

    static func minutes(_ since: Double, now: Date) -> String {
        "\(max(0, Int((now.timeIntervalSince1970 - since) / 60))) min"
    }
}
