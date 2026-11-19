import Foundation

/// A burst of VibeSwitcher's cards for the lead (the wake-up for waiting reports, auto_advance's steps, the workers'
/// notes and reports, audit verdicts, the witness, app health) and the lead's tool rows between them, folded into one
/// quiet line ("4 updates · audit of x started · worker freed · audit of y didn't pass"); opened, the cards show as
/// they always did. The user said of the lead's chat (2026-11-17): "we have too much noise.... i dont even read 80%".
/// Only the view changes: what the agent was handed is the same.
public struct ChatUpdates: Equatable, Sendable {
    /// The folded items, in order: team cards and tool runs, starting with a card.
    public let items: [ChatItem]
    /// The cards (by entry id) whose trouble the conversation after them settled (`ChatTimeline.foldUpdates`): an app
    /// health crash a later report no longer lists as new, or one the lead replied to.
    public let settled: Set<String>

    public init(items: [ChatItem], settled: Set<String> = []) {
        self.items = items
        self.settled = settled
    }

    /// The first item's: it stays as the burst grows, so an opened one stays open.
    public var id: String { "updates:" + (items.first?.id ?? "") }

    /// What it shows opened: every item but the wake-up for waiting reports, which only names the cards after it
    /// (all of them when it holds nothing else).
    public var shown: [ChatItem] {
        let rest = items.filter { !Self.isWake($0) }
        return rest.contains { if case .team = $0 { return true } else { return false } } ? rest : items
    }

    /// The cards it counts and names.
    public var cards: [(entry: ChatEntry, message: TeamMessage)] {
        shown.compactMap { if case .team(let entry, let message) = $0 { return (entry, message) } else { return nil } }
    }

    /// Whether a card in it is a failure the user may care about (`TeamMessage.alarming`) and still current: its line
    /// is marked. Without the board, a task's trouble counts as current.
    public var alarming: Bool { alarming(tasks: nil) }

    /// Whether a card in it is a failure the user may care about (`TeamMessage.alarming`) that's still current, with
    /// the lead's tasks as its board has them now (`ChatTaskStanding.of`; nil: not known): a task's trouble lasts until
    /// the task moves on after its card came (`TeamMessage.stillCurrent`), a crash until the conversation settles it
    /// (`settled`). The user saw a red mark at 9:12 on 2026-11-18 for a worker blocked on a task the lead had already
    /// re-planned and its worker was running again: "I want things to be as clean as possible."
    public func alarming(tasks: [String: ChatTaskStanding]?) -> Bool {
        cards.contains { card in
            card.message.alarming && !settled.contains(card.entry.id) && card.message.stillCurrent(at: card.entry.at, tasks: tasks)
        }
    }

    /// Whether its mark can change with the board: a card in it is alarming about a task.
    public var watchesBoard: Bool { cards.contains { $0.message.alarming && $0.message.alarmTask != nil } }

    /// "4 updates · audit of x started · worker freed": the count, then each card in a few words, from its AI summary
    /// (`summary`, by the card's entry id; nil while there's none) or else its own label (`TeamMessage.foldLabel`).
    /// The same words twice in a row are said once.
    public func line(summary: (TeamMessage, String) -> String? = { _, _ in nil }) -> String {
        let cards = cards
        var parts: [String] = []
        for card in cards {
            let words = summary(card.message, card.entry.id).map(Self.oneLine).flatMap { $0.isEmpty ? nil : $0 } ?? card.message.foldLabel
            let part = Self.lowercasedStart(Summarizer.clip(words, 80))
            if parts.last != part { parts.append(part) }
        }
        let count = cards.count == 1 ? "1 update" : "\(cards.count) updates"
        return ([count] + parts).joined(separator: " · ")
    }

    static func isWake(_ item: ChatItem) -> Bool {
        if case .team(_, let message) = item { return message.isWake }
        return false
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// "Audit of x passed" → "audit of x passed"; a first word with more capitals ("API", "VibeSwitcher") stays.
    static func lowercasedStart(_ text: String) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        let word = text.dropFirst().prefix { !$0.isWhitespace }
        if word.contains(where: \.isUppercase) { return text }
        return first.lowercased() + text.dropFirst()
    }

    /// Whether a run of the lead's tools may fold in with the cards around it: none of them asks something of the user
    /// (a question with ask_user, a shell or wallet card with vs-shell or vs-wallet), which stay in sight.
    public static func quiet(_ tools: [ChatTool]) -> Bool {
        !tools.contains { tool in
            if tool.name == "ask_user" || tool.name.hasSuffix("__ask_user") { return true }
            let command: String
            if case .command(let text) = tool.detail { command = text } else { command = tool.title }
            return command.contains("vs-shell") || command.contains("vs-wallet")
        }
    }
}

extension TeamMessage {
    /// VibeSwitcher's notices to the lead about its routine work, by sender (the rest stay cards: a shell card's or a
    /// wallet's outcome, the user's words passed on, a full disk, an app update).
    static let routineNotices: Set<String> = [
        "reports", LeadAdvance.sender, AppHealth.sender, "timer", "time budget", LeadRemotePoller.sender, "scheduled rotation", "restart",
    ]

