import Foundation

/// How close the Codex account is to its usage limits, as Codex last wrote them, so a task the lead marks `agent: auto`
/// can go to Codex when Claude's quota runs ahead of pace (the user, 2026-11-02: "if there's not a lot of quota I should
/// be leveraging Codex much more"; see `UsageRouting`).
///
/// Codex (0.160) writes its account's limits into each session's rollout (`$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`):
/// a `token_count` event's `payload.rate_limits` after each reply, e.g. `{"limit_id":"codex","primary":{"used_percent":59.0,
/// "window_minutes":10080,"resets_at":1793774133},"secondary":null,"credits":{"has_credits":true,"unlimited":false,
/// "balance":"36762.87"},"rate_limit_reached_type":null}`. Seen on this Mac (2026-11-02): a weekly primary alone, or a
/// 5-hour primary with a weekly secondary; credits null; and other limits beside the account's (`codex_bengalfox`, one
/// model's; `premium`, with no windows), which say nothing of it and are passed over.
///
/// Read only, never written. Failing closed: what isn't known (no rollout, an unreadable or malformed reading, one whose
/// windows have all reset) is unknown, and unknown is never room (`UsageRouting.codexRoom`).
public struct CodexUsage: Equatable, Sendable {
    /// One of the account's limit windows as last read.
    public struct Window: Equatable, Sendable {
        /// How much of it is used, 0–100.
        public var usedPercent: Double
        /// How long it is, when said (300: the 5-hour window; 10080: the weekly one).
        public var windowMinutes: Double?
        /// When it resets (epoch seconds), when said.
        public var resetsAt: Double?

        public init(usedPercent: Double, windowMinutes: Double? = nil, resetsAt: Double? = nil) {
            self.usedPercent = usedPercent
            self.windowMinutes = windowMinutes
            self.resetsAt = resetsAt
        }

        /// "weekly", "5-hour", "90-minute"; "" when its length isn't said.
        public var name: String {
            guard let windowMinutes else { return "" }
            switch windowMinutes {
            case 10080: return "weekly"
            case 300: return "5-hour"
            default: return windowMinutes.truncatingRemainder(dividingBy: 1440) == 0 ? "\(Int(windowMinutes / 1440))-day"
                : windowMinutes.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(windowMinutes / 60))-hour" : "\(Int(windowMinutes))-minute"
            }
        }

        /// Its pace at `now` (see `UsagePace`).
        public func pace(at now: Double) -> UsagePace {
            UsagePace(used: usedPercent, elapsed: UsagePace.elapsed(resetsAt: resetsAt, windowMinutes: windowMinutes, now: now))
        }

