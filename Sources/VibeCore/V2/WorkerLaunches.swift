import Foundation

/// The model families a task's worker sessions were launched on, as the session host saw each one when the lead bound
/// a worker's role to it (`LeadVault.Request.bind`): every `--model` on the command the host itself started that
/// session with (never what the request says), or Claude Code's default at that moment (`~/.claude/settings.json`'s
/// "model" in the host's home) for a launch that passed none. Kept in the vault's record of the task
/// (`Team.launchedFamilies`), which only the host writes, by the task the vault's own grant names (a team member's
/// under its member slug), never trimmed and never cleared, not even at retire (the branch may outlive it).
///
/// These only ever ADD to what an audit is kept off under the floor that keeps audits off the workers' model
/// (`excluded`): the workers' model (the floor's worker_model, the user's word, else Claude Code's default) stays
/// excluded as before, with the board's task model and launched model. Nothing here unlocks a model: argv isn't proof
/// of what ran (a decoy bind, Claude Code's own precedence, `/model` mid-session). A name that isn't a known family
/// adds nothing and removes nothing. The lead's own model was never part of the rule and isn't here (the security
/// architecture's open list: a lead that writes a task's code itself, and `--advisor`).
public enum WorkerLaunch {
    /// What the host saw of a session it binds a role to: the command it started it with (nil: a plain shell), and the
    /// folder it started in (its project settings' model and `env` are read there: they only add).
    public struct Seen: Equatable, Sendable {
        public var command: String?
        public var cwd: String?
        public init(command: String?, cwd: String? = nil) {
            self.command = command
            self.cwd = cwd
        }
    }

    static let families = ["mythos", "fable", "opus", "sonnet", "haiku"]

    /// `model`'s family when it names one; nil for an alias (default, best, opusplan), a custom id or anything else.
    public static func family(of model: String?) -> String? {
        guard let name = model?.lowercased() else { return nil }
        return families.first { name.contains($0) }
    }

    /// Each family's current model id, as this build knows it (kept in step with `LeadPrices.table`'s newest): what a
    /// worker under the floor is launched with in place of the family's alias, and what every team session's
    /// `--settings` pins the aliases to (`pins`), so a worktree's settings `env` can't remap one.
    public static let currentIDs: [String: String] = [
        "fable": "claude-fable-5-2", "mythos": "claude-mythos-5-2", "opus": "claude-opus-5-5", "sonnet": "claude-sonnet-5-5",
        "haiku": "claude-haiku-5-5",
    ]

    /// `model` as its full id when it is a family's bare alias (`opus`, `Fable`, `opus[1m]` keeps its `[1m]`); any other
    /// name (an id already, or a name this doesn't know) as it is.
    public static func fullID(_ model: String) -> String {
        let lowered = model.lowercased()
        let bare = lowered.hasSuffix("[1m]") ? String(lowered.dropLast(4)) : lowered
        guard let id = currentIDs[bare] else { return model }
        return id + (bare == lowered ? "" : "[1m]")
    }

    /// The `env` every team session's `--settings` carries: each family's alias pinned to its id
    /// (ANTHROPIC_DEFAULT_<FAMILY>_MODEL), and ANTHROPIC_MODEL to the model the session is launched with (`model`, as
    /// its id; none without one). Whether a project's or a worktree's settings `env` can still win key by key is
    /// unverified (the security architecture's open list).
    public static func pins(model: String?) -> [String: String] {
        var pins = Dictionary(uniqueKeysWithValues: currentIDs.map { ("ANTHROPIC_DEFAULT_\($0.key.uppercased())_MODEL", $0.value) })
        if let model { pins["ANTHROPIC_MODEL"] = fullID(model) }
        return pins
    }

    /// A name that says which one model it is: a family's or its claude-… id (`opusplan` is two, `best` none).
    public static func namesOne(_ model: String) -> Bool { LeadReviewFloor.knownModel(model) && runsOn(model).count == 1 }

    /// The families a model name a launch passed may run on: its own, `best` Opus, `opusplan` Opus and Sonnet (Claude
    /// Code's aliases); none for anything else (`default` is read as no `--model` by the caller).
    static func runsOn(_ model: String) -> [String] {
        switch model.lowercased() {
        case "best": return ["opus"]
        case "opusplan": return ["opus", "sonnet"]
        default: return family(of: model).map { [$0] } ?? []
        }
    }

    /// The most of a settings file read at a bind, and the deepest its JSON may nest.
    static let settingsLimit = 1 << 20
    static let depthLimit = 64

