import Foundation

/// When to remind the user to run Claude Code's `/doctor prompt-audit` in a project VibeSwitcher manages: its audit of
/// the project's CLAUDE.md / AGENTS.md, .claude rules, skills, commands and agents for prompting a newer model makes
/// obsolete. It's relative to the model, so there are two triggers: the interval (14 days by default) since the
/// project's last run, and the model its sessions answer on differing from the one the last run was on.
///
/// A run is found by plain parsing of the project's Claude Code transcripts (`~/.claude/projects/<slug>/*.jsonl`): a
/// user turn holding `<command-name>/doctor</command-name>` with `<command-args>prompt-audit</command-args>`. A run
/// the user starts on their own resets the clock; nothing here types into a session (Run now on the card is the
/// user's own click, sent by the app as their message).
///
/// What's kept per project (`Book`, `~/.vibeswitcher/prompt-audit.json`): when it was first seen (a project with no
/// recorded run gets its first card one interval after that, never at once: no burst of cards on install), its last
/// run and the model it was on, a snooze, whether it's turned off, and how far each transcript was read.
public enum PromptAudit {
    /// What Run now sends into the project's lead session, as the user's own message.
    public static let command = "/doctor prompt-audit"
    public static let defaultIntervalDays = 14
    public static let intervalRange = 1...90
    /// Remind me in a week.
    public static let snoozeDays = 7
    static let day: TimeInterval = 86_400

    /// Settings › Project lead: on/off and the interval, per Mac (UserDefaults).
    public static let enabledKey = "promptAuditReminders"
    public static let intervalKey = "promptAuditDays"