        /// It still holds at `now`: its reset time is said and hasn't come. One with no reset time isn't known to.
        func current(at now: Double) -> Bool { resetsAt.map { $0 > now } ?? false }
    }

    public var windows: [Window]
    /// `credits.has_credits`, `credits.unlimited` and `credits.balance`, when said.
    public var hasCredits: Bool?
    public var unlimited: Bool?
    public var balance: Double?
    /// `rate_limit_reached_type`: Codex says a limit is reached (no room, whatever the windows say).
    public var reached: String?
    /// When it was read (the event's timestamp, else the file's modification time; epoch seconds).
    public var at: Double
    /// The rollout it was read from.
    public var file: String

    public init(windows: [Window], hasCredits: Bool? = nil, unlimited: Bool? = nil, balance: Double? = nil, reached: String? = nil,
                at: Double, file: String = "") {
        self.windows = windows
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
        self.reached = reached
        self.at = at
        self.file = file
    }

    /// Credits can be spent past a window's limit: unlimited, or credits said to be there (a balance said, above 0).
    public var creditsAvailable: Bool { unlimited == true || (hasCredits == true && (balance.map { $0 > 0 } ?? true)) }

    /// Its windows still holding at `now`, in Codex's order (primary, then secondary).
    public func current(now: Date = Date()) -> [Window] {
        windows.filter { $0.current(at: now.timeIntervalSince1970) }
    }

    /// What one rollout line says of the account's limits: `.known` for a `token_count` event with the account's
    /// `rate_limits` (limit_id `codex`, or none); `.unknown` for one whose account limits can't be read (no window,
    /// a window without a number); nil for a line that says nothing of them (another event, another limit's, null).
    static func parse(line: Substring, file: String, fallbackAt: Double) -> CodexReading? {
        guard line.contains("\"rate_limits\""), let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let payload = object["payload"] as? [String: Any], payload["type"] as? String == "token_count",
              let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        if let id = limits["limit_id"], !(id is NSNull), id as? String != "codex" { return nil }
        let at = (object["timestamp"] as? String).flatMap(Self.timestamp) ?? fallbackAt
        var windows: [Window] = []
        for key in ["primary", "secondary"] {
            guard let given = limits[key], !(given is NSNull) else { continue }
            guard let window = given as? [String: Any], let used = Self.number(window["used_percent"]), used.isFinite, used >= 0 else {
                return .unknown("its last reading's \(key) window can't be read")
            }
            let minutes = Self.number(window["window_minutes"]).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            let resets = Self.number(window["resets_at"]).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            windows.append(Window(usedPercent: used, windowMinutes: minutes, resetsAt: resets))
        }
        guard !windows.isEmpty else { return .unknown("its last reading has no limit window") }
        let credits = limits["credits"] as? [String: Any]
        let balance = credits?["balance"].flatMap { value -> Double? in
            if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
            return number(value)
        }
        let reached = (limits["rate_limit_reached_type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return .known(CodexUsage(windows: windows, hasCredits: credits?["has_credits"] as? Bool, unlimited: credits?["unlimited"] as? Bool,
                                 balance: balance, reached: reached, at: at, file: file))
    }

    /// The last reading of the account's limits in the last `tailBytes` of `file`: only its end is read. Nil when
    /// none is there (a session that hasn't replied yet).
    static func read(file: String, tailBytes: Int = CodexUsageReader.tailBytes) -> CodexReading? {
        guard let handle = FileHandle(forReadingAtPath: file) else { return .unknown("its newest session file can't be read") }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return .unknown("its newest session file can't be read") }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else {
            return .unknown("its newest session file can't be read")
        }
        let modified = ((try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        // Cut mid-line: the first is a line's end only.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() {
            if let reading = parse(line: line, file: file, fallbackAt: modified) { return reading }
        }
        return nil
    }

    static func number(_ value: Any?) -> Double? {
        // A JSON true or false is an NSNumber too.
        guard let number = value as? NSNumber else { return nil }
        return CFGetTypeID(number) == CFBooleanGetTypeID() ? nil : number.doubleValue
    }

    static func timestamp(_ text: String) -> Double? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date.timeIntervalSince1970 }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)?.timeIntervalSince1970
    }

    /// For the lead's status: "Codex usage (its newest session file, read Nov 2, 07:33): weekly 65% used (3 points
    /// behind pace), resets Nov 4, 18:00; credits available (36762.87)".
    public func statusText(now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince1970
        let windows = current(now: now)
        let shown = windows.isEmpty ? "every window of its last reading has reset, so it's not known"
            : windows.map { window in
                let name = window.name.isEmpty ? "a limit" : "the \(window.name) limit"
                return "\(name): \(Int(window.usedPercent.rounded()))% used (\(window.pace(at: seconds).paceText)), "
                    + (window.resetsAt.map { "resets \(UsageLimit.resetText($0))" } ?? "reset time not known")
            }.joined(separator: "; ")
        let credits = unlimited == true ? "; credits unlimited" : creditsAvailable ? "; credits available" + (balance.map { " (\(Self.amount($0)))" } ?? "")
            : hasCredits == false ? "; no credits" : ""
        let reachedText = reached.map { "; Codex says a limit is reached (\($0))" } ?? ""
        return "Codex usage (best effort: its newest session file, read \(UsageLimit.resetText(at))): \(shown)\(credits)\(reachedText)."
    }

    static func amount(_ value: Double) -> String { String(format: "%.2f", value) }
}

