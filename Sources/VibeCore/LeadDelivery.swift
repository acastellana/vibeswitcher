import Foundation

/// How a message reaches an agent: steered in while it works (at its next step, without stopping it), typed in
/// as its next prompt while it's idle (a steer would wait for a turn that never comes).
public enum LeadDelivery {
    public enum Way: Equatable, Sendable { case steer, type }

    public static func way(for state: HookState?) -> Way {
        guard let state else { return .type }
        return ["Stop", "SessionStart", "SessionEnd", "Notification", "PermissionRequest"].contains(state.lastEvent) ? .type : .steer
    }

    static let prefix = "[VibeSwitcher"

    /// The prompt typed for an idle agent: messages not from the user are marked, so neither the agent nor the
    /// chat takes them for the user's words.
    public static func typed(_ text: String, from sender: SteerMessage.Sender) -> String {
        switch sender {
        case .user: return text
        case .lead(let name): return "\(prefix) · from \(name), not the user] \(text)"
        case .system(let about): return "\(prefix) · \(about), not the user] \(text)"
        }
    }
}

extension LeadDelivery {
    /// What happened to a message: steered into a working agent (it gets it at its next step), typed in as an idle
    /// agent's prompt, or queued (idle, but its box held a draft or couldn't be read): it then rides along with the
    /// next prompt, or `flush` types it once the box is empty.
    public enum Delivered: Equatable, Sendable {
        case steered, typed, queued
        /// Steered in, but it's stopped on a question or a permission prompt (what it asks, when known): it gets
        /// the message at its next step, once that's answered.
        case awaitingAnswer(String?)
        /// Idle, but its input box holds this draft: the message waits (as `queued`) unless the draft is cleared.
        case behindDraft(String)
    }

    /// What Claude Code's input box shows: nothing typed, a draft, or no box at all (a dialog is on screen: a
    /// permission prompt or a question, its last lines given).
    public enum Box: Equatable, Sendable {
        case empty
        case draft(String)
        case dialog(String)
    }

    /// A screen as the host shows it: its text, and how its characters are drawn (nil: a host too old to say).
    public struct Screen: Equatable, Sendable {
        public var text: String
        public var runs: [ScreenRun]?

        public init(text: String, runs: [ScreenRun]? = nil) {
            self.text = text
            self.runs = runs
        }
    }