    /// Whether it folds into a burst of updates (`ChatUpdates`): VibeSwitcher's report, audit, witness or routine
    /// notice. Never the user's words, the lead's, a teammate's post, or a notice about something the user did or
    /// must do.
    public var foldsIntoUpdates: Bool {
        switch kind {
        case .report, .audit, .witness: return true
        case .notice:
            if case .vibeSwitcher(let about) = sender { return Self.routineNotices.contains(about) }
            return false
        case .userAnswer, .leadMessage, .teammatePost: return false
        }
    }

    /// The wake-up for waiting reports ("2 new reports (…). Call status."): the reports follow it.
    public var isWake: Bool { sender == .vibeSwitcher("reports") }

    /// A failure the user may care about: an audit that didn't pass, a worker blocked or stopped on an error, a crash.
    public var alarming: Bool {
        switch kind {
        case .audit: return title.contains("didn't pass")
        case .report: return title.hasSuffix("is blocked") || title.contains("is blocked · part")
        case .witness: return gist.contains(" stopped mid-") || gist.contains(" stopped without")
        case .notice: return sender == .vibeSwitcher(AppHealth.sender) && body.contains("Crashes (reports in ")
        case .userAnswer, .leadMessage, .teammatePost: return false
        }
    }

    /// The task an alarming card's trouble is about: an audit's, a blocked worker's, or the one whose worker, verifier
    /// or team member the witness saw stop ("The worker on x stopped mid-task", "Member api of x's team stopped
    /// mid-part"). nil for one that isn't alarming, or a crash.
    public var alarmTask: String? {
        guard alarming else { return nil }
        switch kind {
        case .audit, .report: return task
        case .witness:
            let line = gist
            for opening in ["The worker on ", "The verifier on "] where line.hasPrefix(opening) {
                return line.dropFirst(opening.count).prefix { !$0.isWhitespace }.nonEmpty
            }
            if line.hasPrefix("Member "), let of = line.range(of: " of "), let team = line.range(of: "'s team ", range: of.upperBound..<line.endIndex) {
                return line[of.upperBound..<team.lowerBound].nonEmpty
            }
            return nil
        default: return nil
        }
    }

    /// The team member a witness's card says stopped ("Member api of x's team stopped mid-part": api); nil for any other.
    var alarmMember: String? {
        guard kind == .witness, alarmTask != nil, gist.hasPrefix("Member "), let of = gist.range(of: " of ") else { return nil }
        return gist[gist.index(gist.startIndex, offsetBy: 7)..<of.lowerBound].nonEmpty
    }

    /// Whether an alarming card's trouble, the card having come `at`, is still current with the lead's tasks as they
    /// are now (`tasks`, by slug; nil: not known, so it is). It's over once its task has moved on: finished (merged,
    /// kept, folded, abandoned, reverted) or gone from the board (the archive takes finished ones), or in another status
    /// since the card came (running again after "blocked", a re-audit after "didn't pass"). Besides: a blocked card
    /// lasts while the task is blocked, whatever else happens on it; an audit's while it's failed and no audit started
    /// or gave a verdict since; a stopped worker's until the lead messages it, it notes a milestone, or an audit starts
    /// or gives its verdict, as a new worker or the old one going on does. A teammate's milestone moves on only its
    /// own stop: on a team task members note progress all the time. A crash isn't about a task: the conversation
    /// settles it (`ChatUpdates.settled`).
    public func stillCurrent(at: Date?, tasks: [String: ChatTaskStanding]?) -> Bool {
        guard alarming else { return false }
        guard let tasks, let slug = alarmTask else { return true }
        guard let standing = tasks[slug], !ChatTaskStanding.finished.contains(standing.status) else { return false }
        let card = at?.timeIntervalSince1970
        func since(_ time: Double?) -> Bool {
            guard let card, let time else { return false }
            return time > card
        }
        if since(standing.since) { return false }
        switch kind {
        case .report: return standing.status == .blocked
        case .audit: return standing.status == .failed && !since(standing.audited)
        default:
            // A lead's message reaches a team task's integrator only.
            if let member = alarmMember { return !since(standing.members[member]) && !since(standing.audited) }
            return !since(standing.messaged) && !since(standing.worked) && !since(standing.audited)
        }
    }

    /// The crashes an app health digest lists as new (the lines under "Crashes (reports in …):"); empty for any other card.
    public var newCrashes: Set<String> {
        guard kind == .notice, sender == .vibeSwitcher(AppHealth.sender) else { return [] }
        var found: Set<String> = []
        var inside = false
        for line in body.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("Crashes (reports in ") { inside = true; continue }
            guard inside else { continue }
            guard line.hasPrefix("- ") else { break }
            found.insert(line)
        }
        return found
    }

    /// The card in a few words when it has no AI summary: auto_advance's first step (its card's first line is the
    /// same for every one), the wake-up's own line, else its title.
    public var foldLabel: String {
        // Shown only when nothing followed it: what it says is all there is.
        if isWake { return gist }
        if sender == .vibeSwitcher(LeadAdvance.sender) {
            let steps = body.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) }
            if let first = steps.first {
                return steps.count > 1 ? "\(first) (+\(steps.count - 1) more)" : first
            }
        }
        return title
    }
}