/// What's known of the Codex account's usage: a reading, or why there's none (unknown, never room).
public enum CodexReading: Equatable, Sendable {
    case known(CodexUsage)
    case unknown(String)

    public var usage: CodexUsage? {
        if case .known(let usage) = self { return usage }
        return nil
    }

    /// For the lead's status.
    public func statusText(now: Date = Date()) -> String {
        switch self {
        case .known(let usage): return usage.statusText(now: now)
        case .unknown(let why): return "Codex usage: not known (\(why)), so auto tasks run on Claude."
        }
    }
}

/// Reads the Codex account's usage from the newest rollout under `$CODEX_HOME/sessions` (default `~/.codex`), only
/// its tail, and keeps what it read: the folders are looked at again after `ttl`, and a file is read again only once
/// it has changed. Read only.
public final class CodexUsageReader: @unchecked Sendable {
    /// Codex's home: `$CODEX_HOME`, else `~/.codex`.
    public let home: URL
    /// How long a look at the folders is kept.
    public var ttl: TimeInterval
    /// How much of a rollout's end is read.
    static let tailBytes = 256 * 1024
    /// How many of the newest rollouts are tried for a reading (a session just started has none yet).
    static let files = 4
    /// How many of the newest day folders are looked in (a session started yesterday may be the one written last).
    static let days = 3

    private let lock = NSLock()
    private var looked: (at: Date, reading: CodexReading)?
    private var parsed: (file: String, size: UInt64, modified: Double, reading: CodexReading)?

    public init(home: URL = CodexUsageReader.standardHome, ttl: TimeInterval = 30) {
        self.home = home
        self.ttl = ttl
    }

    public static var standardHome: URL {
        if let given = ProcessInfo.processInfo.environment["CODEX_HOME"], given.hasPrefix("/") { return URL(fileURLWithPath: given) }
        return URL(fileURLWithPath: VibePaths.home).appendingPathComponent(".codex")
    }

    /// The account's usage as Codex last wrote it.
    public func read(now: Date = Date()) -> CodexReading {
        lock.lock()
        defer { lock.unlock() }
        if let looked, now.timeIntervalSince(looked.at) < ttl, now >= looked.at { return looked.reading }
        let reading = look()
        looked = (now, reading)
        return reading
    }

    private func look() -> CodexReading {
        let sessions = home.appendingPathComponent("sessions").path
        let candidates = Self.newest(in: sessions)
        guard !candidates.isEmpty else { return .unknown("no Codex session file under \(sessions)") }
        for candidate in candidates.prefix(Self.files) {
            if let parsed, parsed.file == candidate.path, parsed.size == candidate.size, parsed.modified == candidate.modified {
                return parsed.reading
            }
            guard let reading = CodexUsage.read(file: candidate.path) else { continue }
            parsed = (candidate.path, candidate.size, candidate.modified, reading)
            return reading
        }
        return .unknown("Codex's newest session files say nothing of its limits yet")
    }

    /// The rollouts in the newest `days` day folders (`YYYY/MM/DD`), the last written first.
    static func newest(in sessions: String) -> [(path: String, size: UInt64, modified: Double)] {
        let manager = FileManager.default
        func folders(_ path: String) -> [String] {
            ((try? manager.contentsOfDirectory(atPath: path)) ?? []).filter { $0.allSatisfy(\.isNumber) }.sorted(by: >).map { path + "/" + $0 }
        }
        var dayFolders: [String] = []
        outer: for year in folders(sessions) {
            for month in folders(year) {
                for day in folders(month) {
                    dayFolders.append(day)
                    if dayFolders.count >= days { break outer }
                }
            }
        }
        var found: [(path: String, size: UInt64, modified: Double)] = []
        for day in dayFolders {
            for name in (try? manager.contentsOfDirectory(atPath: day)) ?? [] where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                let path = day + "/" + name
                guard let attributes = try? manager.attributesOfItem(atPath: path), attributes[.type] as? FileAttributeType == .typeRegular else { continue }
                let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                found.append((path, (attributes[.size] as? NSNumber)?.uint64Value ?? 0, modified))
            }
        }
        return found.sorted { ($0.modified, $0.path) > ($1.modified, $1.path) }
    }
}

