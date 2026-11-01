import Foundation

/// How close the Claude account is to its usage limits, as far as VibeSwitcher can tell, so the lead's tools back off
/// before a limit stops work mid-task (2026-10-31: a worker stalled at the weekly limit until the user switched
/// accounts; 2026-11-01: every audit stopped at the Fable limit until the lead set verifier_model to opus).
///
/// What Claude Code 2.1.316 exposes (looked at 2026-11-01), and what's read of it:
/// - **The status line's input** (`rate_limits`, for Claude.ai subscribers, after a session's first reply): per window,
///   `five_hour` and `seven_day`, its `used_percentage` (0–100) and `resets_at` (epoch seconds); behind a gateway,
///   `spend_limit` too. These are the whole account's, whatever model the session runs. The workers' and verifiers'
///   sessions get VibeSwitcher's status line (`statusLineArgument`, see `LeadLaunch.prepare`), which records them here
///   and then shows your own status line as it would have been. No per-model percentage is in it.
/// - **Transcripts** say nothing of usage until a request is refused: then the API-error line (`isApiErrorMessage`)
///   carries `apiError` (`usage_limit_reached`, or `model_requires_usage_credits` when only that model is out, as
///   Fable was on 2026-11-01), `apiErrorParams.rate_limit_info` / `quotaLimits` with `status: rejected`,
///   `rateLimitType` (`five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`, `seven_day_overage_included`, …)
///   and `resetsAt` (see `UsageLimit.read`). A refusal is a limit at 100 % until its reset: for every model, or for
///   that model only (its type names one, or the model needs usage credits).
/// - Claude Code reads per-window utilization from the API's `anthropic-ratelimit-unified-*` headers and shows /usage
///   in its own screen, but writes neither to a file; the OAuth usage endpoint would need the account's token from
///   the Keychain, which VibeSwitcher doesn't touch.
///
/// Best effort, failing safe: what isn't known (no subscriber windows, no status line run yet, a file that can't be
/// read, a reading whose window has reset) means no back-off, never a stop.
public struct AccountUsage: Equatable, Sendable {
    /// One limit as last read.
    public struct Limit: Codable, Equatable, Sendable {
        /// Claude's name for it: the status line's window (`seven_day`, `five_hour`, `spend_limit`), or a refusal's
        /// `rateLimitType`.
        public var name: String
        /// The model family it holds back (`fable`, `opus`, `sonnet`); nil: every model.
        public var model: String?
        /// How much of it is used, 0–100 (a refusal: 100).
        public var usedPercent: Double
        /// When it resets (epoch seconds), when said.
        public var resetsAt: Double?
        /// When it was read (epoch seconds).
        public var at: Double
        /// Claude refused a request at it (rather than a status line's reading).
        public var reached: Bool

        public init(name: String, model: String? = nil, usedPercent: Double, resetsAt: Double? = nil, at: Double, reached: Bool = false) {
            self.name = name
            self.model = model
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
            self.at = at
            self.reached = reached
        }

        /// What it's kept under: one reading per limit and model.
        public var key: String { model.map { "\(name)|\($0)" } ?? name }

        /// "the weekly limit", "the 5-hour limit", "the fable limit (seven_day_overage_included)".
        public var label: String {
            switch name {
            case "seven_day": return model.map { "the weekly limit on \($0)" } ?? "the weekly limit"
            case "five_hour": return model.map { "the 5-hour limit on \($0)" } ?? "the 5-hour limit"
            case "spend_limit": return "the spend limit"
            case "seven_day_opus": return "the weekly Opus limit"
            case "seven_day_sonnet": return "the weekly Sonnet limit"
            default: return model.map { "the \($0) limit (\(name))" } ?? "the \(name.replacingOccurrences(of: "_", with: " ")) limit"
            }
        }

        /// "the weekly limit (every model): 84% used, resets Nov 3, 01:00".
        public var text: String {
            let scope = model == nil ? " (every model)" : ""
            let used = reached ? "reached (Claude refused a request at it)" : "\(Int(usedPercent.rounded()))% used"
            return "\(label)\(scope): \(used), " + (resetsAt.map { "resets \(UsageLimit.resetText($0))" } ?? "reset time not known")
        }

        /// It still holds at `now`: its window hasn't reset; a reading with no reset time counts for `untimed` after it.
        func current(at now: Double) -> Bool {
            if let resetsAt { return resetsAt > now }
            return now - at < AccountUsage.untimed
        }
    }

