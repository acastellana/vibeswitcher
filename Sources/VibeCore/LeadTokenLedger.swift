import Foundation

/// A project lead's own tokens, per local day, read from its Claude Code transcripts the way receipts read a task's
/// workers' and verifiers' (`LeadReceipts`): in Claude's folder for the project's root, the transcripts named for its
/// lead (`lead-<project slug>`, the name `LeadController` starts it with) and their subagents'. Kept in the project's
/// `.vibeswitcher/lead-tokens.json` (0600), which Statistics reads; the app's load recorder tallies it every `every`
/// for the projects whose lead is live (`LoadRecorder.tallyLeads`), off the main thread.
///
/// Each tally reads only what the transcripts gained since the last (by byte offset, up to their last whole line), so
/// it costs a few small reads and one write of the ledger. Recording starts with the ledger: transcripts there when it
/// was made count from their end then, and responses from before `since` never count. A response counts once: by its
/// message id among a transcript's recent ones (a transcript repeats a response once per content block), and a
/// transcript's responses from before it was made (a resumed session's copies of earlier ones) never. Numbers only:
/// no transcript text is kept.
public enum LeadTokenLedger {
    public static let fileName = "lead-tokens.json"
    /// How often the load recorder tallies.
    public static let every: TimeInterval = 5 * 60
    /// A transcript's bytes read in one tally at most (the rest the next time).
    static let readLimit = 32 << 20
    /// The message ids kept per transcript to tell a response's repeats.
    static let recentIDs = 64
    /// A transcript's responses timestamped this long before it was made are copies of another's.
    static let copySlack: Double = 60

    public struct Ledger: Codable, Equatable, Sendable {
        /// When recording began: the lead's tokens before it aren't in it.
        public var since: Double
        /// When it was last tallied.
        public var at: Double
        /// By local day ("2026-11-02").
        public var days: [String: Day]
        /// By transcript (its path under Claude's projects folder): what's been read of it.
        public var files: [String: Mark]

        public init(since: Double, at: Double, days: [String: Day] = [:], files: [String: Mark] = [:]) {
            self.since = since
            self.at = at
            self.days = days
            self.files = files
        }
    }

    /// One day's tokens of the lead's sessions.
    public struct Day: Codable, Equatable, Sendable {
        public var input = 0, output = 0, cacheRead = 0, cacheWrite = 0, cacheWrite1h = 0
        /// The estimated cost of the priced responses (`LeadPrices`); `unpriced`: the models that had none.
        public var cost = 0.0
        public var unpriced: [String]?
        /// Tokens by model.
        public var models: [String: Int] = [:]
        /// The transcripts (sessions, subagents' included) its responses came from.
        public var sessions: [String] = []

        public init() {}

        public var total: Int { input + output + cacheRead + cacheWrite }

        /// As a receipt's role shows tokens: cost unknown when a model had no price.
        public var tokens: LeadTokens {
            LeadTokens(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, cacheWrite1h: cacheWrite1h,
                       sessions: sessions.count, models: models.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key),
                       cost: unpriced == nil ? cost : nil, unpriced: unpriced)
        }

