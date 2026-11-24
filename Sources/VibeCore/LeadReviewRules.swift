import Foundation

/// REVIEW.md's rules by id: each rule in it names its id, its trigger (what in a diff makes it apply) and its source
/// (the task, incident or finding it came from). The verifier applies only the rules whose triggers the diff matches
/// and lists their ids in submit_audit's `rules`, each finding naming the rule it comes from (`rule`); the audit's
/// ledger keeps one `LeadRuleUse` per audit, and status counts them per rule over `window` so the lead can prune, in
/// a retrospective, rules that never apply or never find anything.
///
/// Idea from 'How the Claude Code team thinks about verification' (claude.dev, Nov 2026): a checklist whose items each
/// carry a trigger readable from a diff and the incidents behind them, checked only where the trigger matches, and
/// pruned routinely. Agreed with the user on 2026-11-23.
public enum LeadReviewRules {
    /// How far back status counts.
    public static let window: Double = 30 * 86_400

    /// A rule id as REVIEW.md and a verdict write it: letters then digits ("R3"), at most 12 characters.
    static let idPattern = try! NSRegularExpression(pattern: #"^[A-Za-z]{1,4}[0-9]{1,4}$"#)

    /// `said` as a rule id: its first word, trimmed of `*`, brackets and punctuation, upper-cased ("R1 (main thread)",
    /// "**r1**:" are R1); nil when that isn't one.
    public static func id(_ said: String) -> String? {
        let first = said.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        let word = first.trimmingCharacters(in: CharacterSet(charactersIn: "*`[](),.:;-")).uppercased()
        let range = NSRange(word.startIndex..., in: word)
        return idPattern.firstMatch(in: word, range: range) == nil ? nil : word
    }

    /// What a verifier may write for no rule at all.
    static let none: Set<String> = ["none", "n/a", "na", "-", "no rules", "nothing"]

    /// The rule ids REVIEW.md gives, in its order: each list item starting with one in bold ("- **R3** …").
    public static func ids(in guide: String?) -> [String] {
        guard let guide else { return [] }
        let item = try! NSRegularExpression(pattern: #"^\s*[-*]\s+\*\*([A-Za-z]{1,4}[0-9]{1,4})\*\*"#)
        var seen: Set<String> = []
        return guide.split(whereSeparator: \.isNewline).compactMap { line in
            let text = String(line)
            guard let match = item.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            let id = text[range].uppercased()
            return seen.insert(id).inserted ? id : nil
        }
    }

    /// Ids in rule order: by their letters, then their number (R2 before R10).
    public static func sorted<S: Sequence>(_ ids: S) -> [String] where S.Element == String {
        Set(ids).sorted { a, b in
            let (lettersA, numberA) = split(a), (lettersB, numberB) = split(b)
            return lettersA != lettersB ? lettersA < lettersB : numberA != numberB ? numberA < numberB : a < b
        }
    }

    private static func split(_ id: String) -> (String, Int) {
        let letters = String(id.prefix { $0.isLetter })
        return (letters, Int(id.dropFirst(letters.count)) ?? 0)
    }

    /// One rule's count over the window: the audits that applied it, and those of them it produced a finding in.
    public struct Count: Equatable, Sendable {
        public var applied = 0
        public var found = 0

        public init(applied: Int = 0, found: Int = 0) {
            self.applied = applied
            self.found = found
        }
    }

    /// The audits of `tasks` since `now - window` that listed their rules: how many, and each rule's count.
    public static func counts(_ tasks: [LeadTask], now: Double, window: Double = window) -> (audits: Int, rules: [String: Count]) {
        var audits = 0
        var rules: [String: Count] = [:]
        for task in tasks where task.removedAt == nil {
            for use in task.audits?.ruleUses ?? [] where use.at > now - window && use.at <= now + 1 {
                audits += 1
                for id in use.applied { rules[id, default: Count()].applied += 1 }
                for id in Set(use.found) { rules[id, default: Count()].found += 1 }
            }
        }
        return (audits, rules)
    }

    /// Status's line: each rule's count over the last 30 days, REVIEW.md's rules (`known`) first, with those that
    /// were never applied and those applied that never found anything named; nil when no audit listed its rules.
    /// `known` is read only then (status reads REVIEW.md from the base branch for it).
    public static func statusLine(_ tasks: [LeadTask], known: @autoclosure () -> [String], now: Double) -> String? {
        let (audits, rules) = counts(tasks, now: now)
        guard audits > 0 else { return nil }
        let known = known()
        let order = known + sorted(rules.keys.filter { !known.contains($0) })
        let each = order.map { id -> String in
            let count = rules[id] ?? Count()
            return "\(id) \(count.applied)/\(count.found)" + (known.isEmpty || known.contains(id) ? "" : " (not in REVIEW.md)")
        }
        var line = "Review rules, last 30 days (\(audits) audit\(audits == 1 ? "" : "s") listed theirs; applied/with a finding): "
            + each.joined(separator: ", ") + "."
        let never = known.filter { (rules[$0]?.applied ?? 0) == 0 }
        let fruitless = order.filter { (rules[$0]?.applied ?? 0) > 0 && rules[$0]?.found == 0 }
        if !never.isEmpty { line += " Never applied: \(never.joined(separator: ", "))." }
        if !fruitless.isEmpty { line += " Applied, never a finding: \(fruitless.joined(separator: ", "))." }
        return line
    }
}

/// One audit's REVIEW.md rules (`LeadReviewRules`): the ids it applied, as its verdict listed them, and those among
/// them its new findings came from. Kept on the task's `LeadAuditLedger`.
public struct LeadRuleUse: Codable, Equatable, Sendable {
    /// The audit round it was.
    public var round: Int
    public var at: Double
    public var applied: [String]
    /// The rules that produced a new finding in it (each once); always among `applied`.
    public var found: [String]

    public init(round: Int, at: Double, applied: [String], found: [String]) {
        let found = LeadReviewRules.sorted(found)
        self.round = round
        self.at = at
        // A finding naming a rule the list left out: it was applied all the same.
        self.applied = LeadReviewRules.sorted(applied + found)
        self.found = found
    }
}