/// A limit's use against the time gone in its window: 64% used with 52% of the week gone is 12 points ahead of pace.
public struct UsagePace: Equatable, Sendable {
    /// How much of the limit is used, 0–100.
    public var used: Double
    /// How much of its window has gone, 0–100; nil when its length or reset isn't known.
    public var elapsed: Double?

    public init(used: Double, elapsed: Double?) {
        self.used = used
        self.elapsed = elapsed
    }

    /// Points ahead of pace (negative: behind); nil when the window's time isn't known.
    public var ahead: Double? { elapsed.map { used - $0 } }

    /// The share of a `windowMinutes` window that has gone at `now`, from when it resets; nil when either isn't said,
    /// or the reset is further off than a window (a reading that doesn't add up).
    public static func elapsed(resetsAt: Double?, windowMinutes: Double?, now: Double) -> Double? {
        guard let resetsAt, let windowMinutes, resetsAt.isFinite, windowMinutes.isFinite, windowMinutes > 0 else { return nil }
        let window = windowMinutes * 60
        let left = resetsAt - now
        guard left <= window + 60 else { return nil }
        return min(100, max(0, (window - left) / window * 100))
    }

    /// "12 points ahead of pace", "3 points behind pace", "on pace", "pace not known".
    public var paceText: String {
        guard let ahead else { return "pace not known" }
        let points = Int(abs(ahead).rounded())
        if points == 0 { return "on pace" }
        return "\(points) point\(points == 1 ? "" : "s") \(ahead > 0 ? "ahead of" : "behind") pace"
    }
}

/// Which agent a task marked `agent: auto` starts on: Codex when Claude's usage is tight and Codex has room, Claude
/// otherwise (unknown usage on either side included: Claude). Only workers: leads, planning, reviews and audits stay on
/// Claude whatever the quota. The thresholds are here, and only here.
public enum UsageRouting {
    /// Claude is tight at this share (in percent) of any of its current limits on the task's model...
    public static let claudeTightPercent = 70.0
    /// ...or when a weekly limit is more than this many points ahead of pace.
    public static let claudeWeeklyAheadPoints = 10.0
    /// Codex has room while each of its known limits is under this share...
    public static let codexRoomPercent = 85.0
    /// ...or under this one with credits available.
    public static let codexRoomWithCreditsPercent = 100.0

    /// Where an auto task's worker goes, and why in a few words ("Codex: Claude weekly 64%, 12 points ahead of pace;
    /// Codex 40%").
    public struct Route: Equatable, Sendable {
        public var agent: LeadTask.WorkerAgent
        public var why: String
    }

    /// The length of a Claude limit's window, in minutes, from its name; nil for one that has none (spend_limit) or
    /// isn't known.
    static func claudeWindowMinutes(_ name: String) -> Double? {
        if name == "five_hour" { return 300 }
        if name.hasPrefix("seven_day") { return 10080 }
        return nil
    }

    /// "weekly", "5-hour", "weekly Opus", "fable (seven_day_overage_included)".
    static func claudeName(_ limit: AccountUsage.Limit) -> String {
        let base: String
        switch limit.name {
        case "seven_day": base = "weekly"
        case "five_hour": base = "5-hour"
        case "seven_day_opus": base = "weekly Opus"
        case "seven_day_sonnet": base = "weekly Sonnet"
        default: base = limit.name.replacingOccurrences(of: "_", with: " ")
        }
        return base + (limit.model.map { " (\($0))" } ?? "")
    }

    /// A Claude limit's pace at `now`.
    public static func pace(_ limit: AccountUsage.Limit, now: Double) -> UsagePace {
        UsagePace(used: limit.usedPercent, elapsed: UsagePace.elapsed(resetsAt: limit.resetsAt, windowMinutes: claudeWindowMinutes(limit.name), now: now))
    }

    /// "weekly 64%, 12 points ahead of pace", "weekly reached".
    static func claudeText(_ limit: AccountUsage.Limit, now: Double) -> String {
        if limit.reached { return "\(claudeName(limit)) reached" }
        let pace = pace(limit, now: now)
        return "\(claudeName(limit)) \(Int(limit.usedPercent.rounded()))%" + (pace.ahead == nil ? "" : ", " + pace.paceText)
    }