        mutating func add(_ response: LeadReceipts.Response, session: String) {
            input += response.input
            output += response.output
            cacheRead += response.cacheRead
            cacheWrite += response.cacheWrite
            cacheWrite1h += response.cacheWrite1h
            models[response.model, default: 0] += response.input + response.output + response.cacheRead + response.cacheWrite
            if let price = LeadPrices.price(response.model) {
                cost += LeadPrices.cost(response, price: price)
            } else {
                unpriced = Array(Set((unpriced ?? []) + [response.model])).sorted()
            }
            if !sessions.contains(session) { sessions.append(session) }
        }
    }

    /// What's been read of a transcript.
    public struct Mark: Codable, Equatable, Sendable {
        /// It's the lead's (its name says so).
        public var lead: Bool
        /// The lead's: the bytes read (to its last whole line). Another's: its size when its name was read.
        public var offset: Int
        /// When it was made (its responses from before are copies).
        public var born: Double?
        /// The message ids of its latest responses counted.
        public var recent: [String]?
    }

    /// `root`'s ledger file.
    public static func file(root: String) -> URL {
        URL(fileURLWithPath: root).appendingPathComponent(".vibeswitcher").appendingPathComponent(fileName)
    }

    /// `root`'s ledger; nil when there's none or it can't be read.
    public static func load(root: String) -> Ledger? {
        (try? Data(contentsOf: file(root: root))).flatMap { try? JSONDecoder().decode(Ledger.self, from: $0) }
    }

    /// The name `root`'s lead is started with.
    public static func leadName(root: String) -> String {
        "lead-" + Slug.make(((root as NSString).standardizingPath as NSString).lastPathComponent, taken: [])
    }

    /// Tallies each of `roots` (a project with a board; any other is passed over), its errors left for the next tally.
    public static func tally(roots: [String], home: String = VibePaths.home, now: Date = Date()) {
        for root in roots { _ = try? tally(root: root, home: home, now: now) }
    }

    /// Tallies `root`'s lead up to now and writes its ledger; nil (nothing written) when it has no board.
    @discardableResult
    public static func tally(root: String, home: String = VibePaths.home, now: Date = Date()) throws -> Ledger? {
        let folder = URL(fileURLWithPath: root).appendingPathComponent(".vibeswitcher")
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("board.json").path) else { return nil }
        let seconds = now.timeIntervalSince1970
        let made = load(root: root) == nil
        var ledger = load(root: root) ?? Ledger(since: seconds, at: seconds)
        let projects = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects")
        let name = leadName(root: root)
        var present = Set<String>()
        for claudeFolder in claudeFolders(root: root, projects: projects) {
            let files = (try? FileManager.default.contentsOfDirectory(at: claudeFolder, includingPropertiesForKeys: nil)) ?? []
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "jsonl" {
                let key = claudeFolder.lastPathComponent + "/" + file.lastPathComponent
                present.insert(key)
                guard let size = fileSize(file) else { continue }
                var mark = ledger.files[key]
                // Its name is read once, again while it's too young to be sure it has one (a few lines).
                if mark == nil || (mark?.lead == false && mark!.offset != size && mark!.offset < 128 * 1024) {
                    let lead = LeadReceipts.names(in: file).contains(name)
                    mark = Mark(lead: lead, offset: lead ? (made ? size : 0) : size, born: born(file), recent: nil)
                }
                guard var lead = mark, lead.lead else { ledger.files[key] = mark; continue }
                read(file, session: key, mark: &lead, size: size, ledger: &ledger)
                ledger.files[key] = lead
                // Its subagents' transcripts: the lead's too.
                let subagents = file.deletingPathExtension().appendingPathComponent("subagents")
                let agents = (try? FileManager.default.contentsOfDirectory(at: subagents, includingPropertiesForKeys: nil)) ?? []
                for agent in agents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where agent.pathExtension == "jsonl" {
                    let agentKey = String(key.dropLast(".jsonl".count)) + "/subagents/" + agent.lastPathComponent
                    present.insert(agentKey)
                    guard let agentSize = fileSize(agent) else { continue }
                    var agentMark = ledger.files[agentKey] ?? Mark(lead: true, offset: made ? agentSize : 0, born: born(agent), recent: nil)
                    read(agent, session: agentKey, mark: &agentMark, size: agentSize, ledger: &ledger)
                    ledger.files[agentKey] = agentMark
                }
            }
        }
        // Transcripts gone (Claude prunes old ones) needn't be remembered.
        ledger.files = ledger.files.filter { present.contains($0.key) }
        ledger.at = seconds
        try VibePaths.ensurePrivate(folder)
        try VibePaths.writePrivate(try JSONEncoder().encode(ledger), to: file(root: root))
        return ledger
    }

    /// Claude's folders for `root` (as given and as resolved).
    static func claudeFolders(root: String, projects: URL) -> [URL] {
        let resolved = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        var seen = Set<String>()
        return [root, (root as NSString).standardizingPath, resolved].map(RecentProjects.claudeSlug(for:))
            .filter { seen.insert($0).inserted }.map { projects.appendingPathComponent($0) }
    }

    /// Reads what `file` gained since `mark`, adding its responses to their days.
    static func read(_ file: URL, session: String, mark: inout Mark, size: Int, ledger: inout Ledger) {
        // Rewritten shorter: another file now.
        if size < mark.offset { mark = Mark(lead: true, offset: 0, born: born(file), recent: nil) }
        guard size > mark.offset, let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(mark.offset))) != nil,
              let data = try? handle.read(upToCount: min(size - mark.offset, readLimit)), !data.isEmpty else { return }
        // Up to its last whole line; a line longer than a whole read is passed over.
        guard let end = data.lastIndex(of: UInt8(ascii: "\n")) else {
            if data.count >= readLimit { mark.offset += data.count }
            return
        }
        let whole = data[data.startIndex...end]
        mark.offset += whole.count
        var seen = Set(mark.recent ?? [])
        let floor = max(ledger.since, (mark.born ?? 0) - copySlack)
        let responses = LeadReceipts.responses(in: Data(whole), since: floor, seen: &seen)
        for response in responses {
            guard let at = response.at else { continue }
            ledger.days[LoadStats.day(Date(timeIntervalSince1970: at)), default: Day()].add(response, session: session)
        }
        let recent = (mark.recent ?? []) + responses.map(\.id)
        mark.recent = recent.isEmpty ? nil : Array(recent.suffix(recentIDs))
    }

    static func fileSize(_ file: URL) -> Int? {
        var info = stat()
        guard stat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Int(info.st_size)
    }

    /// When `file` was made (its birth time), nil when not known.
    static func born(_ file: URL) -> Double? {
        if let given = givenBirthsLock.withLock({ givenBirths[file.path] }) { return given }
        return Platform.Files.birthTime(file.path)
    }

    /// Birth times a test gives files, by path: Linux can't set one (`setAttributes` says yes and does nothing), the
    /// Mac can. Empty in the app.
    nonisolated(unsafe) static var givenBirths: [String: Double] = [:]
    static let givenBirthsLock = NSLock()
}