    /// The box between the screen's last two horizontal rules, starting with ❯ (see `TerminalInput`). What Claude
    /// draws dim in it isn't typed: its placeholder (`Try "…"`) and its suggested next prompt, both faint, the
    /// first character inverted when it paints its caret there (typing replaces them). Without `runs` only the
    /// placeholder can be told, by its wording.
    public static func box(in screen: String, runs: [ScreenRun]? = nil) -> Box {
        let lines = screen.replacingOccurrences(of: "\u{0}", with: " ").components(separatedBy: "\n")
        let rules = lines.indices.filter { lines[$0].filter { $0 == "─" }.count >= 20 }
        let shown = { lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(6).joined(separator: " / ") }
        guard rules.count >= 2 else { return .dialog(shown()) }
        let (top, bottom) = (rules[rules.count - 2], rules[rules.count - 1])
        guard top + 1 < bottom, lines[top + 1].trimmingCharacters(in: .whitespaces).hasPrefix("❯"),
              let marker = lines[top + 1].firstIndex(of: "❯") else { return .dialog(shown()) }
        let rows = ((top + 1)..<bottom).map { row -> String in
            let line = Array(lines[row])
            let from = row == top + 1 ? lines[row].distance(from: lines[row].startIndex, to: marker) + 1 : 0
            let dim = runs.map { dimColumns(row: row, runs: $0) } ?? []
            return String(line.indices.filter { $0 >= from && !dim.contains($0) }.map { line[$0] })
                .trimmingCharacters(in: .whitespaces)
        }
        let typed = rows.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty { return .empty }
        if runs == nil, typed.range(of: #"^Try "[^"\n]*"$"#, options: .regularExpression) != nil { return .empty }
        return .draft(typed)
    }

    public static func box(in screen: Screen) -> Box { box(in: screen.text, runs: screen.runs) }

    /// The columns of `row` drawn dim, with a caret cell (inverse, not dim) right before dim text.
    static func dimColumns(row: Int, runs: [ScreenRun]) -> Set<Int> {
        let onRow = runs.filter { $0.row == row }
        var dim = Set(onRow.filter(\.isDim).flatMap { $0.column..<($0.column + $0.length) })
        for caret in onRow where caret.inverse && !caret.isDim && caret.length == 1 && dim.contains(caret.column + 1) {
            dim.insert(caret.column)
        }
        return dim
    }

    /// Steers the message in, or types it when the agent is idle, its input box is empty and `typeInto` reaches its
    /// terminal (a window session; returns whether the keys went out). Otherwise it waits in the inbox.
    @discardableResult
    public static func deliver(_ text: String, from sender: SteerMessage.Sender, to agent: LeadAgent,
                               inputIsEmpty: (() -> Bool)? = nil, typeInto: ((String) -> Bool)?) throws -> Delivered {
        try deliver(text, from: sender, to: agent, state: HookState.load(from: VibePaths.stateFile(tty: agent.tty)),
                    inputIsEmpty: inputIsEmpty, typeInto: typeInto)
    }

    public static func deliver(_ text: String, from sender: SteerMessage.Sender, to agent: LeadAgent, state: HookState?,
                               inputIsEmpty: (() -> Bool)?, typeInto: ((String) -> Bool)?, root: URL = VibePaths.root) throws -> Delivered {
        if way(for: state) == .type {
            if inputIsEmpty?() ?? false, let typeInto, typeInto(typed(text, from: sender)) { return .typed }
            try SteerInbox.post(SteerMessage(text: text, from: sender, agentPid: agent.pid), tty: agent.tty, root: root)
            return .queued
        }
        try SteerInbox.post(SteerMessage(text: text, from: sender, agentPid: agent.pid), tty: agent.tty, root: root)
        return .steered
    }

    /// Types the messages waiting for an idle agent once its input box is empty (an idle agent fires no hook, so
    /// nothing else would deliver them). Returns whether it typed.
    @discardableResult
    public static func flush(_ agent: LeadAgent, state: HookState?, inputIsEmpty: () -> Bool, typeInto: (String) -> Bool,
                             root: URL = VibePaths.root) -> Bool {
        flush(agent, betweenTurns: way(for: state) == .type, inputIsEmpty: inputIsEmpty, typeInto: typeInto, root: root)
    }

    /// As above, for an agent whose turn is known to be over (or not) from more than its hooks (see `LeadActivity`).
    @discardableResult
    public static func flush(_ agent: LeadAgent, betweenTurns: Bool, inputIsEmpty: () -> Bool, typeInto: (String) -> Bool,
                             root: URL = VibePaths.root) -> Bool {
        guard betweenTurns,
              SteerInbox.pending(tty: agent.tty, root: root).contains(where: { $0.agentPid == agent.pid }),
              inputIsEmpty() else { return false }
        // The first becomes the prompt (marked as its sender's) and is the only one marked delivered; the rest stay
        // first in line, and the prompt's own hook hands them to the agent with it. Not typed: all of them wait, in
        // order, for the next try, none marked delivered.
        var typedIt = false
        SteerInbox.deliver(tty: agent.tty, agentPid: agent.pid, root: root) { messages in
            guard let first = messages.first, typeInto(typed(first.text, from: first.from)) else { return 0 }
            typedIt = true
            return 1
        }
        return typedIt
    }

    /// Delivers by what the agent is doing (see `LeadActivity`), never typing into one that isn't between turns:
    /// working, or with nothing known about it, the message is steered in (it gets it at its next step); on a
    /// prompt, steered too (it gets it once that's answered); between turns, typed as its next prompt when its box is
    /// empty, or, with `clearDraft`, once `clear` has emptied a draft. Otherwise it waits in the inbox.
    @discardableResult
    public static func deliver(_ text: String, from sender: SteerMessage.Sender, to agent: LeadAgent, activity: LeadActivity,
                               screen: (() -> String?)?, typeInto: ((String) -> Bool)?, clearDraft: Bool = false,
                               clear: (() -> Void)? = nil, root: URL = VibePaths.root) throws -> Delivered {
        try deliver(text, from: sender, to: agent, activity: activity, styledScreen: screen.map { read in { read().map { Screen(text: $0) } } },
                    typeInto: typeInto, clearDraft: clearDraft, clear: clear, root: root)
    }

    /// As above, reading the screen with how it's drawn, which tells Claude's suggested prompt from a draft.
    @discardableResult
    public static func deliver(_ text: String, from sender: SteerMessage.Sender, to agent: LeadAgent, activity: LeadActivity,
                               styledScreen screen: (() -> Screen?)?, typeInto: ((String) -> Bool)?, clearDraft: Bool = false,
                               clear: (() -> Void)? = nil, root: URL = VibePaths.root) throws -> Delivered {
        let post = { try SteerInbox.post(SteerMessage(text: text, from: sender, agentPid: agent.pid), tty: agent.tty, root: root) }
        switch activity {
        case .working, .unknown:
            try post()
            return .steered
        case .needsInput(let asked):
            try post()
            return .awaitingAnswer(asked)
        case .idle, .apiError:
            break
        }
        guard let screen, let typeInto, let shown = screen() else {
            try post()
            return .queued
        }
        switch box(in: shown) {
        case .empty:
            if typeInto(typed(text, from: sender)) { return .typed }
        case .dialog(let lines):
            try post()
            return .awaitingAnswer(lines)
        case .draft(let draft):
            // Cleared only when asked, and typed only if the box then reads empty (a draft that didn't go stays).
            if clearDraft, let clear {
                clear()
                if let after = screen(), box(in: after) == .empty, typeInto(typed(text, from: sender)) { return .typed }
            }
            try post()
            return .behindDraft(draft)
        }
        try post()
        return .queued
    }
}

extension HostCall {
    /// A session's screen with how it's drawn; only its text from a host too old to say (see `HostRequest.styledScreen`).
    public static func styledScreen(_ id: UUID, socket: String = VibePaths.hostSocket.path) -> LeadDelivery.Screen? {
        switch try? request(.styledScreen(id: id), socket: socket) {
        case .styledScreenText(_, let text, let runs)?: return LeadDelivery.Screen(text: text, runs: runs)
        case .error?:
            if case .screenText(_, let text)? = try? request(.screen(id: id), socket: socket) { return LeadDelivery.Screen(text: text) }
            return nil
        default: return nil
        }
    }
}
