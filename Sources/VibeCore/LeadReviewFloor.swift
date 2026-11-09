import Foundation

/// The least strict the review rules may be in a project, as the user set it in Settings › Project lead (Review rules
/// floor): the lead's configure may raise a rule above it, never lower one below it, and what's in force is the floor
/// joined with workflow.md (paths: both lists; numbers and policies: the stricter). The user's decision, 2026-11-07
/// (F0181AFD): "a floor in Settings that the lead can raise but not lower": the lead set the policy that judges its
/// own proposals.
///
/// Kept in the session host's vault, per repository (`LeadVault.reviewFloor`), and written there only by the app
/// (the host tells the app from the sessions by the process asking, not by what it says): a worker or lead that
/// writes workflow.md, or asks the host itself, can't lower it. Recorded when the app first starts the project's lead
/// after this build, at the project's values then (`starting(from:)`), so nothing changes until the user raises it.
public struct LeadReviewFloor: Codable, Equatable, Sendable {
    /// Globs ask_sensitive holds back that the project's sensitive_paths always holds too.
    public var sensitivePaths: [String]
    /// Globs strict_paths always holds too.
    public var strictPaths: [String]
    /// The fewest finders an audit runs.
    public var auditFinders: Int
    /// The least strict merge policy (auto < ask_sensitive < ask_all).
    public var mergePolicy: LeadWorkflow.MergePolicy
    /// The most lines a review none task may change before it's audited (lower is stricter); 0: no floor on it.
    public var riskLines: Int
    /// The risk check's model pass stays on.
    public var riskModel: Bool
    /// Audits never run on the workers' model (verifier_model may name any other).
    public var verifierDifferent: Bool
    /// The least share, in percent, of review none tasks auto_advance audits anyway (audit_sample_percent; higher is
    /// stricter); 0: no floor on it.
    public var auditSamplePercent: Int

    public init(sensitivePaths: [String] = [], strictPaths: [String] = [], auditFinders: Int = 1, mergePolicy: LeadWorkflow.MergePolicy = .auto,
                riskLines: Int = 0, riskModel: Bool = false, verifierDifferent: Bool = true, auditSamplePercent: Int = 0) {
        self.sensitivePaths = Self.clean(sensitivePaths)
        self.strictPaths = Self.clean(strictPaths)
        self.auditFinders = min(LeadWorkflow.maxFinders, max(1, auditFinders))
        self.mergePolicy = mergePolicy
        self.riskLines = max(0, riskLines)
        self.riskModel = riskModel
        self.verifierDifferent = verifierDifferent
        self.auditSamplePercent = min(100, max(0, auditSamplePercent))
    }

    enum CodingKeys: String, CodingKey {
        case sensitivePaths, strictPaths, auditFinders, mergePolicy, riskLines, riskModel, verifierDifferent, auditSamplePercent
    }