    /// Whether Claude's usage is tight for a worker on `model` (nil: Claude's default): one of its current limits on
    /// that model (or on every model) at `claudeTightPercent` or more, or a weekly one more than
    /// `claudeWeeklyAheadPoints` ahead of pace; with the limit that says so (or the most used one), in words.
    public static func claude(_ usage: AccountUsage, model: String?, now: Date = Date()) -> (tight: Bool, text: String) {
        let seconds = now.timeIntervalSince1970
        let family = AccountUsage.family(model)
        let limits = usage.current(now: now).limits.filter { $0.model == nil || $0.model == family }
        guard !limits.isEmpty else { return (false, "Claude's usage not known") }
        if let full = limits.first(where: { $0.usedPercent >= claudeTightPercent }) { return (true, "Claude " + claudeText(full, now: seconds)) }
        let ahead = limits.filter { $0.name.hasPrefix("seven_day") }
            .compactMap { limit in pace(limit, now: seconds).ahead.map { (limit, $0) } }
            .filter { $0.1 > claudeWeeklyAheadPoints }.max { $0.1 < $1.1 }
        if let ahead { return (true, "Claude " + claudeText(ahead.0, now: seconds)) }
        // Not tight: the weekly one when known (it decides most), else the most used.
        let shown = limits.first { $0.name == "seven_day" } ?? limits[0]
        return (false, "Claude " + claudeText(shown, now: seconds))
    }

    /// Whether Codex has room: a reading whose current limits are each under `codexRoomPercent` (under
    /// `codexRoomWithCreditsPercent` with credits available), and no limit Codex says is reached; with it in words.
    /// Unknown is no room.
    public static func codex(_ reading: CodexReading, now: Date = Date()) -> (room: Bool, text: String) {
        // Why it isn't known is status's Codex line's to say (`CodexReading.statusText`).
        guard let usage = reading.usage else { return (false, "Codex usage not known") }
        // A window with no reset time can't be told current or not: unknown, so no room (whatever the others say).
        guard usage.windows.allSatisfy({ $0.resetsAt != nil }) else { return (false, "Codex usage not known (a limit's reset time isn't said)") }
        let windows = usage.current(now: now)
        guard !windows.isEmpty else { return (false, "Codex usage not known (its last reading's windows have reset)") }
        let percents = windows.count == 1 ? "\(Int(windows[0].usedPercent.rounded()))%"
            : windows.map { "\($0.name.isEmpty ? "a limit" : $0.name) \(Int($0.usedPercent.rounded()))%" }.joined(separator: ", ")
        if let reached = usage.reached { return (false, "Codex \(percents), at a limit (\(reached))") }
        let credits = usage.creditsAvailable
        let ceiling = credits ? codexRoomWithCreditsPercent : codexRoomPercent
        let room = windows.allSatisfy { $0.usedPercent < ceiling }
        let past = windows.contains { $0.usedPercent >= codexRoomPercent }
        return (room, "Codex \(percents)" + (past && credits ? ", with credits" : "") + (room ? "" : ", no room"))
    }

    /// Where an auto task's worker on `model` (Claude's; nil: its default) starts: Codex when Claude is tight and
    /// Codex has room, else Claude. `codexWorkers`: Codex workers can be started (see `LeadLaunch.codexWorkersUsable`).
    public static func route(claude usage: AccountUsage, codex reading: CodexReading, model: String?, codexWorkers: Bool = true,
                             now: Date = Date()) -> Route {
        guard codexWorkers else { return Route(agent: .claude, why: "Claude: Codex workers are switched off") }
        let claude = claude(usage, model: model, now: now)
        let codex = codex(reading, now: now)
        let agent: LeadTask.WorkerAgent = claude.tight && codex.room ? .codex : .claude
        return Route(agent: agent, why: "\(agent.name): \(claude.text)" + (claude.tight ? "" : ", not tight") + "; \(codex.text)")
    }
}
