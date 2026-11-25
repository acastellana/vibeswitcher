import Foundation
import VibeCore

/// Every card the user answers, by id (the engine plan's E6, the security architecture document's S3): the lead's
/// questions, its approvals of held merges, the agents' config the vault holds, and a base that moved. Held in the
/// server's memory; the open ones are kept across a restart in `cards.json`, taken back only while the vault vouches for
/// its bytes (`CardKeep`), so nothing on a card is read back from a file the team could have written. A question card is made from
/// the lead's tool server's post (`question.post`, EN-D10), never from `board.json`; an approval card's facts are the
/// engine's, from git and the vault, with the lead's wording beside them marked as the lead's; a held-config card is
/// bound to the hashes it showed; a base-move card to the move it showed. Each has a four-letter code (`NodeIds.code`)
/// the user types to act on it. On the engine's queue; `changes` carries each card as it changes.
public final class CardStore: @unchecked Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case question
        case approval
        case configHeld = "config"
        case baseMove = "base"
        /// A feature plugin's request (`Plugins/`): its card is data (`PluginCard`), answered with its words.
        case plugin
    }

    /// An approval card's facts (S3): what the engine derives itself, never the board's words.
    public struct ApprovalFacts: Codable, Equatable, Sendable {
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
    public struct Draft: Codable, Equatable, Sendable {
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

    public struct Card: Codable, Equatable, Sendable {
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
        /// A feature plugin's card (`PluginCard`): what the plugin drew, after the core's checks.
        public var plugin: PluginCard?
        /// What became of the user's answer, when it wasn't simply taken (`withdrawn`, `afterAutoDecision`,
        /// `alreadyAnswered`, `missing`, an approval not recorded), or of an accept.
        public var notice: String?
        /// What the node adds from the vault beside the lead's words, for a question the lead's audit asked (which model
        /// may audit a task the floor left none for: `Answers.auditFacts`); nil for every other card.
        public var facts: [String]?
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

        /// The one command that settles this card, for `status`, `approve`'s set-aside lines and the page alike: `vibeswitcher
        /// approve` when its batch takes it (held config that records no rules; a base move from a recorded or given
        /// commit), else the card's own accept, which prints the short card and asks one code (`config accept CARD`,
        /// `base accept CARD`); a question, approval or plugin's card is answered (`answer CARD TEXT`, or one of its
        /// words). Nil once closed.
        public var settle: String? {
            guard isOpen else { return nil }
            switch kind {
            case .configHeld:
                return config?.recordsRules == true || config?.firstLook == true ? "vibeswitcher config accept \(id)" : "vibeswitcher approve"
            case .baseMove:
                guard let base else { return "vibeswitcher base show \(root)" }
                return [.recorded, .given].contains(base.fromIs) && base.from != nil && base.from != base.to ? "vibeswitcher approve" : "vibeswitcher base accept \(id)"
            case .plugin:
                let words = plugin?.actions.map(\.word) ?? []
                return "vibeswitcher answer \(id) " + (words.isEmpty ? "WORD" : words.joined(separator: "|"))
            case .question, .approval:
                return "vibeswitcher answer \(id) TEXT"
            }
        }

        /// As `cards.json` keeps it (`CardKeep`): every field but `code`, which is its id's (`NodeIds.code(card:)`, a
        /// digest of the id, no secret: the voice rule is what keeps a code from any sender but the user's terminal) and
        /// is made again from the id as it's read, never taken from the file.
        enum CodingKeys: String, CodingKey { case id, project, root, kind, question, approval, config, base, plugin, notice, facts, closed, at, closedAt, draft }

        public init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: CodingKeys.self)
            id = try keys.decode(String.self, forKey: .id)
            code = NodeIds.code(card: id)
            project = try keys.decode(String.self, forKey: .project)
            root = try keys.decode(String.self, forKey: .root)
            kind = try keys.decode(Kind.self, forKey: .kind)
            question = try keys.decodeIfPresent(LeadQuestion.self, forKey: .question)
            approval = try keys.decodeIfPresent(ApprovalFacts.self, forKey: .approval)
            config = try keys.decodeIfPresent(ConfigHoldStore.Shown.self, forKey: .config)
            base = try keys.decodeIfPresent(BaseMoveStore.Shown.self, forKey: .base)
            plugin = try keys.decodeIfPresent(PluginCard.self, forKey: .plugin)
            notice = try keys.decodeIfPresent(String.self, forKey: .notice)
            facts = try keys.decodeIfPresent([String].self, forKey: .facts)
            closed = try keys.decodeIfPresent(String.self, forKey: .closed)
            at = try keys.decode(Date.self, forKey: .at)
            closedAt = try keys.decodeIfPresent(Date.self, forKey: .closedAt)
            draft = try keys.decodeIfPresent(Draft.self, forKey: .draft)
        }

        /// Whether it blocks the lead's work: a blocking question, any approval, held config, a base move.
        public var isBlocking: Bool {
            switch kind {
            case .question: return question?.rank == .blocking
            case .approval, .baseMove: return true
            // Something held (its own, or the home folder's it leaves to that card): no worker, verifier or merge until
            // accepted. A card with nothing held (rails to record, a first look owed) holds nothing up.
            case .configHeld: return config.map { $0.holdsWork ?? (!$0.items.isEmpty || $0.sharedHome != nil) } ?? true
            // The agent waits on it, not the lead's work.
            case .plugin: return false
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

    /// The plugin cards a server before this one drew, taken back from `cards.json` (`LeadEngine.restoreCards`), by
    /// `<plugin>:<request>`, until their plugin draws its request again (`adopt`): the card it draws then takes the kept
    /// one's id. Not shown meanwhile: the plugin's own program, started again, is asked about the request anew, and only
    /// what it answers is drawn (the kept card's words never come back). Dropped past their expiry.
    var kept: [String: Card] = [:]
    /// Whether cards a server before this one kept may still be taken back (a kept file was there at the start, and the
    /// first welcome's restore hasn't run yet): plugins draw nothing until it has (`PluginRuntime.look`), so a request is
    /// drawn again under its kept id.
    var restoring = false

    public init() {}

    /// `<plugin>:<request>`.
    static func keptKey(plugin: String, request: String) -> String { plugin + ":" + request }

    /// The id and time of the card a server before this one drew for `request` of `plugin`, taken out of `kept`; nil
    /// when none was kept, or it expired.
    func adopt(plugin: String, request: String, now: Date) -> Card? {
        guard let card = kept.removeValue(forKey: Self.keptKey(plugin: plugin, request: request)) else { return nil }
        return (card.plugin?.expiresAt).map { $0 > now } == true ? card : nil
    }

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
    /// pruned card is told to the stream as gone; asked for later it is `gone` (S3). On the engine's queue.
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
