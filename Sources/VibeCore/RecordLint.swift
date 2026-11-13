import Foundation

/// The repository's text lints that read the lead's records (`records_dir`, docs/lead/ by default), run on text before
/// it's recorded: PrivateNamesLint's names and SecretShapeLint's shapes, the same lists the lint tests use (one list,
/// never a copy). On 2026-11-12 at 10:57 a dismiss_finding reason named one of the user's other projects; it was committed
/// to docs/lead/progress.md, PrivateNamesLint failed every merge from then on, and the lead, which can't edit files,
/// couldn't take it out: merges stalled until about 13:45. Now the lead's recording tools refuse such text, saying what
/// matched, and nothing is recorded.
public enum RecordLint {
    /// Each of the user's other projects' names as two halves, matched in any case with an optional "-", "_", "." or
    /// space between them. Assembled, so this file passes PrivateNamesLint itself.
    public static let privateNames: [(String, String)] = [("stake", "gen"), ("gen", "swap")]

    public static let privateNamesPattern = try! NSRegularExpression(
        pattern: privateNames.map { "\($0.0)[-_. ]?\($0.1)" }.joined(separator: "|"), options: [.caseInsensitive])

    /// Which of the lints a repository carries: only those it runs (its own tests) apply to its records. The names
    /// are this repository's private ones; in those projects' own repositories they're their names.
    public struct Lints: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let privateNames = Lints(rawValue: 1)
        public static let secretShapes = Lints(rawValue: 2)
        public static let all: Lints = [.privateNames, .secretShapes]
    }

    /// The lints the repository at `root` carries, by their test files git tracks there (`PrivateNamesLintTests.swift`,
    /// `SecretShapeLintTests.swift`, anywhere in it). None when git can't say.
    public static func carried(root: String) -> Lints {
        let listed = Git.run(["ls-files", "--", ":(glob)**/PrivateNamesLintTests.swift", ":(glob)**/SecretShapeLintTests.swift"], in: root)
        guard listed.ok else { return [] }
        var lints: Lints = []
        if listed.output.contains("PrivateNamesLintTests.swift") { lints.insert(.privateNames) }
        if listed.output.contains("SecretShapeLintTests.swift") { lints.insert(.secretShapes) }
        return lints
    }

    /// What in `text` the lints would fail on: "a name of one of the user's other projects (“…”)" and "a <vendor>'s
    /// credential shape", each once; empty when it passes. The matched name is shown masked past its first letters,
    /// so the refusal doesn't carry it whole either. Only `lints` are run.
    public static func problems(in text: String, lints: Lints = .all) -> [String] {
        var found: [String] = []
        let range = NSRange(text.startIndex..., in: text)
        var names: [String] = []
        for match in lints.contains(.privateNames) ? privateNamesPattern.matches(in: text, range: range) : [] {
            guard let matched = Range(match.range, in: text) else { continue }
            let shown = masked(String(text[matched]))
            if !names.contains(shown) { names.append(shown) }
        }
        if !names.isEmpty {
            found.append("PrivateNamesLint: it names one of the user's other projects (\(names.map { "“\($0)”" }.joined(separator: ", "))); write 'project-b' or 'project-c' instead")
        }
        for name in lints.contains(.secretShapes) ? SecretShapes.found(in: text) : [] {
            found.append("SecretShapeLint: it holds a string shaped like a \(name); quote it cut short (`glpat-AbCd…`) or leave it out")
        }
        return found
    }

    /// Every string in `value` (a tool's arguments: strings, lists and objects of them), each once.
    public static func strings(in value: Any) -> [String] {
        switch value {
        case let text as String: return [text]
        case let list as [Any]: return list.flatMap { strings(in: $0) }
        case let object as [String: Any]: return object.keys.sorted().flatMap { [$0] + strings(in: object[$0]!) }
        default: return []
        }
    }

    /// The refusal for a tool call whose arguments fail the lints; nil when they pass.
    public static func refusal(tool: String, arguments: [String: Any], lints: Lints = .all) -> String? {
        guard !lints.isEmpty else { return nil }
        var problems: [String] = []
        for text in strings(in: arguments) {
            for problem in self.problems(in: text, lints: lints) where !problems.contains(problem) { problems.append(problem) }
        }
        guard !problems.isEmpty else { return nil }
        return "Refused, nothing recorded: \(tool)'s text would go into the lead's records (committed to the repository), and the repository's lints fail on it, "
            + "which would hold every merge after it. " + problems.joined(separator: "; ") + ". Call it again without it."
    }

    /// `name` with all but its first two letters masked ("st•••••••").
    static func masked(_ name: String) -> String {
        String(name.prefix(2)) + String(repeating: "•", count: max(1, name.count - 2))
    }

    /// The tools whose text goes into the lead's records (decisions.md, progress.md, incidents.md) or the board the
    /// records quote: each refuses text the lints fail on (`refusal`).
    public static let recordingTools: Set<String> = ["record_decision", "dismiss_finding", "record_incident", "add_task", "update_task",
                                                     "post_update", "progress"]
}
