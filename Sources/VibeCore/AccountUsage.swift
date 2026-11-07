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
    /// `ignoring`: Settings' "Ignore usage limits" is on (`MacLimits.ignoreUsageLimits`): only a limit Claude refused a
    /// request at holds (a session started into it would stop at once), whatever share of the others is used.
    public func hold(model: String?, now: Date = Date(), threshold: Double = AccountUsage.threshold, ignoring: Bool = false) -> Limit? {
        let family = Self.family(model)
        return current(now: now).limits.first { limit in
            (ignoring ? limit.reached : limit.usedPercent >= threshold) && (limit.model == nil || limit.model == family)
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

    /// For the lead's status: each limit known, or nil when none is. `ignored`: Settings' "Ignore usage limits" is on.
    public func statusText(now: Date = Date(), ignored: Bool = false) -> String? {
        let known = current(now: now).limits
        guard !known.isEmpty else { return nil }
        let seconds = now.timeIntervalSince1970
        return "Account usage" + (ignored ? " " + Self.ignoredMark : "") + " (best effort: what sessions' status lines and refusals said): " + known.map { limit in
            let pace = UsageRouting.pace(limit, now: seconds)
            return limit.text + (limit.reached || pace.ahead == nil ? "" : ", " + pace.paceText)
        }.joined(separator: "; ")
            + (ignored ? ". The user set Ignore usage limits in Settings › Project lead: start_worker, audit and auto_advance start at any share of a limit, "
                + "Boost isn't held off for usage, and agent: auto stays on Claude; only a limit Claude refused a request at still holds back its model."
                : ". At \(Int(Self.threshold))% of a limit, start_worker and audit stop starting sessions on the models it holds back (override_usage: true overrides).")
    }

    /// What usage shown while Settings' "Ignore usage limits" is on is marked with.
    public static let ignoredMark = "(limits ignored)"
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
/// account's usage windows (`rate_limits`); it runs your own status line (the `statusLine` command your Claude settings
/// give that session, see `userCommand`) with the same input and prints its output byte for byte, then keeps the usage
/// (`AccountUsageStore`), so the session's status line reads as yours would. Your own sessions keep theirs untouched.
/// With no status line of yours, it prints the usage.
public enum UsageStatusLine {
    public static let argument = "--status-line"
    /// Added for a verifier, started with `--setting-sources user`: only your user settings' status line is run, never
    /// one in the branch's project settings (a worker wrote them).
    public static let userOnlyArgument = "--user-settings-only"
    /// How long your own status line may take before it's stopped (Claude Code gives up on a slow one too).
    public static let patience: TimeInterval = 5
    /// The signals that stop a status line, as Claude Code stops one it gives up on (see `runCommand`).
    public static let stopSignals: [Int32] = [SIGTERM, SIGHUP, SIGINT]

    /// The status line's settings entry for a role's `--settings`: this tool server run with `argument`.
    public static func settings(server: String, userOnly: Bool = false) -> [String: Any] {
        ["type": "command", "command": RecentProjects.shellQuote(server) + " " + argument + (userOnly ? " " + userOnlyArgument : "")]
    }

    /// Runs a status line command: (command, input, patience) → what it printed.
    public typealias Runner = (String, Data, TimeInterval) -> Data

    /// Shows (`show`) your own status line's output first, byte for byte, so nothing of ours that fails afterwards
    /// keeps it from showing; then keeps the usage `input` carries. With no status line of yours, shows the usage in a
    /// few words, marked `AccountUsage.ignoredMark` while Settings' "Ignore usage limits" is on (`ignored`: nil reads
    /// mac-limits.json). Never fails: input that isn't JSON keeps nothing (your status line still runs on it).
    public static func run(input: Data, userOnly: Bool = false, store: AccountUsageStore = AccountUsageStore(), home: String = VibePaths.home,
                           now: Date = Date(), patience: TimeInterval = UsageStatusLine.patience, runner: Runner = runCommand,
                           contextStore: LeadContextStore? = nil, ignored: Bool? = nil,
                           show: (Data) -> Void) {
        let object = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
        let command = userCommand(home: home, project: userOnly ? nil : projectFolder(object))
        if let command { show(runner(command, input, patience)) }
        let limits = object.map { AccountUsage.fromStatusLine($0, now: now) } ?? []
        store.record(limits, now: now)
        if let object { (contextStore ?? LeadContextStore(home: home)).record(object, now: now) }
        guard command == nil else { return }
        var text = limits.map { limit in
            let name = limit.name == "seven_day" ? "weekly" : limit.name == "five_hour" ? "5h" : limit.name.replacingOccurrences(of: "_", with: " ")
            return "\(name) \(Int(limit.usedPercent.rounded()))%"
        }.joined(separator: " · ")
        if !text.isEmpty, ignored ?? MacLimits.load().ignoreUsageLimits { text += " " + AccountUsage.ignoredMark }
        show(Data(text.utf8))
    }

    /// The session's project folder, whose `.claude` settings Claude Code layers over yours: the input's
    /// `workspace.project_dir`, else its `cwd`, else this process's folder (Claude Code runs it in the session's).
    static func projectFolder(_ input: [String: Any]?) -> String {
        let workspace = input?["workspace"] as? [String: Any]
        for candidate in [workspace?["project_dir"], input?["cwd"]] {
            if let path = candidate as? String, path.hasPrefix("/") { return path }
        }
        return FileManager.default.currentDirectoryPath
    }

    /// Your status line command as Claude Code layers its settings files, the first that sets `statusLine` deciding:
    /// the project's `.claude/settings.local.json`, its `.claude/settings.json` (nil `project`: neither), then
    /// `~/.claude/settings.local.json` and `~/.claude/settings.json`. Nil when the deciding one isn't a command, or is
    /// this one (it would run itself), or none sets one. A file that can't be read or parsed is passed over.
    static func userCommand(home: String, project: String?) -> String? {
        var files: [String] = []
        if let project { files += [project + "/.claude/settings.local.json", project + "/.claude/settings.json"] }
        files += [home + "/.claude/settings.local.json", home + "/.claude/settings.json"]
        var seen = Set<String>()
        for file in files {
            // The project folder may be the home: its files once.
            let path = URL(fileURLWithPath: file).standardizedFileURL.path
            guard seen.insert(path).inserted, let data = FileManager.default.contents(atPath: path),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let entry = object["statusLine"] else { continue }
            guard let line = entry as? [String: Any], (line["type"] as? String ?? "command") == "command",
                  let command = (line["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty,
                  !command.contains(argument) else { return nil }
            return command
        }
        return nil
    }

    /// `command` run by `/bin/sh -c` with `input` on its stdin; what it printed on stdout (stderr goes nowhere). It runs
    /// on this thread alone (a kqueue on its pipes and its exit: no other thread or queue, so a busy process can't
    /// starve it): the input is written as the pipe takes it and never after the command has exited or closed its end
    /// (the pipe can't raise SIGPIPE either: `F_SETNOSIGPIPE`); its output is read until it ends. Past `patience` the
    /// command is killed and what it printed so far is returned; so it is when one of `stopSignals` comes to this
    /// process. It starts in a process group of its own, with SIGPIPE and `stopSignals` at their defaults, an empty
    /// signal mask and no descriptor of this process but its stdin, stdout and stderr. Empty when it couldn't be started.
    public static func runCommand(_ command: String, input: Data, patience: TimeInterval) -> Data {
        var toChild: [Int32] = [-1, -1], fromChild: [Int32] = [-1, -1]
        guard pipe(&toChild) == 0 else { return Data() }
        guard pipe(&fromChild) == 0 else {
            toChild.forEach { close($0) }
            return Data()
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, toChild[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, fromChild[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t(), mask = sigset_t()
        sigemptyset(&defaults)
        for signal in Self.stopSignals + [SIGPIPE] { sigaddset(&defaults, signal) }
        sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &mask)
        // A process group of its own: stopping it stops the whole of it (a pipeline's every program).
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP))
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(command), nil]
        defer { argv.forEach { free($0) } }
        let queue = kqueue()
        func watch(_ ident: Int32, _ filter: Int32, fflags: UInt32 = 0, flags: Int32 = EV_ADD) -> Bool {
            var change = kevent(ident: UInt(ident), filter: Int16(filter), flags: UInt16(flags), fflags: fflags, data: 0, udata: nil)
            return kevent(queue, &change, 1, nil, 0, nil) == 0
        }
        // Claude Code stopping this status line (TERM, then KILL about 2 s later): the command is stopped with it, never
        // left running. Watched from before it starts, and heard even while ignored (`--status-line` ignores them).
        for signal in Self.stopSignals { _ = watch(signal, EVFILT_SIGNAL) }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, environ)
        close(toChild[0])
        close(fromChild[1])
        var writer: Int32 = toChild[1]
        let reader = fromChild[0]
        guard spawned == 0 else {
            close(writer)
            close(reader)
            if queue >= 0 { close(queue) }
            return Data()
        }
        _ = fcntl(writer, F_SETNOSIGPIPE, 1)
        for fd in [writer, reader] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        func stopWriting() {
            guard writer >= 0 else { return }
            close(writer) // Its kevent goes with it.
            writer = -1
        }
        var output = Data(), pending = input[...]
        // A command that has already exited (a zombie) can't be watched: it has exited.
        var exited = queue < 0 || !watch(pid, EVFILT_PROC, fflags: UInt32(NOTE_EXIT))
        var ended = queue < 0 || !watch(reader, EVFILT_READ)
        if pending.isEmpty || exited || queue < 0 || !watch(writer, EVFILT_WRITE) { stopWriting() }
        var stopped = false
        let deadline = Date().addingTimeInterval(patience)
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while !(exited && ended), !stopped {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { break }
            var wait = timespec(tv_sec: Int(left), tv_nsec: Int((left - left.rounded(.down)) * 1e9))
            var events = Array(repeating: kevent(), count: 4)
            let count = kevent(queue, nil, 0, &events, Int32(events.count), &wait)
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            let fired = events.prefix(Int(count))
            if fired.contains(where: { Int32($0.filter) == EVFILT_SIGNAL }) { stopped = true }
            // Its exit first: nothing is written after it.
            if fired.contains(where: { Int32($0.filter) == EVFILT_PROC }) {
                exited = true
                stopWriting()
            }
            for event in fired where Int32(event.filter) == EVFILT_READ {
                while true {
                    let read = Darwin.read(reader, &chunk, chunk.count)
                    if read > 0 { output.append(contentsOf: chunk[0..<read]); continue }
                    if read < 0 && errno == EINTR { continue }
                    if read == 0 || errno != EAGAIN {
                        ended = true
                        _ = watch(reader, EVFILT_READ, flags: EV_DELETE)
                    }
                    break
                }
            }
            for event in fired where Int32(event.filter) == EVFILT_WRITE && writer >= 0 {
                // Its reader gone (EV_EOF): the command closed its stdin or exited.
                if event.flags & UInt16(EV_EOF) != 0 { stopWriting(); continue }
                while !pending.isEmpty {
                    let wrote = pending.withUnsafeBytes { Darwin.write(writer, $0.baseAddress, $0.count) }
                    if wrote > 0 { pending = pending.dropFirst(wrote); continue }
                    if wrote < 0 && errno == EINTR { continue }
                    if wrote < 0 && errno == EAGAIN { break }
                    pending = pending.prefix(0) // EPIPE, or anything else: the rest isn't wanted.
                }
                if pending.isEmpty { stopWriting() }
            }
        }
        stopWriting()
        close(reader)
        if queue >= 0 { close(queue) }
        if !exited {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        return output
    }
}