    public var limits: [Limit]

    public init(limits: [Limit] = []) { self.limits = limits }

    /// At this share of a limit (in percent) the lead's tools stop starting workers and audits on the models it holds
    /// back, unless the lead overrides.
    public static let threshold = 80.0
    /// How long a reading without a reset time is believed.
    static let untimed: Double = 3600

    /// Its limits still holding at `now`, the most used first.
    public func current(now: Date = Date()) -> AccountUsage {
        AccountUsage(limits: limits.filter { $0.current(at: now.timeIntervalSince1970) }.sorted { ($0.usedPercent, $1.key) > ($1.usedPercent, $0.key) })
    }

    /// The limit that holds back a start on `model` (as `claude --model` names it; nil: Claude's default) at `now`: the
    /// most used of those at or past `threshold`, for every model or for its family; nil when none is (or none is known).
    public func hold(model: String?, now: Date = Date(), threshold: Double = AccountUsage.threshold) -> Limit? {
        let family = Self.family(model)
        return current(now: now).limits.first { limit in
            limit.usedPercent >= threshold && (limit.model == nil || limit.model == family)
        }
    }

    /// The model family a model name is of: fable, opus, sonnet or haiku when it names one ("claude-fable-5-1",
    /// "opus[1m]"), else the name itself, lowercased; nil for none.
    public static func family(_ model: String?) -> String? {
        guard let model = model?.trimmingCharacters(in: .whitespaces).lowercased(), !model.isEmpty else { return nil }
        return ["fable", "opus", "sonnet", "haiku"].first { model.contains($0) } ?? model
    }

    /// The windows in a status line's input (`rate_limits`): each with a `used_percentage`, for every model.
    public static func fromStatusLine(_ input: [String: Any], now: Date = Date()) -> [Limit] {
        guard let windows = input["rate_limits"] as? [String: Any] else { return [] }
        return windows.keys.sorted().compactMap { name in
            guard let window = windows[name] as? [String: Any], let used = (window["used_percentage"] as? NSNumber)?.doubleValue,
                  used.isFinite else { return nil }
            let resets = (window["resets_at"] as? NSNumber)?.doubleValue
            return Limit(name: name, usedPercent: max(0, used), resetsAt: resets, at: now.timeIntervalSince1970)
        }
    }

    /// A refusal at the account's usage limit (`UsageLimit`, from a transcript) in a session running `model`: that
    /// limit at 100 % until its reset; for that model's family only when its type names a model, or the model needs
    /// usage credits (its weekly allowance is spent: `model_requires_usage_credits`), else for every model. Nil for a
    /// model-only refusal whose model isn't known (Claude's default, a session no task names): unknown usage holds
    /// nothing back, and kept for every model it would stop every start.
    public static func fromRefusal(_ limit: UsageLimit, model: String?, now: Date = Date()) -> Limit? {
        let kind = limit.kind ?? "usage"
        let named = ["fable", "opus", "sonnet", "haiku"].first { kind.lowercased().contains($0) }
        let modelOnly = limit.apiError == "model_requires_usage_credits"
        let scoped = named ?? (modelOnly ? family(model) : nil)
        if modelOnly, scoped == nil { return nil }
        return Limit(name: kind, model: scoped, usedPercent: 100, resetsAt: limit.resetsAt, at: limit.at ?? now.timeIntervalSince1970, reached: true)
    }

    /// For the lead's status: each limit known, or nil when none is.
    public func statusText(now: Date = Date()) -> String? {
        let known = current(now: now).limits
        guard !known.isEmpty else { return nil }
        return "Account usage (best effort: what sessions' status lines and refusals said): " + known.map(\.text).joined(separator: "; ")
            + ". At \(Int(Self.threshold))% of a limit, start_worker and audit stop starting sessions on the models it holds back (override_usage: true overrides)."
    }
}

/// Where the account's usage is kept between readings: `~/.vibeswitcher/account-usage.json` (0600), one reading per limit,
/// the newest kept. Every project's lead reads it (the account is the Mac's). A file that can't be read is no usage known.
public struct AccountUsageStore: Sendable {
    public var file: URL

    public init(file: URL = AccountUsageStore.standardFile) { self.file = file }

    public static var standardFile: URL { VibePaths.root.appendingPathComponent("account-usage.json") }
    /// How old a reading must be before the same one read again replaces it.
    static let refresh: Double = 300

    private struct Stored: Codable { var limits: [AccountUsage.Limit] }

