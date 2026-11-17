import Foundation

/// A burst of VibeSwitcher's cards for the lead (the wake-up for waiting reports, auto_advance's steps, the workers'
/// notes and reports, audit verdicts, the witness, app health) and the lead's tool rows between them, folded into one
/// quiet line ("4 updates · audit of x started · worker freed · audit of y didn't pass"); opened, the cards show as
/// they always did. The user said of the lead's chat (2026-11-17): "we have too much noise.... i dont even read 80%".
/// Only the view changes: what the agent was handed is the same.
public struct ChatUpdates: Equatable, Sendable {
    /// The folded items, in order: team cards and tool runs, starting with a card.
    public let items: [ChatItem]

    public init(items: [ChatItem]) { self.items = items }

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

    /// Whether a card in it is a failure the user may care about (`TeamMessage.alarming`): its line is marked.
    public var alarming: Bool { cards.contains { $0.message.alarming } }

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
    public static func foldUpdates(_ items: [ChatItem]) -> [ChatItem] {
        var folded: [ChatItem] = []
        folded.reserveCapacity(items.count)
        var burst: [ChatItem] = []
        var tools: [ChatItem] = []
        func close() {
            if !burst.isEmpty { folded.append(.updates(ChatUpdates(items: burst))) }
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
}
