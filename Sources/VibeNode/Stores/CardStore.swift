import Foundation
import VibeCore

/// Every card the user answers, by id (the engine plan's E6, the security architecture document's S3): the lead's
/// questions, its approvals of held merges, the agents' config the vault holds, and a base that moved. Held in the
/// server's memory only: nothing on a card is read back from a file the team can write. A question card is made from
/// the lead's tool server's post (`question.post`, EN-D10), never from `board.json`; an approval card's facts are the
/// engine's, from git and the vault, with the lead's wording beside them marked as the lead's; a held-config card is
/// bound to the hashes it showed; a base-move card to the move it showed. Each has a four-letter code (`NodeIds.code`)
/// the user types to act on it. On the engine's queue; `changes` carries each card as it changes.
public final class CardStore: @unchecked Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case question
        case approval
        case configHeld = "config"
        case baseMove = "base"
        /// A shell an agent asked for (`vs-shell run`, `ShellAsk`): Run or Decline (`ShellCards.swift`).
        case shell
    }

    /// A shell request's card (`ShellCards.swift`): the request as the host stamped it, never changed, and what became
    /// of it. What runs is exactly `request.command` in `request.cwd`, as shown.
    public struct ShellShown: Equatable, Sendable {
        public enum State: String, Sendable { case waiting, starting, started, declined, expired, failed }
        public var request: ShellRequest
        /// The asking session's name as the node lists it.
        public var asker: String
        public var state: State
        /// The shell session started (started): its id and name.
        public var shell: String?
        public var name: String?
        /// Why it didn't start (failed).
        public var why: String?

        public init(request: ShellRequest, asker: String, state: State = .waiting, shell: String? = nil, name: String? = nil, why: String? = nil) {
            self.request = request
            self.asker = asker
            self.state = state
            self.shell = shell
            self.name = name
            self.why = why
        }
    }

    /// An approval card's facts (S3): what the engine derives itself, never the board's words.
    public struct ApprovalFacts: Equatable, Sendable {
        /// The commit the lead's option approves, whole.
        public var commit: String
        /// The tasks whose branch `agent/<slug>` points at that commit now (`git for-each-ref --points-at`).
        public var tasks: [String]
        /// The base it would merge into, and the files and diffstat of `<base>...<commit>` from git.
        public var base: String?
        public var files: [String]
        public var diffstat: String
        /// The commit's subject, from git.
        public var subject: String?
        /// The verdict the vault holds for each task, as a line ("complete, clean at <commit>"), when it holds one.
        public var verdicts: [String: String]
        /// The files the commit touches that `sensitive_paths` names, read from workflow.md only while its value's hash
        /// is the one the vault records (`guardedRecord`); nil when it couldn't be vouched for (said on the card).
        public var sensitive: [String]?
        /// Why a fact is missing, when one is.
        public var problems: [String]

        public init(commit: String, tasks: [String] = [], base: String? = nil, files: [String] = [], diffstat: String = "",
                    subject: String? = nil, verdicts: [String: String] = [:], sensitive: [String]? = nil, problems: [String] = []) {
            self.commit = commit
            self.tasks = tasks
            self.base = base
            self.files = files
            self.diffstat = diffstat
            self.subject = subject
            self.verdicts = verdicts
            self.sensitive = sensitive
            self.problems = problems
        }
    }

    /// An answer drafted in a web client (the live plan's LW-D6, B5): the user's words for the card, kept in the server's
    /// memory and told to nobody. The lead hears nothing and the vault records nothing until the user takes it with
    /// `vibeswitcher answer CARD` in a terminal and types the card's code; that request is the user's voice, as every
    /// answer is. The last one wins.
    public struct Draft: Equatable, Sendable {
        public var text: String
        /// The question's version the page showed when the draft was made.
        public var version: Int
        public var at: Date
        /// The page's action id for it.
        public var action: String

        public init(text: String, version: Int, at: Date, action: String) {
            self.text = text
            self.version = version
            self.at = at
            self.action = action
        }
    }

    public struct Card: Equatable, Sendable {
        public var id: String
        public var code: String
        public var project: String
        public var root: String
        public var kind: Kind
        /// A question or approval card's question, as the lead's tool server last posted it (and as the user's answer,
        /// a hold or a timer left it).
        public var question: LeadQuestion?
        public var approval: ApprovalFacts?
        public var config: ConfigHoldStore.Shown?
        public var base: BaseMoveStore.Shown?
        public var shell: ShellShown?
        /// What became of the user's answer, when it wasn't simply taken (`withdrawn`, `afterAutoDecision`,
        /// `alreadyAnswered`, `missing`, an approval not recorded), or of an accept.
        public var notice: String?
        /// Closed: answered, withdrawn, decided by its timer, accepted, kept refused, or gone.
        public var closed: String?
        public var at: Date
        /// When it closed, as the store saw it close (`put`); nil while open. What `prune` keeps the closed by.
        public var closedAt: Date?
        /// The answer a web page drafted (`Draft`), until the card closes or the lead revises the wording it was for.
        public var draft: Draft?

        public init(id: String = NodeIds.card(), root: String, kind: Kind, at: Date = Date()) {
            self.id = id
            code = NodeIds.code(card: id)
            self.root = root
            project = NodeIds.project(root: root)
            self.kind = kind
            self.at = at
        }

        public var isOpen: Bool { closed == nil }

        /// Whether it blocks the lead's work: a blocking question, any approval, held config, a base move.
        public var isBlocking: Bool {
            switch kind {
            case .question: return question?.rank == .blocking
            case .approval, .configHeld, .baseMove: return true
            // The agent waits on it, not the lead's work.
            case .shell: return false
            }
        }
    }

    public let changes = Changes<Card>()
    /// By id. On the engine's queue.
    public private(set) var cards: [String: Card] = [:]
    /// The clock a card's close is stamped by (a test's own).
    var now: @Sendable () -> Date = { Date() }

    /// How many closed cards are kept, all kinds together (`prune`).
    public static let keptClosed = 200
    /// How many closed held-config cards are kept: each `config held` after a change, and each look that finds
    /// something new held, draws one, so they are the most and the least read once closed.
    public static let keptClosedConfig = 10
    /// The encoded bytes of the closed cards kept at most, all together (`prune`): with the open ones, a cards
    /// snapshot fits a line (the architecture review's row 14; `LiveHub.fitted` trims one that still doesn't).
    public static let keptClosedBytes = 384 * 1024
    /// How long a closed card is kept at most.
    public static let closedLife: TimeInterval = 24 * 60 * 60

    public init() {}

    /// `card` kept and sent. A draft doesn't outlive the card's question as it was drafted for: a card that closed (an
    /// answer, a withdrawal, its timer) or whose question the lead revised since loses it. A card that closes here is
    /// stamped (`closedAt`) and the closed are pruned (`prune`).
    func put(_ card: Card) {
        var card = card
        if let draft = card.draft, !card.isOpen || card.question?.version != draft.version { card.draft = nil }
        let closing = !card.isOpen && card.closedAt == nil
        if card.isOpen { card.closedAt = nil } else if closing { card.closedAt = now() }
        cards[card.id] = card
        changes.send(card.id, card)
        if closing { prune() }
    }

    /// The closed cards kept bounded (2026-11-20: a node kept every card it ever drew, 329 after a day, 1.4 MB, past a
    /// line's limit, and `answer` broke): the held-config ones past the newest `keptClosedConfig` go first, then any
    /// closed longer than `closedLife` ago, then the oldest closed past `keptClosed`, then the oldest closed past
    /// `keptClosedBytes` of their encoded values together (`value`). An open card is never pruned. A
    /// pruned card is told to the stream as gone; asked for later it is `gone`, as after a restart (S3: cards are memory
    /// only). On the engine's queue.
    func prune() {
        let closed = cards.values.filter { !$0.isOpen }.sorted { ($0.closedAt ?? $0.at, $0.id) > ($1.closedAt ?? $1.at, $1.id) }
        guard !closed.isEmpty else { return }
        let oldest = now().addingTimeInterval(-Self.closedLife)
        var kept = 0, keptConfig = 0, bytes = 0, full = false
        for card in closed {
            let at = card.closedAt ?? card.at
            let config = card.kind == .configHeld
            let size = full ? 0 : NodeWire.message(card.value).count
            if !full, bytes + size > Self.keptClosedBytes { full = true }
            if (config && keptConfig >= Self.keptClosedConfig) || at < oldest || kept >= Self.keptClosed || full {
                remove(card.id)
                continue
            }
            kept += 1
            bytes += size
            if config { keptConfig += 1 }
        }
    }

    func change(_ id: String, _ body: (inout Card) -> Void) {
        guard var card = cards[id] else { return }
        body(&card)
        put(card)
    }

    func remove(_ id: String) {
        cards[id] = nil
        changes.send(id, nil)
    }

    /// The question or approval card for question `question` of `root`'s lead.
    func card(question: String, root: String) -> Card? {
        let project = NodeIds.project(root: root)
        return cards.values.first { $0.project == project && $0.question?.id == question }
    }

    /// The card `wanted` names: its whole id, or a prefix of the UUID part (at least 4 characters) only one card has.
    public func resolve(_ wanted: String) -> Card? {
        let wanted = wanted.trimmingCharacters(in: .whitespaces).lowercased()
        if let exact = cards[wanted] { return exact }
        let prefix = "\(NodeIds.node):card:"
        let part = wanted.hasPrefix(prefix) ? String(wanted.dropFirst(prefix.count)) : wanted
        guard part.count >= 4 else { return nil }
        let matches = cards.values.filter { $0.id.dropFirst(prefix.count).hasPrefix(part) }
        return matches.count == 1 ? matches.first : nil
    }

    /// The open cards of `project` (every project's when nil), newest last; closed ones too with `all`.
    public func list(project: String? = nil, all: Bool = false) -> [Card] {
        cards.values.filter { (project == nil || $0.project == project) && (all || $0.isOpen) }.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
    }

    /// The roots with a question or approval open for the user: their leads ask (`Session.leadAsks`).
    public var asking: Set<String> {
        Set(cards.values.filter { $0.isOpen && ($0.kind == .question || $0.kind == .approval) }.map { ($0.root as NSString).standardizingPath })
    }

    /// The open cards counted by kind, for `status`.
    public func counts(project: String? = nil) -> [Kind: Int] {
        var counts: [Kind: Int] = [:]
        for card in list(project: project) { counts[card.kind, default: 0] += 1 }
        return counts
    }
}
