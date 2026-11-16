import Foundation

/// While Claude refuses Fable (`AccountUsage.fableHeldBack`), new workers and audits that would run on Fable start on
/// Opus, and a worker Fable's refusal halted mid-task starts again on Opus in its own worktree, where it was, told why
/// (the user's answer of 2026-11-12, after boost-release-7-7 halted on “You're out of usage credits. Run /usage-credits
/// to keep using Fable 5.2 or /model to switch models.” and the lead moved it by hand). At the refusal's reset new
/// sessions are on Fable again. The lead is told once at each switch.
///
/// The witness (the app) sees the halt (`halts`) and hands it to the lead's tool server (`enqueue`, then a nudge),
/// whose loop (`LeadAdvance`) restarts the worker through start_worker's own checks. Each halt is restarted once: it's
/// kept by its session and its refusal's time, and claimed before the restart; the new worker runs on Opus, which
/// Fable's refusal doesn't stop.
public enum LeadUsageFallback {
    /// A worker halted at Fable's limit, as the witness saw it.
    public struct Halt: Codable, Equatable, Sendable {
        public var slug: String
        public var session: String
        /// When Claude wrote the refusal (else its reset, else 0): with the session, which halt it is.
        public var at: Double

        public init(slug: String, session: String, at: Double) {
            self.slug = slug
            self.session = session
            self.at = at
        }

        /// The witness's key for the same stop (`LeadWitness.usageLimitKey`): its notice waits while the restart is due.
        public var key: String { "\(session)|usage-limit-\(Int(at))" }
    }

    /// A refusal (from a session started on `model`, see `LeadTask.launchedModels`) that holds back Fable alone: a
    /// session on another model would go on.
    public static func fableOnly(_ limit: UsageLimit, model: String?) -> Bool {
        AccountUsage.fromRefusal(limit, model: model)?.model == AccountUsage.heldBackFamily
    }

    /// The model a task's session was started on, as its task noted (nil: Claude's default, or not noted).
    static func launchedModel(_ task: LeadTask, _ session: String) -> String? {
        task.launchedModels?[session].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The running tasks' workers stopped at Fable's limit now: live, their agent running, their turn ended on a
    /// refusal that holds back Fable alone.
    public static func halts(board: LeadBoard, seen: [String: LeadWitness.Seen]) -> [Halt] {
        board.tasks.compactMap { task in
            guard [.running, .failed].contains(task.status), let worker = task.worker, worker != task.stopped, let info = seen[worker],
                  info.live, !info.agentQuit, let limit = info.usageLimit, fableOnly(limit, model: launchedModel(task, worker)) else { return nil }
            return Halt(slug: task.slug, session: worker, at: limit.at ?? limit.resetsAt ?? 0)
        }
    }

    struct Record: Codable {
        var halt: Halt
        var handled: Double?
        var attempted: Bool?
        var released: Bool?
    }

    /// `told`: the reset of the Fable hold the lead was last told of (`AccountUsage.ends`); nil: told it's over, or
    /// never told of one.
    struct Kept: Codable {
        var halts: [Record] = []
        var told: Double?
    }

    /// `.vibeswitcher/usage-fallback.json`: the halts handed to the lead's tool server, and the switch last told. Kept
    /// across relaunches; a claim is recorded before the restart, so an uncertain one is left to the lead, not repeated.
    struct Store {
        let root: String
        var folder: String { (root as NSString).appendingPathComponent(".vibeswitcher") }
        var file: URL { URL(fileURLWithPath: folder).appendingPathComponent("usage-fallback.json") }
        /// How many restarts a task gets in an hour: a third halt is the lead's.
        static let perHour = 2

        func edit<T>(_ body: (inout Kept) throws -> T) throws -> T {
            guard let lock = FileLock.attempt((folder as NSString).appendingPathComponent("run/usage-fallback.lock")) else {
                throw BoardError(text: "The Fable fallback's record is busy")
            }
            defer { lock.release() }
            let original = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
            var kept = try original.map { try JSONDecoder().decode(Kept.self, from: $0) } ?? Kept()
            let result = try body(&kept)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(kept)
            if data != original { try VibePaths.writePrivate(data, to: file) }
            return result
        }

        func pending() throws -> [Halt] { try edit { $0.halts.filter { $0.handled == nil }.map(\.halt) } }

        /// Left to the lead: the witness tells it of the halt as before.
        func release(_ halt: Halt) throws {
            try edit { kept in
                guard let index = kept.halts.firstIndex(where: { $0.halt == halt }) else { return }
                kept.halts[index].released = true
            }
        }

        /// Claims `halt` once (nil: claimed before, or never handed over); whether it may be restarted: the task's
        /// restarts in the hour before `now` are under `perHour`.
        func claim(_ halt: Halt, now: Double, attempting: Bool = true) throws -> Bool? {
            try edit { kept in
                guard let index = kept.halts.firstIndex(where: { $0.halt == halt && $0.handled == nil }) else { return nil }
                let count = kept.halts.filter { $0.halt.slug == halt.slug && $0.attempted == true && ($0.handled ?? -.infinity) > now - 3600 }.count
                kept.halts[index].handled = now
                kept.halts[index].attempted = attempting && count < Self.perHour
                kept.halts = kept.halts.filter { ($0.handled ?? now) > now - 86_400 }
                return count < Self.perHour
            }
        }

        /// Records that the lead knows the hold ends at `ends` (nil: no hold); whether that's news.
        func switched(to ends: Double?) throws -> Bool {
            try edit { kept in
                guard kept.told != ends else { return false }
                kept.told = ends
                return true
            }
        }
    }

    /// Hands `halts` to the lead's tool server of `root` and nudges its loop when one is new; the keys of those whose
    /// restart is still due or under way (the witness holds their notices). A failed write hands over nothing: the
    /// witness tells the lead as before.
    public static func enqueue(_ halts: [Halt], root: String) -> Set<String> {
        guard !halts.isEmpty else { return [] }
        do {
            let (keys, added) = try Store(root: root).edit { kept in
                var added = false
                for halt in halts where !kept.halts.contains(where: { $0.halt == halt }) {
                    kept.halts.append(Record(halt: halt))
                    added = true
                }
                let held = kept.halts.filter { $0.released != true && halts.contains($0.halt) }
                return (Set(held.map(\.halt.key)), added)
            }
            if added { LeadAdvance.nudge(root: root) }
            return keys
        } catch { return [] }
    }

    /// What the restarted worker is told first.
    static func note(_ limit: AccountUsage.Limit?) -> String {
        "You were moved to Opus: Claude refused Fable at its usage limit (“You're out of usage credits”) and halted your previous session mid-task"
            + (limit.map { ", until \(UsageLimit.resetText(AccountUsage.ends($0)))" } ?? "") + ". "
            + "Your work so far is here, in this worktree on your task's branch: check git status and git log, then carry on where it was, on Opus."
    }
}
