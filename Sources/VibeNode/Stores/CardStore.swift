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
        /// What became of the user's answer, when it wasn't simply taken (`withdrawn`, `afterAutoDecision`,
        /// `alreadyAnswered`, `missing`, an approval not recorded), or of an accept.
        public var notice: String?
        /// Closed: answered, withdrawn, decided by its timer, accepted, kept refused, or gone.
        public var closed: String?
        public var at: Date

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
            }
        }
    }

    public let changes = Changes<Card>()
    /// By id. On the engine's queue.
    public private(set) var cards: [String: Card] = [:]

    public init() {}

    func put(_ card: Card) {
        cards[card.id] = card
        changes.send(card.id, card)
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