    /// A settings file under `root` (`components`), read the careful way (`Platform.Files.readRegular`: no link below
    /// `root`, a regular file only, opened without waiting, at most `settingsLimit` bytes) and parsed only when its JSON
    /// nests no deeper than `depthLimit`; with why not, when it isn't read (none: no such file).
    public static func settings(in root: String, _ components: [String]) -> (object: [String: Any]?, note: String?) {
        let name = components.joined(separator: "/")
        switch Platform.Files.readRegular(in: root, path: components, limit: settingsLimit) {
        case .absent: return (nil, nil)
        case .refused(let why): return (nil, "\(name) in \(root) not read: \(why)")
        case .data(let data):
            guard nests(data, within: depthLimit) else {
                return (nil, "\(name) in \(root) not read: not UTF-8 JSON (no byte-order mark, no NUL) nesting at most \(depthLimit) deep")
            }
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (nil, nil) }
            return (object, nil)
        }
    }

    /// Whether `data`'s JSON nests at most `limit` deep (brackets outside strings counted), before a parser sees it:
    /// only UTF-8 with no byte-order mark and no NUL (what the parser could read otherwise, UTF-16 or UTF-32, isn't these
    /// bytes), and never closing more than it opened.
    static func nests(_ data: Data, within limit: Int) -> Bool {
        guard !data.starts(with: [0xEF, 0xBB, 0xBF]), !data.contains(0), String(data: data, encoding: .utf8) != nil else { return false }
        var depth = 0, inString = false, escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                continue
            }
            switch byte {
            case 0x22: inString = true
            case 0x5B, 0x7B:
                depth += 1
                if depth > limit { return false }
            case 0x5D, 0x7D:
                depth -= 1
                if depth < 0 { return false }
            default: break
            }
        }
        return true
    }

    /// The model names a session's project settings in `cwd` give Claude Code (their "model", and their `env`'s
    /// ANTHROPIC_MODEL and ANTHROPIC_DEFAULT_*_MODEL): branch content, read the careful way (`settings`) only to add;
    /// with why a file wasn't read.
    static func projectModels(cwd: String?) -> (models: [String], notes: [String]) {
        guard let cwd else { return ([], []) }
        var found: [String] = [], notes: [String] = []
        for file in ["settings.json", "settings.local.json"] {
            let read = settings(in: cwd, [".claude", file])
            if let note = read.note { notes.append(note) }
            guard let object = read.object else { continue }
            if let model = object["model"] as? String { found.append(model) }
            for (key, value) in object["env"] as? [String: Any] ?? [:]
            where key == "ANTHROPIC_MODEL" || (key.hasPrefix("ANTHROPIC_DEFAULT_") && key.hasSuffix("_MODEL")) {
                if let value = value as? String { found.append(value) }
            }
        }
        return (found, notes)
    }

    /// The `--model` (or `--model=`) a launch command passes before its `--` (what follows is the start message: the
    /// brief's words, never options): the last one, as Claude Code's own option parsing takes it; nil when none. The
    /// command split as a shell splits it (`words`).
    public static func launchModel(command: String) -> String? {
        let options = words(command).prefix { $0 != "--" }
        var found: String?
        for (index, word) in options.enumerated() {
            if word == "--model", index + 1 < options.count { found = options[options.startIndex + index + 1] }
            if word.hasPrefix("--model=") { found = String(word.dropFirst("--model=".count)) }
        }
        return found.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `command`'s words as a POSIX shell splits them: single quotes literal, double quotes with `\` escaping `"`, `\`,
    /// `$` and `` ` ``, a bare `\` escaping the next character (`RecentProjects.shellQuote`'s `'\''` among them).
    static func words(_ command: String) -> [String] {
        var words: [String] = []
        var word = "", inWord = false
        var characters = command.makeIterator()
        while let character = characters.next() {
            switch character {
            case "'":
                inWord = true
                while let next = characters.next(), next != "'" { word.append(next) }
            case "\"":
                inWord = true
                while let next = characters.next(), next != "\"" {
                    if next == "\\", let escaped = characters.next() {
                        if !"\"\\$`".contains(escaped) { word.append(next) }
                        word.append(escaped)
                    } else {
                        word.append(next)
                    }
                }
            case "\\":
                inWord = true
                if let escaped = characters.next() { word.append(escaped) }
            case _ where character.isWhitespace:
                if inWord { words.append(word) }
                word = ""
                inWord = false
            default:
                inWord = true
                word.append(character)
            }
        }
        if inWord { words.append(word) }
        return words
    }

    /// The families a launch adds (`seen` nil: the host didn't know the session, none): its `--model`'s (`runsOn`), or
    /// with none (or `default`), Claude Code's default's as `home` holds it now, and with no default set either, Claude's
    /// own, which the floor counts as Opus (`LeadReviewFloor.workersModel`); and whatever its project settings name
    /// (`projectModels`). An unknown name adds nothing.
    /// Every file is read the careful way (`settings`); one that isn't adds nothing and is named in `notes`.
    public static func families(seen: Seen?, home: String) -> (families: [String], notes: [String]) {
        guard let seen else { return ([], []) }
        var notes: [String] = []
        let passed = seen.command.flatMap(launchModel(command:)).flatMap { $0.lowercased() == "default" ? nil : $0 }
        let ran: [String]
        if let passed {
            ran = runsOn(passed)
        } else {
            let home = settings(in: home, [".claude", "settings.json"])
            if let note = home.note { notes.append(note) }
            ran = runsOn(LeadReviewFloor.workersModel(home.object?["model"] as? String))
        }
        let project = projectModels(cwd: seen.cwd)
        return (Array(Set(ran + project.models.flatMap(runsOn))).sorted(), notes + project.notes)
    }

    /// `families`, run off the caller's queue (the host's) and waited for at most `limit`: past it, nothing is added
    /// and that's said (a read held up on a slow file system).
    public static func families(seen: Seen?, home: String, limit: TimeInterval) -> (families: [String], notes: [String]) {
        guard seen != nil else { return ([], []) }
        let done = DispatchSemaphore(value: 0)
        let result = Found()
        DispatchQueue.global(qos: .userInitiated).async {
            result.set(families(seen: seen, home: home))
            done.signal()
        }
        guard done.wait(timeout: .now() + limit) == .success, let found = result.get() else {
            return ([], ["a worker's launch wasn't recorded: reading its settings took more than \(Int(limit)) s"])
        }
        return found
    }

    /// How long a bind waits for its reads.
    public static let bindLimit: TimeInterval = 2

    /// `families`' result, handed between two queues.
    private final class Found: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (families: [String], notes: [String])?
        func set(_ found: (families: [String], notes: [String])) { lock.withLock { value = found } }
        func get() -> (families: [String], notes: [String])? { lock.withLock { value } }
    }

    /// What a task's audit is kept off under the floor, and the line that says so: the workers' model (`floorModel`,
    /// the floor's worker_model, else `projectDefault`, Claude Code's default) and the families the vault recorded for
    /// the task's launches (`launched`, nil: no record).
    public static func excluded(floorModel: String?, projectDefault: String?, launched: [String]?) -> (workers: [String?], text: String) {
        let base = floorModel.map { "workers' model \(shown($0)) by your review floor" }
            ?? "Claude Code's default \(projectDefault.map(shown) ?? "(Claude's own, counted as opus)")"
        let record = launched.flatMap { $0.isEmpty ? nil : $0 }.map { " and launched on \($0.joined(separator: " and ")) by the host's record" }
            ?? ", no launch record"
        return ([floorModel ?? projectDefault] + (launched ?? []), "kept off " + base + record)
    }

    /// A model as the line says it: its family when known.
    static func shown(_ model: String) -> String { family(of: model) ?? model }
}