    /// What's kept (whatever its age; `AccountUsage.current` drops what has reset).
    public func load() -> AccountUsage {
        guard let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return AccountUsage() }
        return AccountUsage(limits: stored.limits)
    }

    /// Keeps `limits`, each replacing an older reading of the same limit (never a newer one), and drops readings
    /// that have reset. Nothing is written when nothing changes. Best effort: a write that fails is no reading kept.
    public func record(_ limits: [AccountUsage.Limit], now: Date = Date()) {
        guard !limits.isEmpty else { return }
        let before = load().limits
        var kept = Dictionary(before.map { ($0.key, $0) }, uniquingKeysWith: { $0.at >= $1.at ? $0 : $1 })
        for limit in limits {
            guard let old = kept[limit.key] else { kept[limit.key] = limit; continue }
            // Newer only; the same reading again (a status line runs at every change of the session's screen) is
            // rewritten only once it's `refresh` old, so the file isn't written each time.
            let same = old.usedPercent == limit.usedPercent && old.resetsAt == limit.resetsAt && old.model == limit.model && old.reached == limit.reached
            if old.at <= limit.at, !same || limit.at - old.at >= Self.refresh { kept[limit.key] = limit }
        }
        let after = kept.values.filter { $0.current(at: now.timeIntervalSince1970) }.sorted { $0.key < $1.key }
        guard after != before.sorted(by: { $0.key < $1.key }) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Stored(limits: after)) else { return }
        try? VibePaths.ensurePrivate(file.deletingLastPathComponent())
        try? VibePaths.writePrivate(data, to: file)
    }
}

/// The status line VibeSwitcher gives the sessions it starts (lead, workers, verifiers; see `LeadLaunch.prepare`):
/// `vibeswitcher-mcp --status-line`. Claude Code runs it with the session's state on its input, which carries the
/// account's usage windows (`rate_limits`); it keeps them (`AccountUsageStore`), then runs your own status line (your
/// Claude settings' `statusLine` command) with the same input and prints what it prints, so the session's status line
/// reads as yours would. Your own sessions keep theirs untouched. With no status line of yours, it prints the usage.
public enum UsageStatusLine {
    public static let argument = "--status-line"
    /// How long your own status line may take before it's stopped (Claude Code gives up on a slow one too).
    public static let patience: TimeInterval = 5

    /// The status line's settings entry for a role's `--settings`: this tool server run with `argument`.
    public static func settings(server: String) -> [String: Any] {
        ["type": "command", "command": RecentProjects.shellQuote(server) + " " + argument]
    }

    /// Keeps the usage `input` carries, then returns what to print: your own status line's output, else the usage
    /// in a few words. Never fails: input that isn't JSON keeps nothing.
    public static func run(input: Data, store: AccountUsageStore = AccountUsageStore(), home: String = VibePaths.home, now: Date = Date(),
                           patience: TimeInterval = UsageStatusLine.patience) -> String {
        let object = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
        let limits = object.map { AccountUsage.fromStatusLine($0, now: now) } ?? []
        store.record(limits, now: now)
        if let command = userCommand(home: home) { return runCommand(command, input: input, patience: patience) ?? "" }
        return limits.map { limit in
            let name = limit.name == "seven_day" ? "weekly" : limit.name == "five_hour" ? "5h" : limit.name.replacingOccurrences(of: "_", with: " ")
            return "\(name) \(Int(limit.usedPercent.rounded()))%"
        }.joined(separator: " · ")
    }

    /// Your Claude settings' status line command (`statusLine.command` in `~/.claude/settings.json`), unless it's this one.
    static func userCommand(home: String) -> String? {
        let file = URL(fileURLWithPath: home).appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: file), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let line = object["statusLine"] as? [String: Any], (line["type"] as? String ?? "command") == "command",
              let command = (line["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty,
              !command.contains(argument) else { return nil }
        return command
    }

    /// `command` run by the shell with `input`, its output; nil when it can't start or takes past `patience` (then stopped).
    static func runCommand(_ command: String, input: Data, patience: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        do { try process.run() } catch { return nil }
        // Written and read on threads of their own: neither side's pipe filling blocks the other.
        DispatchQueue.global().async {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }
        var output = Data()
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            output = stdout.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        guard ended.wait(timeout: .now() + patience) == .success else {
            process.terminate()
            return nil
        }
        _ = read.wait(timeout: .now() + 1)
        return String(decoding: output, as: UTF8.self)
    }
}
