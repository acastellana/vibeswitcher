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
    /// What a running worker is told when `merged`'s merge into `base` changed `files`, which its branch changes too:
    /// merge `base` in now, while a conflict is still small, rather than find it at its own merge.
    public static func catchUp(base: String, merged: String, files: [String]) -> String {
        let named = files.prefix(12).joined(separator: ", ") + (files.count > 12 ? ", …" : "")
        return "\(base) just moved: \(merged) merged, and it changed files your branch changes too: \(named). Merge \(base) in now, while any conflict is still small: "
            + "in your worktree run `git merge \(base)`, resolve the conflicts in those files if there are any, `git add` them, then `git commit`, each command on its own (no pipes, && or 2>&1). "
            + "Then run the tests those files affect, commit, and carry on with your task."
    }

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
        /// Asked to clear the draft, it couldn't: what the box held before, and what it showed after the ^C (nil:
        /// the keys didn't go out, or the screen couldn't be read). The message waits (as `queued`).
        case draftStayed(before: String, after: String?)
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
        // A long message whose first parts it got at its steps (see `SteerReply.nextPart`): the rest, whole.
        var typedIt = false
        SteerInbox.deliver(tty: agent.tty, agentPid: agent.pid, root: root) { messages in
            guard let first = messages.first else { return 0 }
            let text = (first.handedOver ?? 0) > 0 ? "(The rest of the long message whose first part reached you earlier.) " + first.remainingText
                : first.text
            guard typeInto(typed(text, from: first.from)) else { return 0 }
            typedIt = true
            return 1
        }
        return typedIt
    }

    /// Delivers by what the agent is doing (see `LeadActivity`), never typing into one that isn't between turns:
    /// working, or with nothing known about it, the message is steered in (it gets it at its next step); on a
    /// prompt, steered too (it gets it once that's answered); between turns, typed as its next prompt when its box is
    /// empty, or, with `clearDraft`, once `clear` (true when its keys went out) has emptied a draft. Otherwise it
    /// waits in the inbox.
    @discardableResult
    public static func deliver(_ text: String, from sender: SteerMessage.Sender, to agent: LeadAgent, activity: LeadActivity,
                               screen: (() -> String?)?, typeInto: ((String) -> Bool)?, clearDraft: Bool = false,
                               clear: (() -> Bool)? = nil, root: URL = VibePaths.root) throws -> Delivered {
        try deliver(text, from: sender, to: agent, activity: activity, styledScreen: screen.map { read in { read().map { Screen(text: $0) } } },
                    typeInto: typeInto, clearDraft: clearDraft, clear: clear, root: root)
    }

    /// As above, reading the screen with how it's drawn, which tells Claude's suggested prompt from a draft.
    @discardableResult
    public static func deliver(_ text: String, from sender: SteerMessage.Sender, to agent: LeadAgent, activity: LeadActivity,
                               styledScreen screen: (() -> Screen?)?, typeInto: ((String) -> Bool)?, clearDraft: Bool = false,
                               clear: (() -> Bool)? = nil, root: URL = VibePaths.root) throws -> Delivered {
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
        // A report for an idle lead isn't typed as it is: the app's wake-up (`LeadWake`) types one short prompt for
        // all that wait, and the prompt's hook hands them over.
        if case .system = sender {
            try post()
            return .queued
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
            guard clearDraft, let clear else {
                try post()
                return .behindDraft(draft)
            }
            var seen: String?
            if clear(), let after = screen() {
                switch box(in: after) {
                case .empty:
                    if typeInto(typed(text, from: sender)) { return .typed }
                    seen = ""
                case .draft(let again) where again == draft && after.runs == nil:
                    // The same text drawn again right after the ^C emptied the box: Claude's suggested prompt, which a
                    // host too old to say what's dim shows as text. Typing replaces it.
                    if typeInto(typed(text, from: sender)) { return .typed }
                    seen = again
                case .draft(let again), .dialog(let again):
                    seen = again
                }
            }
            try post()
            return .draftStayed(before: draft, after: seen)
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

/// Waking an idle lead when reports come in (a worker done or blocked, a verdict, the witness's news). They wait
/// in its inbox, and its hooks hand them over with its next prompt or step; an idle lead takes no step, so
/// VibeSwitcher types one short prompt that says what came in and asks it to call status. The reports themselves
/// still arrive through the prompt's hook (and status), not in the prompt. Reports close together wake it once
/// (`debounce`), only between turns, only into an empty box (Claude's dim suggestion counts as empty), and no new
/// wake-up goes in until the lead has taken one of the reports since the last (a turn ran).
public struct LeadWake: Equatable, Sendable {
    /// Quiet this long after the last report before waking (more may follow)…
    public static let debounce: TimeInterval = 5
    /// …but no longer than this after the first, while they keep coming.
    public static let longest: TimeInterval = 8
    /// Reports waiting this long are shown on the lead's strip (it couldn't be woken: your draft, a dialog).
    public static let shownAfter: TimeInterval = 120

    /// The reports the last wake-up was typed for; while all of them still wait, the lead hasn't taken a turn.
    public private(set) var typedFor: Set<String> = []

    public init() {}

    public enum Step: Equatable, Sendable {
        /// Nothing to do: no reports, a wake-up in flight, or the lead gets them otherwise (mid-turn, at a prompt).
        case none
        /// More may come: look again then.
        case later(Double)
        /// Read the box, and type the wake-up if it's empty (`type`).
        case ready
    }

    /// What waits for the lead that a wake-up is for: everything but the user's own words (those are typed as
    /// they are, see `LeadDelivery.flush`).
    public static func reports(_ pending: [SteerMessage], agentPid: Int32) -> [SteerMessage] {
        pending.filter { $0.agentPid == agentPid && $0.from != .user }
    }

    /// The first half of a try: whether to read the lead's box now.
    public mutating func step(reports: [SteerMessage], activity: LeadActivity, now: Double) -> Step {
        let ids = Set(reports.map(\.id))
        // One of them was taken: its hook ran, so the lead took a turn since the last wake-up.
        if !typedFor.isEmpty, !typedFor.isSubset(of: ids) { typedFor = [] }
        guard let first = reports.map(\.at).min(), let last = reports.map(\.at).max(), typedFor.isEmpty,
              activity.betweenTurns else { return .none }
        let due = min(last + Self.debounce, first + Self.longest)
        return now >= due ? .ready : .later(due)
    }

    /// The second half: types the wake-up for the reports waiting now if the box reads empty. Nothing is marked
    /// delivered (the prompt's hook hands them over). Returns whether it typed.
    @discardableResult
    public mutating func type(reports: [SteerMessage], box: LeadDelivery.Box?, typeInto: (String) -> Bool) -> Bool {
        guard typedFor.isEmpty, !reports.isEmpty, box == .empty,
              typeInto(LeadDelivery.typed(Self.prompt(reports), from: .system("reports"))) else { return false }
        typedFor = Set(reports.map(\.id))
        return true
    }

    /// Both halves at once, for a screen read on the spot.
    @discardableResult
    public mutating func tick(reports: [SteerMessage], activity: LeadActivity, screen: () -> LeadDelivery.Screen?,
                              typeInto: (String) -> Bool, now: Double) -> Step {
        let step = step(reports: reports, activity: activity, now: now)
        if step == .ready { type(reports: reports, box: screen().map(LeadDelivery.box(in:)), typeInto: typeInto) }
        return step
    }

    /// How many reports the strip shows as waiting: those older than `shownAfter`, all of them then.
    public static func waiting(_ reports: [SteerMessage], now: Double) -> Int {
        guard let first = reports.map(\.at).min(), now - first >= shownAfter else { return 0 }
        return reports.count
    }

    /// "2 new reports (verifier phone-and-remote passed; worker x blocked). Call status."
    public static func prompt(_ reports: [SteerMessage]) -> String {
        let named = reports.prefix(3).map(short).joined(separator: "; ")
        let more = reports.count > 3 ? "; \(reports.count - 3) more" : ""
        let count = reports.count == 1 ? "1 new report" : "\(reports.count) new reports"
        return "\(count) (\(named)\(more)). Call status."
    }

    /// A report in a few words: who, and what became of it.
    static func short(_ report: SteerMessage) -> String {
        let text = report.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let said: [(String, String)] = [
            ("says it's done", "done"), ("is blocked", "blocked"), ("is stalled", "stalled"), ("asks", "asks"), ("is waiting for input", "waits for input"),
            ("stopped mid-", "stopped on an API error"), ("stopped without", "stopped"), ("ended", "ended"),
        ]
        for role in ["worker", "verifier"] {
            let opening = "The \(role) on "
            guard text.hasPrefix(opening) else { continue }
            let rest = text.dropFirst(opening.count)
            guard let space = rest.firstIndex(of: " ") else { break }
            let after = rest[rest.index(after: space)...]
            if let match = said.first(where: { after.hasPrefix($0.0) }) { return "\(role) \(rest[..<space]) \(match.1)" }
        }
        if text.hasPrefix("The audit of "), let space = text.dropFirst(13).firstIndex(of: " ") {
            let slug = text.dropFirst(13)[..<space]
            return "verifier \(slug) " + (text[space...].hasPrefix(" passed") ? "passed" : "failed")
        }
        let about: String
        if case .system(let name) = report.from { about = name } else if case .lead(let name) = report.from { about = name } else { about = "" }
        let clipped = text.count > 60 ? String(text.prefix(60)) + "…" : text
        return about.isEmpty ? clipped : "\(about): \(clipped)"
    }
}