    public static func isOn(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: enabledKey) as? Bool ?? true }

    public static func intervalDays(_ defaults: UserDefaults) -> Int {
        let days = defaults.integer(forKey: intervalKey)
        return days == 0 ? defaultIntervalDays : min(max(days, intervalRange.lowerBound), intervalRange.upperBound)
    }

    /// One project's record.
    public struct Project: Codable, Equatable, Sendable {
        /// When VibeSwitcher first saw the project (seconds since 1970).
        public var firstSeen: Double
        /// The last run known: found in its transcripts or sent by Run now.
        public var lastRun: Double?
        /// The model the reminder compares against: the last run's, or (before any run since first seen) the one its
        /// sessions answered on when first seen. Nil: not known yet.
        public var model: String?
        /// Remind me in a week: no card before this.
        public var snoozedUntil: Double?
        /// Not for this project.
        public var off: Bool
        /// Each transcript's bytes read so far (by file name): read on from there next time.
        public var read: [String: UInt64]
        /// The newest model its sessions answered on, and when (seconds since 1970).
        public var latestModel: String?
        public var latestModelAt: Double?

        public init(firstSeen: Date) {
            self.firstSeen = firstSeen.timeIntervalSince1970
            off = false
            read = [:]
        }
    }

    /// Why a card shows.
    public enum Due: Equatable, Sendable {
        /// The interval passed since `since` (the last run, or when VibeSwitcher first saw the project).
        case interval(since: Date, ranBefore: Bool)
        /// Its sessions answer on `to`; the last run (or first sight) was on `from`.
        case modelChanged(from: String, to: String)
    }

    /// "claude-opus-5-5[1m]", "claude-opus-5-5-20261101" and "Claude-Opus-5-5" are one model; "<synthetic>" none.
    public static func normalized(_ model: String?) -> String? {
        guard var name = model?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty, !name.hasPrefix("<") else { return nil }
        if let bracket = name.firstIndex(of: "[") { name = String(name[..<bracket]) }
        if let match = name.range(of: #"-\d{8}$"#, options: .regularExpression) { name.removeSubrange(match) }
        return name.isEmpty ? nil : name
    }

    /// Whether `project` gets a card at `now`, and why. Off, snoozed or turned off: none. A model change shows at once;
    /// the interval counts from the last run, never from before VibeSwitcher first saw the project.
    public static func due(_ project: Project, now: Date, intervalDays: Int = defaultIntervalDays) -> Due? {
        guard !project.off else { return nil }
        if let until = project.snoozedUntil, now.timeIntervalSince1970 < until { return nil }
        if let was = normalized(project.model), let now = normalized(project.latestModel), was != now {
            return .modelChanged(from: was, to: now)
        }
        let since = max(project.lastRun ?? project.firstSeen, project.firstSeen)
        guard now.timeIntervalSince1970 >= since + Double(intervalDays) * day else { return nil }
        return .interval(since: Date(timeIntervalSince1970: since), ranBefore: project.lastRun != nil)
    }

    /// What the card says it's for.
    public static func reason(_ due: Due, now: Date) -> String {
        switch due {
        case .interval(let since, let ranBefore):
            let days = max(0, Int((now.timeIntervalSince(since) / day).rounded(.down)))
            return ranBefore ? "The last prompt audit here was \(days) days ago."
                : "No prompt audit seen here in the \(days) days VibeSwitcher has known this project."
        case .modelChanged(let from, let to):
            return "Its sessions now answer on \(to); the last prompt audit here was for \(from)."
        }
    }

    // MARK: Changes

    /// The book's record for `root` after a look at its transcripts: first seen now if new (the model it answers on
    /// now is where it starts from, whatever an older run was on), every run found after the last one taken as the
    /// last run (the model it answered on, the snooze cleared), and the newest model seen.
    public static func observe(_ project: Project?, scan: Scan, now: Date) -> Project {
        let isNew = project == nil
        var project = project ?? Project(firstSeen: now)
        project.read = scan.read
        if let latest = scan.latestModel, latest.at >= (project.latestModelAt ?? -.infinity) {
            project.latestModel = latest.model
            project.latestModelAt = latest.at
        }
        if let run = scan.runs.max(by: { $0.at < $1.at }), run.at > (project.lastRun ?? -.infinity) {
            project.lastRun = run.at
            if !isNew {
                project.model = run.model ?? project.latestModel
                project.snoozedUntil = nil
            }
        }
        if isNew || project.model == nil { project.model = project.latestModel }
        return project
    }

    /// Run now: run at `now`, on the model its sessions answer on.
    public static func ran(_ project: Project, at now: Date) -> Project {
        var project = project
        project.lastRun = now.timeIntervalSince1970
        project.model = project.latestModel ?? project.model
        project.snoozedUntil = nil
        return project
    }

    /// Remind me in a week.
    public static func snoozed(_ project: Project, at now: Date) -> Project {
        var project = project
        project.snoozedUntil = now.timeIntervalSince1970 + Double(snoozeDays) * day
        return project
    }

    // MARK: Transcripts

    /// One run found in a transcript: when, and the model that answered it (nil: no answer read yet).
    public struct Run: Equatable, Sendable {
        public var at: Double
        public var model: String?
        public init(at: Double, model: String?) {
            self.at = at
            self.model = model
        }
    }

    /// What a look at a project's transcripts found.
    public struct Scan: Equatable, Sendable {
        public var runs: [Run] = []
        public var latestModel: (model: String, at: Double)?
        /// Each transcript's bytes read, to read on from next time.
        public var read: [String: UInt64] = [:]
        public init() {}

        public static func == (a: Scan, b: Scan) -> Bool {
            a.runs == b.runs && a.read == b.read && a.latestModel?.model == b.latestModel?.model && a.latestModel?.at == b.latestModel?.at
        }
    }

    /// Claude Code's folder of transcripts for the project at `root`.
    public static func transcripts(root: String, home: String = VibePaths.home) -> URL {
        URL(fileURLWithPath: LeadLaunch.claudeProjectFolder(root, home: home), isDirectory: true)
    }

    /// A line that may be a run: parsed only then (its JSON may write `/` as `\/`, so not the command's name).
    static let commandNeedle = Data("prompt-audit".utf8)
    static let modelNeedle = Data("\"model\":\"".utf8)
    static let chunk = 4 << 20

    /// Reads the transcripts in `folder` on from where `read` left each (from the start for one that's new or got
    /// shorter): only whole lines, only the lines holding a needle parsed. Plain parsing; nothing written.
    public static func scan(_ folder: URL, read: [String: UInt64] = [:]) -> Scan {
        var scan = Scan()
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".jsonl") }.sorted()
        for name in names {
            let file = folder.appendingPathComponent(name)
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            var offset = read[name] ?? 0
            if offset > size { offset = 0 }
            guard (try? handle.seek(toOffset: offset)) != nil else { continue }
            var pending = Data()
            /// A run whose answer (its model) isn't read yet.
            var waiting: Int?
            while offset < size, let data = try? handle.read(upToCount: chunk), !data.isEmpty {
                pending.append(data)
                guard let last = pending.lastIndex(of: UInt8(ascii: "\n")) else { continue }
                let lines = pending[pending.startIndex...last]
                for line in lines.split(separator: UInt8(ascii: "\n")) { take(Data(line), into: &scan, waiting: &waiting) }
                offset += UInt64(lines.count)
                pending = Data(pending[(last + 1)...])
            }
            scan.read[name] = offset
        }
        return scan
    }

    private static func take(_ line: Data, into scan: inout Scan, waiting: inout Int?) {
        let isRun = line.range(of: commandNeedle) != nil
        guard isRun || line.range(of: modelNeedle) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let at = (object["timestamp"] as? String).flatMap(CodexUsage.timestamp) else { return }
        let message = object["message"] as? [String: Any]
        if isRun, object["type"] as? String == "user", isAuditRun(message?["content"]) {
            scan.runs.append(Run(at: at, model: nil))
            waiting = scan.runs.count - 1
            return
        }
        guard object["type"] as? String == "assistant", let model = normalized(message?["model"] as? String) else { return }
        if let index = waiting {
            scan.runs[index].model = model
            waiting = nil
        }
        if at >= (scan.latestModel?.at ?? -.infinity) { scan.latestModel = (model, at) }
    }

    /// A user turn's content is `/doctor prompt-audit`: its command name and its arguments' first word.
    static func isAuditRun(_ content: Any?) -> Bool {
        let text: String
        if let string = content as? String {
            text = string
        } else if let parts = content as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            return false
        }
        guard text.contains("<command-name>/doctor</command-name>"),
              let open = text.range(of: "<command-args>"), let close = text.range(of: "</command-args>", range: open.upperBound..<text.endIndex) else { return false }
        return text[open.upperBound..<close.lowerBound].split(whereSeparator: \.isWhitespace).first == "prompt-audit"
    }

    // MARK: The book

    /// Every project's record, by its root folder.
    public struct Book: Codable, Equatable, Sendable {
        public var projects: [String: Project] = [:]
        public init() {}

        public static var file: URL { VibePaths.root.appendingPathComponent("prompt-audit.json") }

        public static func load(from file: URL = Book.file) -> Book {
            (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Book.self, from: $0) } ?? Book()
        }

        public func save(to file: URL = Book.file) throws {
            try VibePaths.ensurePrivate(file.deletingLastPathComponent())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try VibePaths.writePrivate(encoder.encode(self), to: file)
        }
    }
}
