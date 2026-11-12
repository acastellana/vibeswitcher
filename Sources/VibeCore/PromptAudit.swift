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
        /// The transcript the last run found was in (by file name): its answer's model is the run's.
        public var runFile: String?
        /// The models the last audit is for: the one that answered the last run, or (before any run since first seen)
        /// those its sessions answered on when first seen. Nil: not known yet (a run whose answer isn't read yet).
        public var models: [String]?
        /// Answers count from here: the last run, or first sight.
        public var since: Double
        /// Each session's (transcript's, by file name) model as of its last answer since `since`.
        public var sessions: [String: Seen]
        /// Remind me in a week: no card before this.
        public var snoozedUntil: Double?
        /// Not for this project.
        public var off: Bool
        /// Each transcript's bytes read so far (by file name): read on from there next time.
        public var read: [String: UInt64]

        public init(firstSeen: Date) {
            self.firstSeen = firstSeen.timeIntervalSince1970
            since = self.firstSeen
            sessions = [:]
            off = false
            read = [:]
        }
    }

    /// A session's model as of its last answer, and when that was (seconds since 1970).
    public struct Seen: Codable, Equatable, Sendable {
        public var model: String
        public var last: Double
        public init(model: String, last: Double) {
            self.model = model
            self.last = last
        }
    }

    /// A session that hasn't answered in this long before the folder's newest answer no longer counts as in use.
    static let activeWindow: TimeInterval = 2 * day

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

    /// The model its sessions moved to, if they did: none of the sessions in use (those that answered within two days
    /// of the folder's newest answer) is on a model the last audit is for any more. Two sessions on two models in the
    /// folder (the lead on one, your own session on another) are no change while either is still on the audited one,
    /// whichever wrote last.
    public static func movedTo(_ project: Project) -> (from: String, to: String)? {
        guard let models = project.models, !models.isEmpty, let newest = project.sessions.values.map(\.last).max() else { return nil }
        let active = project.sessions.values.filter { $0.last >= newest - activeWindow }
        guard !active.contains(where: { models.contains($0.model) }),
              let newest = active.max(by: { ($0.last, $0.model) < ($1.last, $1.model) })?.model else { return nil }
        // Named by the session the last run was in (the lead's, as a rule), when it's among those in use.
        let to = project.runFile.flatMap { file in project.sessions[file].flatMap { active.contains($0) ? $0.model : nil } } ?? newest
        return (models.sorted().joined(separator: ", "), to)
    }

    /// Whether `project` gets a card at `now`, and why. Off, snoozed or turned off: none. A model change shows at once;
    /// the interval counts from the last run, never from before VibeSwitcher first saw the project.
    public static func due(_ project: Project, now: Date, intervalDays: Int = defaultIntervalDays) -> Due? {
        guard !project.off else { return nil }
        if let until = project.snoozedUntil, now.timeIntervalSince1970 < until { return nil }
        if let moved = movedTo(project) { return .modelChanged(from: moved.from, to: moved.to) }
        let since = max(project.lastRun ?? project.firstSeen, project.firstSeen)
        guard now.timeIntervalSince1970 >= since + Double(intervalDays) * day else { return nil }
        return .interval(since: Date(timeIntervalSince1970: since), ranBefore: project.lastRun != nil)
    }

    /// What the card says it's for.
    public static func reason(_ due: Due, now: Date) -> String {
        switch due {
        case .interval(let since, let ranBefore):
            let days = max(0, Int((now.timeIntervalSince(since) / day + 0.001).rounded(.down)))
            return ranBefore ? "The last prompt audit here was \(days) days ago."
                : "No prompt audit seen here in the \(days) days VibeSwitcher has known this project."
        case .modelChanged(let from, let to):
            return "Its sessions now answer on \(to); the last prompt audit here was for \(from)."
        }
    }

    // MARK: Changes

    /// How far back first sight looks for the models in use.
    static let firstSightWindow: TimeInterval = 7 * day

    /// The book's record for `root` after a look at its transcripts. New: first seen now, the models its sessions
    /// answered on in the week before (else the last one) what it starts from, whatever an older run was on. A run
    /// found after the last one: the last run (the clock restarts, the snooze is cleared), and the model that answers
    /// it in its own transcript is what the audit is for. Every answer since is counted by model.
    public static func observe(_ project: Project?, scan: Scan, now: Date) -> Project {
        let isNew = project == nil
        var project = project ?? Project(firstSeen: now)
        project.read = scan.read
        if isNew {
            // Every session's model as of its last answer, whenever that was; the audit is for those in use this week.
            project.since = -.infinity
            take(scan.answers, into: &project)
            project.since = project.firstSeen
            let recent = Set(project.sessions.values.filter { $0.last >= now.timeIntervalSince1970 - firstSightWindow }.map(\.model))
            let models = recent.isEmpty ? project.sessions.values.max(by: { $0.last < $1.last }).map { [$0.model] } ?? [] : recent.sorted()
            project.models = models.isEmpty ? nil : models
            if let run = scan.runs.max(by: { $0.at < $1.at }) { project.lastRun = run.at }
            return project
        }
        if let run = scan.runs.max(by: { $0.at < $1.at }), run.at > (project.lastRun ?? -.infinity) {
            project.lastRun = run.at
            project.runFile = run.file
            project.since = run.at
            project.sessions = [:]
            project.models = nil
            project.snoozedUntil = nil
        }
        // The run's answer, in its own transcript (in this look or a later one).
        if project.models == nil, let file = project.runFile, let lastRun = project.lastRun,
           let answer = scan.answers.filter({ $0.file == file && $0.at >= lastRun }).min(by: { $0.at < $1.at }) {
            project.models = [answer.model]
        }
        take(scan.answers, into: &project)
        // Nothing says which model a run was for (it was sent but never found, or found with no answer) a day on:
        // the models that answered since.
        if project.models == nil, now.timeIntervalSince1970 - (project.lastRun ?? project.firstSeen) > day, !project.sessions.isEmpty {
            project.models = Array(Set(project.sessions.values.map(\.model))).sorted()
        }
        return project
    }

    private static func take(_ answers: [Answer], into project: inout Project) {
        for answer in answers where answer.at >= project.since && answer.at >= (project.sessions[answer.file]?.last ?? -.infinity) {
            project.sessions[answer.file] = Seen(model: answer.model, last: answer.at)
        }
    }

    /// Run now: run at `now`; the model it's for is the one that answers it, once a look finds the run.
    public static func ran(_ project: Project, at now: Date) -> Project {
        var project = project
        project.lastRun = now.timeIntervalSince1970
        project.runFile = nil
        project.since = now.timeIntervalSince1970
        project.sessions = [:]
        project.models = nil
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

    /// One run found in a transcript: when, and in which (by file name).
    public struct Run: Equatable, Sendable {
        public var at: Double
        public var file: String
        public init(at: Double, file: String) {
            self.at = at
            self.file = file
        }
    }

    /// One assistant answer: its model, when, and in which transcript.
    public struct Answer: Equatable, Sendable {
        public var model: String
        public var at: Double
        public var file: String
        public init(model: String, at: Double, file: String) {
            self.model = model
            self.at = at
            self.file = file
        }
    }

    /// What a look at a project's transcripts found.
    public struct Scan: Equatable, Sendable {
        public var runs: [Run] = []
        public var answers: [Answer] = []
        /// Each transcript's bytes read, to read on from next time.
        public var read: [String: UInt64] = [:]
        public init() {}
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
            while offset < size, let data = try? handle.read(upToCount: chunk), !data.isEmpty {
                pending.append(data)
                guard let last = pending.lastIndex(of: UInt8(ascii: "\n")) else { continue }
                let lines = pending[pending.startIndex...last]
                for line in lines.split(separator: UInt8(ascii: "\n")) { take(Data(line), file: name, into: &scan) }
                offset += UInt64(lines.count)
                pending = Data(pending[(last + 1)...])
            }
            scan.read[name] = offset
        }
        return scan
    }

    private static func take(_ line: Data, file: String, into scan: inout Scan) {
        let isRun = line.range(of: commandNeedle) != nil
        guard isRun || line.range(of: modelNeedle) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let at = (object["timestamp"] as? String).flatMap(CodexUsage.timestamp) else { return }
        let message = object["message"] as? [String: Any]
        if isRun, object["type"] as? String == "user", isAuditRun(message?["content"]) {
            scan.runs.append(Run(at: at, file: file))
            return
        }
        guard object["type"] as? String == "assistant", let model = normalized(message?["model"] as? String) else { return }
        scan.answers.append(Answer(model: model, at: at, file: file))
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