    /// A floor recorded before audit_sample_percent was part of it holds no share (0).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(sensitivePaths: try c.decode([String].self, forKey: .sensitivePaths), strictPaths: try c.decode([String].self, forKey: .strictPaths),
                  auditFinders: try c.decode(Int.self, forKey: .auditFinders), mergePolicy: try c.decode(LeadWorkflow.MergePolicy.self, forKey: .mergePolicy),
                  riskLines: try c.decode(Int.self, forKey: .riskLines), riskModel: try c.decode(Bool.self, forKey: .riskModel),
                  verifierDifferent: try c.decode(Bool.self, forKey: .verifierDifferent),
                  auditSamplePercent: try c.decodeIfPresent(Int.self, forKey: .auditSamplePercent) ?? 0)
    }

    /// The floor at a project's values now: its sensitive_paths (the defaults when it names none) and strict_paths,
    /// its audit_finders, merge_policy (auto when not chosen yet: not chosen holds nothing back at the floor),
    /// risk_lines, risk_model, audit_sample_percent, and audits on another model than the workers' (unless
    /// verifier_model names theirs: `workerModel`, the model the workers start with; nil: not known).
    public static func starting(from workflow: LeadWorkflow, workerModel: String? = nil) -> LeadReviewFloor {
        let sameModel = workflow.verifierModel.map { !$0.isEmpty && LeadReviewFloor.sameModel($0, workerModel) } ?? false
        return LeadReviewFloor(sensitivePaths: workflow.sensitivePaths ?? LeadWorkflow.defaultSensitivePaths, strictPaths: workflow.strictPaths ?? [],
                               auditFinders: workflow.auditFinders, mergePolicy: workflow.mergePolicy ?? .auto,
                               riskLines: workflow.riskLines, riskModel: workflow.riskModel, verifierDifferent: !sameModel,
                               auditSamplePercent: workflow.auditSamplePercent)
    }

    /// Where the user changes it, as a refusal names it.
    public static let place = "VibeSwitcher's Settings › Project lead › Review rules floor"

    /// The keys of workflow.md it's a floor for.
    public static let keys = ["sensitive_paths", "strict_paths", "audit_finders", "merge_policy", "risk_lines", "risk_model", "verifier_model",
                              "audit_sample_percent"]

    static func clean(_ globs: [String]) -> [String] {
        var seen = Set<String>()
        return globs.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// auto 0, ask_sensitive 1, ask_all 2.
    static func rank(_ policy: LeadWorkflow.MergePolicy) -> Int {
        switch policy {
        case .auto: return 0
        case .askSensitive: return 1
        case .askAll: return 2
        }
    }

    /// Whether two of `claude --model`'s names are one model: the same family (fable, opus, sonnet, haiku) or the same
    /// name. False when either isn't known.
    public static func sameModel(_ one: String?, _ other: String?) -> Bool {
        guard let one = one?.trimmingCharacters(in: .whitespaces).lowercased(), !one.isEmpty,
              let other = other?.trimmingCharacters(in: .whitespaces).lowercased(), !other.isEmpty else { return false }
        let family = { (name: String) in ["fable", "opus", "sonnet", "haiku"].first { name.contains($0) } ?? name }
        return family(one) == family(other)
    }

    /// The workers' model as the floor compares a verifier with: theirs when it names one, else opus (unset, or an
    /// alias such as default: Claude's default, which counts as opus), so an unknown workers' model never lets
    /// audits onto it.
    public static func workersModel(_ workerModel: String?) -> String {
        guard let name = workerModel?.trimmingCharacters(in: .whitespaces), knownModel(name) else { return "opus" }
        return name
    }

    /// A name `claude --model` takes that says which model it is: one of the families, or a claude-… id of one.
    /// An alias (default, best) or anything else may be any model.
    public static func knownModel(_ name: String) -> Bool {
        let name = name.lowercased()
        return ["fable", "opus", "sonnet", "haiku"].contains { name.contains($0) }
    }

    /// risk_lines as strictness: 0 (no size trigger) is the least strict.
    static func looser(_ lines: Int, than floor: Int) -> Bool {
        guard floor > 0 else { return false }
        return lines == 0 || lines > floor
    }

    // MARK: Refusing

    /// Why configure can't set `key` to `value` (as configure normalized it; empty: cleared, so its default) under
    /// this floor; nil when it may. `workerModel`: the model the workers run (nil: not known).
    public func refusal(key: String, value: String, workerModel: String?) -> String? {
        switch key {
        case "sensitive_paths", "strict_paths":
            let given = LeadWorkflow.globs(value) ?? (key == "sensitive_paths" ? LeadWorkflow.defaultSensitivePaths : [])
            let floor = key == "sensitive_paths" ? sensitivePaths : strictPaths
            let dropped = floor.filter { !given.contains($0) }
            guard !dropped.isEmpty else { return nil }
            return "\(key) would leave out \(dropped.joined(separator: ", ")), which the floor holds"
        case "audit_finders":
            let count = Int(value) ?? 1
            return count < auditFinders ? "audit_finders \(count) is under the floor of \(auditFinders)" : nil
        case "merge_policy":
            // Not chosen is handled as ask_sensitive.
            let policy = LeadWorkflow.MergePolicy(text: value) ?? .askSensitive
            return Self.rank(policy) < Self.rank(mergePolicy)
                ? "merge_policy \(value.isEmpty ? "cleared (handled as ask_sensitive)" : policy.rawValue) is looser than the floor's \(mergePolicy.rawValue)" : nil
        case "risk_lines":
            let lines = Int(value) ?? LeadRisk.defaultLines
            return Self.looser(lines, than: riskLines)
                ? "risk_lines \(lines == 0 ? "0 (no size trigger)" : String(lines)) is looser than the floor's \(riskLines) (lower is stricter)" : nil
        case "risk_model":
            let on = LeadWorkflow.flag(value) ?? true
            return riskModel && !on ? "risk_model false is under the floor, which keeps the risk check's model pass on" : nil
        case "audit_sample_percent":
            let percent = Int(value) ?? LeadAuditSample.defaultPercent
            return percent < auditSamplePercent ? "audit_sample_percent \(percent) is under the floor of \(auditSamplePercent)" : nil
        case "verifier_model":
            guard verifierDifferent, !value.isEmpty else { return nil }
            if !Self.knownModel(value) {
                return "verifier_model \(value) doesn't say which model it is (name one: fable, opus, sonnet, haiku, or its claude-… id), and the floor says audits never run on the workers' model"
            }
            guard Self.sameModel(value, Self.workersModel(workerModel)) else { return nil }
            return "verifier_model \(value) is the workers' model (\(workerModel ?? "Claude's default, opus")), and the floor says audits run on a different one"
        default:
            return nil
        }
    }

    // MARK: Showing it

    /// "a, b, … (12)" for a long list, "none" for an empty one.
    static func list(_ globs: [String], limit: Int = 6) -> String {
        guard !globs.isEmpty else { return "none" }
        return globs.prefix(limit).joined(separator: ", ") + (globs.count > limit ? ", … (\(globs.count))" : "")
    }

    /// For status (which stays short on a big board; configure() has `lines`): one line naming each rule the floor
    /// holds above what workflow.md says, in force and the file's value; nil while the floor changes nothing.
    public func statusLine(_ workflow: LeadWorkflow, workerModel: String?) -> String? {
        var file = workflow
        file.floor = nil
        var held: [String] = []
        func rule(_ name: String, _ inForce: String, _ written: String) {
            if inForce != written { held.append("\(name) \(inForce) (workflow.md: \(written))") }
        }
        rule("audit_finders", String(workflow.findersInForce), String(file.findersInForce))
        rule("merge_policy", workflow.policyInForce?.rawValue ?? "ask_sensitive (not chosen)", file.policyInForce?.rawValue ?? "ask_sensitive (not chosen)")
        rule("risk_lines", String(workflow.riskLinesInForce), file.riskLinesInForce == 0 ? "0, no size trigger" : String(file.riskLinesInForce))
        rule("risk_model", workflow.riskModelInForce ? "on" : "off", file.riskModelInForce ? "on" : "off")
        rule("audit_sample_percent", String(workflow.samplePercentInForce), String(file.samplePercentInForce))
        rule("audits on", workflow.auditModel(workerModel: workerModel), file.auditModel(workerModel: workerModel))
        for (name, inForce, written) in [("sensitive_paths", workflow.sensitiveGlobs, file.sensitiveGlobs),
                                         ("strict_paths", workflow.strictGlobs ?? [], file.strictGlobs ?? [])] {
            let added = inForce.filter { !written.contains($0) }
            if !added.isEmpty { held.append("\(name) also \(Self.list(added, limit: 3))") }
        }
        guard !held.isEmpty else { return nil }
        return "Review rules' floor (the user's; configure can't go below it; configure() shows every rule) holds above workflow.md: "
            + held.joined(separator: "; ") + "."
    }

    /// Each rule: the floor, and what's in force (the floor joined with `workflow`), for status and configure.
    public func lines(_ workflow: LeadWorkflow, auditModel: String) -> [String] {
        [
            "- sensitive_paths: floor \(Self.list(sensitivePaths)); in force \(Self.list(workflow.sensitiveGlobs))",
            "- strict_paths: floor \(Self.list(strictPaths)); in force \(Self.list(workflow.strictGlobs ?? []))",
            "- audit_finders: floor \(auditFinders); in force \(workflow.findersInForce)",
            "- merge_policy: floor \(mergePolicy.rawValue); in force \(workflow.policyInForce?.rawValue ?? "not chosen (ask_sensitive)")",
            "- risk_lines: floor \(riskLines == 0 ? "none" : String(riskLines)); in force \(workflow.riskLinesInForce == 0 ? "0 (no size trigger)" : String(workflow.riskLinesInForce))",
            "- risk_model: floor \(riskModel ? "on" : "off (either)"); in force \(workflow.riskModelInForce)",
            "- audit_sample_percent: floor \(auditSamplePercent); in force \(workflow.samplePercentInForce)",
            "- verifier: floor \(verifierDifferent ? "never the workers' model" : "any model"); audits run on \(auditModel)",
        ]
    }
}