/// The lead's audit of `task` at `commit` found no model the floor leaves and asked the user (`LeadVault.Request
/// .offerAuditModels`): only an answer to that question, naming that task and commit, records an allowance.
public struct AuditOffer: Codable, Equatable, Sendable {
    public var task: String
    public var commit: String
    public var at: Double
    /// The question as the audit asked it (`questionDigest` of its text and options): a reworded or re-optioned one
    /// isn't the audit's.
    public var digest: String?

    /// The digest of a question's text and options, as the audit asked them.
    public static func questionDigest(text: String, options: [String]) -> String {
        LeadVault.hash(([text] + options).joined(separator: "\u{0}"))
    }
}

/// The user allowed `model` to audit `task` at `commit` (their answer to an `AuditOffer`'s question): used by the one
/// audit that starts while the task's branch is at that commit, then gone.
public struct AuditAllowance: Codable, Equatable, Sendable {
    public var task: String
    public var commit: String
    public var model: String
    public var at: Double
}

extension LeadVault {
    /// The offer behind a question, nil for a question no audit asked (or a vault that can't be asked).
    public func auditOffer(root: String, question: String) -> AuditOffer? {
        guard case .offer(let offer)? = try? call(.auditOffer(root: root, question: question)) else { return nil }
        return offer
    }

    /// The lead's audit of `task` at `commit` asked `question` (its id): the user's answer to it may then allow a model.
    public func offerAuditModels(root: String, task: String, commit: String, question: String, digest: String) throws {
        _ = try call(.offerAuditModels(root: root, task: task, commit: commit, question: question, digest: digest))
    }

    /// The audit that used `task`'s allowance at `commit` started: the allowance is gone.
    public func consumeAuditAllowance(root: String, task: String, commit: String) {
        _ = try? call(.consumeAuditAllowance(root: root, task: task, commit: commit))
    }

    /// The allowance the user gave for `task`, if any.
    public func auditAllowance(root: String, task: String) -> AuditAllowance? {
        guard case .allowance(let allowance)? = try? call(.auditAllowance(root: root, task: task)) else { return nil }
        return allowance
    }

    /// The families the host recorded for `task`'s worker launches and its team members' (`WorkerLaunch`); nil: none
    /// kept, or the vault couldn't be asked (an older host).
    public func launchedFamilies(root: String, task: String) -> [String]? {
        guard case .families(let families)? = try? call(.launchedFamilies(root: root, task: task)) else { return nil }
        return families
    }
}
