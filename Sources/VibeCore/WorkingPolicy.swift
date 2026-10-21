import CryptoKit
import Foundation

/// The user's working policy: one text, kept in `~/.vibeswitcher/policy.md` and edited in Settings › Project lead, that
/// every project's lead, workers and verifiers get in their prompts (see `LeadPrompts`). The leads already running are
/// told when it changes, and once when a build that has it first runs (see `LeadWitness.PolicyWatch`).
public enum WorkingPolicy {
    /// The user's five rules (2026-10-21), verbatim.
    public static let defaultText = """
        - One agent owns each change through completion. Separate reviewers only for security, irreversible operations, or complex changes.
        - Run affected tests while editing, then the full suite once before merging. Repeat only when new changes justify it.
        - Parallelize independent implementation work. Serialize expensive builds and tests so workers don't compete for CPU.
        - Fix material bugs. Cosmetic observations don't automatically become tasks or block delivery.
        - Stop when the requested behavior works and relevant checks pass. No recursive audit loop without a concrete unresolved concern.
        """

    public static var file: URL { VibePaths.root.appendingPathComponent("policy.md") }
    /// Which policy the running leads were told, and which leads (see `LeadWitness.PolicyWatch`).
    public static var toldFile: URL { VibePaths.root.appendingPathComponent("policy-told.json") }

    /// The policy as it is now: the file's text, or the default while there's none (missing, unreadable or blank).
    public static func load(from file: URL = file) -> String {
        let text = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? defaultText : text
    }

    /// Writes it (0600); a blank text is the default.
    public static func save(_ text: String, to file: URL = file) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try VibePaths.ensurePrivate(file.deletingLastPathComponent())
        try VibePaths.writePrivate(Data(((trimmed.isEmpty ? defaultText : trimmed) + "\n").utf8), to: file)
    }

    /// The policy as each role's prompt has it.
    public static func section(_ text: String) -> String {
        "The user's working policy (for every project; VibeSwitcher's Settings › Project lead). Follow it; where the rest of "
            + "these instructions say more, they say how:\n" + text
    }

    /// What the witness tells a running lead: the policy, and to apply it from now on.
    public static func witnessText(_ text: String) -> String {
        "The user's working policy for every project, as it is now (VibeSwitcher's Settings › Project lead). Apply it from now "
            + "on in how you plan, delegate, review and merge. Workers and verifiers you start get it in their prompts; tell the "
            + "ones running now what concerns their task.\n\n" + text
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension LeadWitness {
    /// The working policy, told to each running lead once: when it changes (a lead running then has the old one in
    /// its prompt), and once when a build that has it first runs (leads started before it have none). A lead started
    /// with it in its prompt (`started`) isn't told it again. What was told to which lead is kept in `file`, so a
    /// relaunch doesn't tell it again.
    public struct PolicyWatch {
        let read: () -> String
        let file: URL

        public init(read: @escaping () -> String = { WorkingPolicy.load() }, file: URL = WorkingPolicy.toldFile) {
            self.read = read
            self.file = file
        }

        /// The policy's digest, and the leads (their sessions) that have it.
        struct Told: Codable, Equatable {
            var digest: String
            var leads: [String]
        }

        /// The most leads kept as told: the oldest go first (they ended long ago).
        static let kept = 200

        /// The leads of `running` (their sessions) to tell now, and what: none when each was told this policy or
        /// started with it. Those returned count as told from now on.
        public func look(running: [String]) -> (text: String, leads: [String])? {
            let policy = read()
            let digest = WorkingPolicy.digest(policy)
            let before = load()
            var told = before.flatMap { $0.digest == digest ? $0 : nil } ?? Told(digest: digest, leads: [])
            var seen = Set(told.leads)
            let due = running.filter { seen.insert($0).inserted }
            guard !due.isEmpty else {
                // Changed, with no lead to tell: leads started from now on have it in their prompts.
                if before != told { save(told) }
                return nil
            }
            told.leads = Array((told.leads + due).suffix(Self.kept))
            save(told)
            return (WorkingPolicy.witnessText(policy), due)
        }

        /// The lead on `session` started with `policy` in its prompt: told, as long as that's the policy now (one
        /// changed since is told to it at the next look).
        public func started(_ session: String, with policy: String) {
            let digest = WorkingPolicy.digest(policy)
            guard digest == WorkingPolicy.digest(read()) else { return }
            var told = load().flatMap { $0.digest == digest ? $0 : nil } ?? Told(digest: digest, leads: [])
            guard !told.leads.contains(session) else { return }
            told.leads = Array((told.leads + [session]).suffix(Self.kept))
            save(told)
        }

        func load() -> Told? {
            (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Told.self, from: $0) }
        }

        func save(_ told: Told) {
            guard let data = try? JSONEncoder().encode(told) else { return }
            try? VibePaths.ensurePrivate(file.deletingLastPathComponent())
            try? VibePaths.writePrivate(data, to: file)
        }
    }
}