extension LeadWorkflow.MergePolicy: Codable {}

// MARK: What's in force

extension LeadWorkflow {
    /// strict_paths joined with the floor's; nil when neither names any.
    public var strictGlobs: [String]? {
        let joined = LeadReviewFloor.clean((strictPaths ?? []) + (floor?.strictPaths ?? []))
        return joined.isEmpty ? nil : joined
    }

    /// audit_finders, at least the floor's.
    public var findersInForce: Int { max(auditFinders, floor?.auditFinders ?? 1) }

    /// merge_policy, at least the floor's; nil (not chosen, handled as ask_sensitive) while that's at least as strict.
    public var policyInForce: MergePolicy? {
        guard let floor = floor?.mergePolicy else { return mergePolicy }
        let now = mergePolicy ?? .askSensitive
        if LeadReviewFloor.rank(floor) > LeadReviewFloor.rank(now) { return floor }
        return mergePolicy
    }

    /// risk_lines, at most the floor's (0, no size trigger, is the loosest).
    public var riskLinesInForce: Int {
        guard let floor = floor?.riskLines, floor > 0 else { return riskLines }
        return riskLines == 0 ? floor : min(riskLines, floor)
    }

    /// risk_model, on when the floor keeps it on.
    public var riskModelInForce: Bool { riskModel || floor?.riskModel == true }

    /// audit_sample_percent, at least the floor's.
    public var samplePercentInForce: Int { max(auditSamplePercent, floor?.auditSamplePercent ?? 0) }
}

// MARK: In the vault

extension LeadVault {
    /// The review rules' floor the user set for the repository; nil while none is recorded.
    public func reviewFloor(root: String) throws -> LeadReviewFloor? {
        guard case .reviewFloor(let floor) = try call(.reviewFloor(root: root)) else { throw Self.unexpected }
        return floor
    }

    /// Records the floor (the app only: the host refuses anyone else). `onlyIfUnset`: only while none is recorded.
    /// The floor recorded after it.
    @discardableResult
    public func setReviewFloor(_ floor: LeadReviewFloor, root: String, onlyIfUnset: Bool = false) throws -> LeadReviewFloor? {
        guard case .reviewFloor(let recorded) = try call(.setReviewFloor(root: root, floor: floor, onlyIfUnset: onlyIfUnset)) else { throw Self.unexpected }
        return recorded
    }
}