extension ChatTimeline {
    /// `items` with each burst of VibeSwitcher's cards for the lead (`TeamMessage.foldsIntoUpdates`), and the lead's
    /// tool runs between them (`ChatUpdates.quiet`), as one `.updates` item. Anything else ends a burst: your words,
    /// the lead's replies, a closed question, an all-done card, "New since you looked". A tool run after a burst's
    /// last card isn't between cards and stays out of it.
    ///
    /// An app health crash's card is settled (`ChatUpdates.settled`) once a later health report no longer lists all
    /// its crashes as new, or the lead replied after it.
    public static func foldUpdates(_ items: [ChatItem]) -> [ChatItem] {
        let settled = settledCrashes(items)
        var folded: [ChatItem] = []
        folded.reserveCapacity(items.count)
        var burst: [ChatItem] = []
        var tools: [ChatItem] = []
        func close() {
            if !burst.isEmpty {
                let ids = settled.isEmpty ? [] : Set(burst.lazy.map(\.id)).intersection(settled)
                folded.append(.updates(ChatUpdates(items: burst, settled: ids)))
            }
            folded += tools
            burst = []
            tools = []
        }
        for item in items {
            switch item {
            case .team(_, let message) where message.foldsIntoUpdates:
                burst += tools
                tools = []
                burst.append(item)
            case .tools(_, let run) where !burst.isEmpty && ChatUpdates.quiet(run):
                tools.append(item)
            default:
                close()
                folded.append(item)
            }
        }
        close()
        return folded
    }

    /// The app health cards (by entry id) whose crashes the conversation after them settled: a later health report
    /// leaves one of them out (it lists only what's new), or the lead replied after it.
    static func settledCrashes(_ items: [ChatItem]) -> Set<String> {
        var settled: Set<String> = []
        var replied = false
        // The crashes every later report lists as new; nil: no later report.
        var listedLater: Set<String>?
        for item in items.reversed() {
            switch item {
            case .reply: replied = true
            case .team(let entry, let message) where message.sender == .vibeSwitcher(AppHealth.sender):
                let crashes = message.newCrashes
                if message.alarming, replied || listedLater.map({ !crashes.isSubset(of: $0) }) == true { settled.insert(entry.id) }
                listedLater = listedLater.map { $0.intersection(crashes) } ?? crashes
            default: break
            }
        }
        return settled
    }
}

/// A lead's task as far as a red mark on a card about it goes (`TeamMessage.stillCurrent`): its status, when it took
/// it, and when each thing that moves it on last happened.
public struct ChatTaskStanding: Equatable, Sendable {
    public var status: LeadTask.Status
    /// When it took its status (`LeadTask.since`).
    public var since: Double?
    /// The lead's last message to its worker (`LeadTask.messagedAt`).
    public var messaged: Double?
    /// Its own worker's last milestone: a team member's ("api: …", `LeadToolset.progress`) isn't its worker's.
    public var worked: Double?
    /// Each team member's last milestone, by name (the integrator's are `worked`).
    public var members: [String: Double]
    /// Its audit's last start or verdict.
    public var audited: Double?

    public init(status: LeadTask.Status, since: Double? = nil, messaged: Double? = nil, worked: Double? = nil,
                members: [String: Double] = [:], audited: Double? = nil) {
        self.status = status
        self.since = since
        self.messaged = messaged
        self.worked = worked
        self.members = members
        self.audited = audited
    }

    public init(_ task: LeadTask) {
        // A member's milestones start with its name (the integrator, member 1, notes its own as the task's worker).
        let names = (task.team ?? []).dropFirst().map { $0.name + ": " }
        var worked: Double?
        var members: [String: Double] = [:]
        for checkpoint in task.checkpoints ?? [] {
            if let name = names.first(where: checkpoint.text.hasPrefix) {
                members[String(name.dropLast(2))] = max(members[String(name.dropLast(2))] ?? 0, checkpoint.at)
            } else {
                worked = max(worked ?? 0, checkpoint.at)
            }
        }
        self.init(status: task.status, since: task.since, messaged: task.messagedAt, worked: worked, members: members,
                  audited: [task.auditOpening?.at, task.evidence?.at].compactMap { $0 }.max())
    }

    /// Finished: nothing more happens on it, so no trouble on it is current.
    public static let finished: Set<LeadTask.Status> = [.done, .kept, .folded, .abandoned, .reverted]

    /// A board's tasks, by slug; nil when the board didn't load. One that can't be read loads as an empty board
    /// (`BoardStore.load`), and a task missing from it would read as finished, clearing every mark: a running lead's
    /// board that read names its base branch or its lead, so a board with nothing at all is taken as not read.
    public static func of(_ board: LeadBoard) -> [String: ChatTaskStanding]? {
        guard board != LeadBoard() else { return nil }
        return Dictionary(board.tasks.map { ($0.slug, ChatTaskStanding($0)) }, uniquingKeysWith: { first, _ in first })
    }
}

private extension Substring {
    var nonEmpty: String? { isEmpty ? nil : String(self) }
}
