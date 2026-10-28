import Foundation

/// What a task cost, kept on it once it ends (merged, folded or abandoned): its worker's working time and the wall
/// time from its first worker's start to its end; the tokens its workers and its verifiers spent, read from their own
/// Claude Code transcripts, with an estimated cost (`LeadPrices`); its audit rounds, re-rolls and merge reruns; the
/// merge's test count; the user's questions about it and the time they waited; and the commits its merge brought, with
/// where to roll back to. Numbers only: no transcript text is kept. Tasks that ended before receipts have none, and
/// show nothing. The lead's board(task) shows it; the scorecard and the all-done card sum a batch's (`LeadReceiptTotals`).
public struct LeadReceipt: Codable, Equatable, Sendable {
    public enum Ending: String, Codable, Sendable { case merged, folded, abandoned }

    public var ending: Ending
    /// When its first worker started (nil: never started); when it ended.
    public var startedAt: Double?
    public var endedAt: Double
    /// Its workers' counted working time, in seconds (see `LeadBudget.counts`).
    public var worked: Double?
    /// The tokens of its worker sessions and of its verifier (and finder) sessions; nil: no transcript of that role found.
    public var worker: LeadTokens?
    public var verifier: LeadTokens?
    public var rounds: Int
    public var rerolls: Int
    /// The merge's test reruns (`MergeRerun`): 0 or 1.
    public var mergeReruns: Int
    /// The tests the merge's test run reported (nil: none ran, or its output named no count).
    public var tests: Int?
    public var questions: Int
    /// Seconds those questions waited on the user.
    public var waitingOnUser: Double
    /// Merged: the base's head it went onto (the rollback point), the commit it left, and how many commits it brought.
    public var onto: String?
    public var commit: String?
    public var commits: Int?
    /// The date of the prices its cost is estimated with (`LeadPrices.asOf`).
    public var pricesAsOf: String

    public init(ending: Ending, startedAt: Double?, endedAt: Double, worked: Double?, worker: LeadTokens?, verifier: LeadTokens?,
                rounds: Int = 0, rerolls: Int = 0, mergeReruns: Int = 0, tests: Int? = nil, questions: Int = 0, waitingOnUser: Double = 0,
                onto: String? = nil, commit: String? = nil, commits: Int? = nil, pricesAsOf: String = LeadPrices.asOf) {
        self.ending = ending
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.worked = worked
        self.worker = worker
        self.verifier = verifier
        self.rounds = rounds
        self.rerolls = rerolls
        self.mergeReruns = mergeReruns
        self.tests = tests
        self.questions = questions
        self.waitingOnUser = waitingOnUser
        self.onto = onto
        self.commit = commit
        self.commits = commits
        self.pricesAsOf = pricesAsOf
    }

    /// `task`'s receipt as it ends now: the board's numbers for it, `usage` from its transcripts (`LeadReceipts.usage`).
    public init(_ task: LeadTask, ending: Ending, questions: [LeadQuestion], usage: LeadReceipts.Usage, tests: Int? = nil,
                mergeReruns: Int = 0, commits: Int? = nil, now: Double = Date().timeIntervalSince1970) {
        let asked = questions.filter { $0.task == task.slug }
        let merged = ending == .merged ? task.merged : nil
        self.init(ending: ending, startedAt: task.startedAt, endedAt: now, worked: task.worked, worker: usage.worker, verifier: usage.verifier,
                  rounds: task.audits?.rounds ?? 0, rerolls: task.rerolls?.count ?? 0, mergeReruns: mergeReruns, tests: tests,
                  questions: asked.count, waitingOnUser: asked.reduce(0) { $0 + $1.waitingOnUser(now: now) },
                  onto: merged?.onto, commit: merged?.commit, commits: commits)
    }

    /// Seconds from its first worker's start to its end.
    public var wall: Double? { startedAt.map { max(0, endedAt - $0) } }
    public var tokens: Int { (worker?.total ?? 0) + (verifier?.total ?? 0) }
    /// The estimated cost of both roles; nil when a role's is unknown (a model not in `LeadPrices`).
    public var cost: Double? {
        let parts = [worker, verifier].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        let costs = parts.compactMap(\.cost)
        return costs.count == parts.count ? costs.reduce(0, +) : nil
    }

    /// "Receipt (merged; cost an estimate at prices of 2026-10-06): 1 h 12 min worked, 3 h 4 min wall · worker 15.5M
    /// tokens (in 202, out 73.2k, cache read 15.2M, cache write 298k), verifier 2.1M tokens (…) · est. $6.67 · 2 audit
    /// rounds, 1 re-roll, 1 merge rerun · 1234 tests · 1 question to you, 4 min waiting · 3 commits onto 3f2a1b4c
    /// (rollback point)". Unknown parts are left out, never shown as zeros.
    public var line: String {
        var parts: [String] = []
        // A time that wasn't counted (boards from before the witness counted it) is left out, not shown as 0.
        let time = [worked.map { "\(LeadToolset.age($0)) worked" }, wall.map { "\(LeadToolset.age($0)) wall" }].compactMap { $0 }
        if !time.isEmpty { parts.append(time.joined(separator: ", ")) }
        let roles = [("worker", worker), ("verifier", verifier)].compactMap { name, tokens in tokens.map { "\(name) \($0.text)" } }
        parts.append(roles.isEmpty ? "tokens unknown (no transcripts of its sessions found)" : roles.joined(separator: ", "))
        if !roles.isEmpty { parts.append(cost.map { "est. \(Self.dollars($0))" } ?? "cost unknown" + Self.unpricedNote([worker, verifier])) }
        var runs = ["\(rounds) audit round\(rounds == 1 ? "" : "s")"]
        if rerolls > 0 { runs.append("\(rerolls) re-roll\(rerolls == 1 ? "" : "s")") }
        if mergeReruns > 0 { runs.append("\(mergeReruns) merge rerun\(mergeReruns == 1 ? "" : "s")") }
        parts.append(runs.joined(separator: ", "))
        if let tests { parts.append("\(tests) tests in the merge's run") }
        if questions > 0 {
            parts.append("\(questions) question\(questions == 1 ? "" : "s") to you, \(LeadScorecard.minutes(waitingOnUser / 60)) min waiting")
        }
        if let commit, let onto {
            let count = commits.map { "\($0) commit\($0 == 1 ? "" : "s")" } ?? "its commits"
            parts.append("\(count) \(onto.prefix(8))..\(commit.prefix(8)); rollback point \(onto.prefix(8))")
        }
        return "Receipt (\(ending.rawValue); cost an estimate at prices of \(pricesAsOf)): " + parts.joined(separator: " · ")
    }

    /// " (no price for claude-x)" for the models that left a cost unknown.
    static func unpricedNote(_ tokens: [LeadTokens?]) -> String {
        let models = Array(Set(tokens.compactMap { $0?.unpriced }.flatMap { $0 })).sorted()
        return models.isEmpty ? "" : " (no price for \(models.joined(separator: ", ")))"
    }

    /// 6.674 → "$6.67"; 0.004 → "$0.004".
    public static func dollars(_ value: Double) -> String {
        value >= 0.01 || value == 0 ? String(format: "$%.2f", value) : String(format: "$%.3f", value)
    }

    /// 15_473_000 → "15.5M", 298_031 → "298k", 73_190 → "73.2k", 202 → "202".
    public static func count(_ value: Int) -> String {
        switch value {
        case 1_000_000...: return String(format: value >= 10_000_000 ? "%.0fM" : "%.1fM", Double(value) / 1_000_000)
        case 100_000...: return String(format: "%.0fk", Double(value) / 1000)
        case 1000...: return String(format: "%.1fk", Double(value) / 1000)
        default: return "\(value)"
        }
    }

    /// The tests a test run's output reports: XCTest's "Executed N tests" (its largest: the whole run's) plus Swift
    /// Testing's "Test run with N tests", node's "# tests N" / "ℹ tests N", pytest's "N passed", Jest's "Tests: … N
    /// total" and cargo's "test result: ok. N passed" (summed over its binaries); nil when it names none.
    public static func testCount(_ output: String) -> Int? {
        func numbers(_ pattern: String) -> [Int] {
            let regex = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
            return regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).compactMap {
                Range($0.range(at: 1), in: output).flatMap { Int(output[$0]) }
            }
        }
        let found = [numbers(#"Executed (\d+) tests?, with"#).max(),
                     numbers(#"Test run with (\d+) tests?"#).max(),
                     numbers(#"^\s*(?:#|ℹ) tests (\d+)\s*$"#).reduce(nil) { ($0 ?? 0) + $1 },
                     numbers(#"^=+ .*?(\d+) passed"#).max(),
                     numbers(#"^Tests:.*?(\d+) total"#).max(),
                     numbers(#"^test result: \w+\. (\d+) passed"#).reduce(nil) { ($0 ?? 0) + $1 }].compactMap { $0 }
        return found.isEmpty ? nil : found.reduce(0, +)
    }
}

/// The tokens one role's sessions spent, as their transcripts' API responses report them, and their estimated cost.
public struct LeadTokens: Codable, Equatable, Sendable {
    /// Uncached input, output, cache reads and cache writes (the 1-hour ones among them, priced higher).
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var cacheWrite1h: Int
    /// The sessions (transcripts, subagents' included) they were read from.
    public var sessions: Int
    /// The models that answered, most tokens first.
    public var models: [String]
    /// Its estimated cost in US dollars; nil when a model it used has no price (`unpriced`).
    public var cost: Double?
    public var unpriced: [String]?

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, cacheWrite1h: Int = 0, sessions: Int = 0,
                models: [String] = [], cost: Double? = 0, unpriced: [String]? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.cacheWrite1h = cacheWrite1h
        self.sessions = sessions
        self.models = models
        self.cost = cost
        self.unpriced = unpriced
    }

    public var total: Int { input + output + cacheRead + cacheWrite }

    /// "15.5M tokens (in 202, out 73.2k, cache read 15.2M, cache write 298k; claude-opus-5-5)".
    public var text: String {
        "\(LeadReceipt.count(total)) tokens (in \(LeadReceipt.count(input)), out \(LeadReceipt.count(output)), cache read "
            + "\(LeadReceipt.count(cacheRead)), cache write \(LeadReceipt.count(cacheWrite))" + (models.isEmpty ? "" : "; \(models.joined(separator: ", "))") + ")"
    }
}

/// Per-model API prices, in US dollars per million tokens, for estimating what a task cost. One table, with the date
/// its prices were taken: Anthropic's first-party rates as the claude-api skill's model table had them (cached
/// 2026-10-06). Cache writes cost 1.25× input for the 5-minute duration and 2× for the 1-hour one; fast mode costs 2×.
/// A model not in the table has no price: its tokens show with "cost unknown", never a wrong number.
public enum LeadPrices {
    public static let asOf = "2026-10-06"

    public struct Price: Equatable, Sendable {
        public var input: Double
        public var output: Double
        public var cacheRead: Double
        /// Prompts over `longOver` tokens (input, cache reads and writes) cost these instead (Haiku 5.5).
        public var longOver: Int?
        public var longInput: Double?
        public var longOutput: Double?

        public init(input: Double, output: Double, cacheRead: Double? = nil, longOver: Int? = nil, longInput: Double? = nil, longOutput: Double? = nil) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead ?? input / 10
            self.longOver = longOver
            self.longInput = longInput
            self.longOutput = longOutput
        }
    }

    public static let table: [String: Price] = [
        "claude-fable-5-1": Price(input: 10, output: 50, cacheRead: 0.25),
        "claude-mythos-5-1": Price(input: 10, output: 50, cacheRead: 0.25),
        "claude-fable-5": Price(input: 10, output: 50, cacheRead: 1),
        "claude-mythos-5": Price(input: 10, output: 50, cacheRead: 1),
        "claude-opus-5-5": Price(input: 4, output: 20, cacheRead: 0.20),
        "claude-opus-5": Price(input: 5, output: 25),
        "claude-opus-4-8": Price(input: 5, output: 25),
        "claude-opus-4-7": Price(input: 5, output: 25),
        "claude-opus-4-6": Price(input: 5, output: 25),
        "claude-sonnet-5-5": Price(input: 2, output: 10, cacheRead: 0.20),
        "claude-sonnet-5": Price(input: 2, output: 10),
        "claude-sonnet-4-6": Price(input: 3, output: 15),
        "claude-haiku-5-5": Price(input: 0.10, output: 0.50, longOver: 100_000, longInput: 0.50, longOutput: 2.50),
        "claude-haiku-4-5": Price(input: 1, output: 5),
    ]

    /// The price of `model` as a transcript names it: its id, also with a context suffix ("[1m]"), a date
    /// ("-20251001") or a platform prefix ("anthropic.", "us.anthropic."); nil for any other.
    public static func price(_ model: String) -> Price? {
        var id = model.lowercased()
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        if let dot = id.range(of: "anthropic.", options: .backwards) { id = String(id[dot.upperBound...]) }
        if let at = id.firstIndex(of: "@") { id = String(id[..<at]) }
        if let price = table[id] { return price }
        if let match = id.range(of: #"-\d{8}$"#, options: .regularExpression) { return table[String(id[..<match.lowerBound])] }
        return nil
    }

    /// The cost of one response's usage on `price`, `fast` for fast mode.
    static func cost(_ usage: LeadReceipts.Response, price: Price) -> Double {
        let prompt = usage.input + usage.cacheRead + usage.cacheWrite
        let long = price.longOver.map { prompt > $0 } ?? false
        let input = long ? price.longInput ?? price.input : price.input
        let output = long ? price.longOutput ?? price.output : price.output
        let read = long ? input / 10 : price.cacheRead
        let fiveMinute = usage.cacheWrite - usage.cacheWrite1h
        let dollars = Double(usage.input) * input + Double(usage.output) * output + Double(usage.cacheRead) * read
            + Double(fiveMinute) * input * 1.25 + Double(usage.cacheWrite1h) * input * 2
        return dollars / 1_000_000 * (usage.fast ? 2 : 1)
    }
}

/// Reads a task's tokens from its own sessions' Claude Code transcripts: in Claude's folder for its worktree (where its
/// workers and verifiers run), the transcripts named for its worker (`worker-<slug>`), its verifier (`verify-<slug>`)
/// or a finder (`finder<N>-<slug>`), with their subagents'. Any other transcript there (the user's own session in that
/// folder, say) isn't read past its name. Each API response counts once, by its message id: a transcript repeats a
/// response once per content block, and a resumed session's copies earlier ones.
public enum LeadReceipts {
    public enum Role: String, Sendable { case worker, verifier }

    /// One API response's usage.
    struct Response: Equatable {
        var model: String
        var input = 0, output = 0, cacheRead = 0, cacheWrite = 0, cacheWrite1h = 0
        var fast = false
    }

    /// Both roles' tokens.
    public struct Usage: Equatable, Sendable {
        public var worker: LeadTokens?
        public var verifier: LeadTokens?

        public init(worker: LeadTokens? = nil, verifier: LeadTokens? = nil) {
            self.worker = worker
            self.verifier = verifier
        }
    }

    /// Claude's folders for `slug`'s worktree under `root` (the path as given and as resolved).
    public static func folders(root: String, slug: String, home: String = VibePaths.home) -> [URL] {
        let projects = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects")
        let worktree = Worktrees.path(root: root, slug: slug)
        let resolved = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let paths = [worktree, (worktree as NSString).standardizingPath, Worktrees.path(root: resolved, slug: slug)]
        var seen = Set<String>()
        return paths.map(RecentProjects.claudeSlug(for:)).filter { seen.insert($0).inserted }.map { projects.appendingPathComponent($0) }
    }

    /// The role a transcript's session holds in `slug`, by the name it was started with; nil for any other session.
    static func role(named names: Set<String>, slug: String) -> Role? {
        if names.contains("worker-\(slug)") { return .worker }
        if names.contains("verify-\(slug)") { return .verifier }
        if names.contains(where: { $0.hasPrefix("finder") && $0.hasSuffix("-\(slug)") && Int($0.dropFirst(6).dropLast(slug.count + 1)) != nil }) {
            return .verifier
        }
        return nil
    }

    /// `slug`'s transcripts and their roles: each session's own, then its subagents'.
    public static func transcripts(root: String, slug: String, home: String = VibePaths.home) -> [(role: Role, url: URL)] {
        var found: [(role: Role, url: URL)] = []
        for folder in folders(root: root, slug: slug, home: home) {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "jsonl" {
                guard let role = role(named: names(in: file), slug: slug) else { continue }
                found.append((role, file))
                let subagents = file.deletingPathExtension().appendingPathComponent("subagents")
                let agents = (try? FileManager.default.contentsOfDirectory(at: subagents, includingPropertiesForKeys: nil)) ?? []
                found += agents.filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { (role, $0) }
            }
        }
        return found
    }

    /// The names a transcript's session was given (`customTitle`, `agentName`), from the first and last 64 KB, where
    /// Claude writes them: nothing else of it is read to tell whose it is.
    static func names(in url: URL) -> Set<String> {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let limit = 64 * 1024
        guard var data = try? handle.read(upToCount: limit), let size = try? handle.seekToEnd() else { return [] }
        if size > UInt64(limit), (try? handle.seek(toOffset: max(UInt64(limit), size - UInt64(limit)))) != nil, let end = try? handle.readToEnd() {
            data.append(end)
        }
        let text = String(decoding: data, as: UTF8.self)
        let regex = try! NSRegularExpression(pattern: #""(?:customTitle|agentName)":"([^"\\]{1,200})""#)
        return Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        })
    }

    /// The tokens of `slug`'s sessions (see `transcripts`), counting responses from `since` on (its creation: a folder
    /// a removed task of the same name used stays out).
    public static func usage(root: String, slug: String, since: Double, home: String = VibePaths.home) -> Usage {
        usage(transcripts(root: root, slug: slug, home: home), since: since)
    }

    /// The tokens in `files`, by role: each response once, wherever it's repeated.
    static func usage(_ files: [(role: Role, url: URL)], since: Double) -> Usage {
        var seen = Set<String>()
        var tallies: [Role: (responses: [Response], sessions: Int)] = [:]
        for (role, url) in files {
            guard let data = try? Data(contentsOf: url) else { continue }
            let responses = self.responses(in: data, since: since, seen: &seen)
            tallies[role, default: ([], 0)].responses += responses
            tallies[role, default: ([], 0)].sessions += 1
        }
        func tokens(_ role: Role) -> LeadTokens? {
            guard let tally = tallies[role] else { return nil }
            var tokens = LeadTokens(sessions: tally.sessions)
            var byModel: [String: Int] = [:]
            var unpriced = Set<String>()
            var cost = 0.0
            for response in tally.responses {
                tokens.input += response.input
                tokens.output += response.output
                tokens.cacheRead += response.cacheRead
                tokens.cacheWrite += response.cacheWrite
                tokens.cacheWrite1h += response.cacheWrite1h
                byModel[response.model, default: 0] += response.input + response.output + response.cacheRead + response.cacheWrite
                if let price = LeadPrices.price(response.model) { cost += LeadPrices.cost(response, price: price) } else { unpriced.insert(response.model) }
            }
            tokens.models = byModel.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
            tokens.cost = unpriced.isEmpty ? cost : nil
            tokens.unpriced = unpriced.isEmpty ? nil : unpriced.sorted()
            return tokens
        }
        return Usage(worker: tokens(.worker), verifier: tokens(.verifier))
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// The API responses in a transcript's lines (`"type":"assistant"` with a usage), from `since` on, each once:
    /// those whose message id (else request id) is in `seen` are left out, and the rest added to it. A response with
    /// no tokens (Claude Code's own `<synthetic>` notes) isn't one.
    static func responses(in data: Data, since: Double, seen: inout Set<String>) -> [Response] {
        var responses: [Response] = []
        let usageKey = Data("\"usage\"".utf8)
        for line in data.split(separator: UInt8(ascii: "\n")) where line.range(of: usageKey) != nil {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] else { continue }
            if let stamp = object["timestamp"] as? String, let date = iso.date(from: stamp), date.timeIntervalSince1970 < since { continue }
            let int = { (key: String) in (usage[key] as? NSNumber)?.intValue ?? 0 }
            let creation = usage["cache_creation"] as? [String: Any]
            var response = Response(model: message["model"] as? String ?? "unknown", input: int("input_tokens"), output: int("output_tokens"),
                                    cacheRead: int("cache_read_input_tokens"), cacheWrite: int("cache_creation_input_tokens"),
                                    cacheWrite1h: (creation?["ephemeral_1h_input_tokens"] as? NSNumber)?.intValue ?? 0,
                                    fast: usage["speed"] as? String == "fast")
            response.cacheWrite1h = min(response.cacheWrite1h, response.cacheWrite)
            guard response.input + response.output + response.cacheRead + response.cacheWrite > 0 else { continue }
            guard let id = message["id"] as? String ?? object["requestId"] as? String ?? object["uuid"] as? String else { continue }
            guard seen.insert(id).inserted else { continue }
            responses.append(response)
        }
        return responses
    }
}

/// A batch's receipts summed: how many tasks have one, their workers' hours, tokens and estimated cost, and the most
/// expensive of them. The all-done card shows its batch's; status and the scorecard the board's current batch.
public struct LeadReceiptTotals: Codable, Equatable, Sendable {
    public var tasks: Int
    /// Seconds.
    public var worked: Double
    public var tokens: Int
    /// The known costs summed; `unpriced` tasks' costs are unknown and not in it.
    public var cost: Double
    public var unpriced: Int
    /// The task that cost the most (by estimated cost; by tokens when no cost is known), its title and what it cost.
    public var top: String?
    public var topTitle: String?
    public var topCost: Double?
    public var topTokens: Int?
    public var pricesAsOf: String

    /// `tasks`' receipts summed; nil when none has one (tasks from before receipts show nothing, not zeros).
    public init?(_ tasks: [LeadTask]) {
        let receipts = tasks.compactMap { task in task.receipt.map { (task, $0) } }
        guard !receipts.isEmpty else { return nil }
        self.tasks = receipts.count
        worked = receipts.reduce(0) { $0 + ($1.1.worked ?? 0) }
        tokens = receipts.reduce(0) { $0 + $1.1.tokens }
        cost = receipts.compactMap { $0.1.cost }.reduce(0, +)
        unpriced = receipts.filter { $0.1.cost == nil && $0.1.tokens > 0 }.count
        let priced = receipts.filter { $0.1.cost != nil }
        let top = priced.max { $0.1.cost! < $1.1.cost! } ?? receipts.max { $0.1.tokens < $1.1.tokens }
        if let (task, receipt) = top, receipt.tokens > 0 {
            self.top = task.slug
            topTitle = task.title
            topCost = receipt.cost
            topTokens = receipt.tokens
        }
        pricesAsOf = receipts.map(\.1.pricesAsOf).max() ?? LeadPrices.asOf
    }

    /// "4 tasks, 6.2 h of worker time, 61.3M tokens, est. $38.12; most expensive: Every task gets a receipt (est. $14.80)".
    public var text: String {
        var parts = ["\(tasks) task\(tasks == 1 ? "" : "s")", "\(LeadTeams.hours(worked)) of worker time", "\(LeadReceipt.count(tokens)) tokens"]
        if unpriced == tasks {
            parts.append("cost unknown")
        } else {
            parts.append("est. \(LeadReceipt.dollars(cost))" + (unpriced > 0 ? " (+ \(unpriced) task\(unpriced == 1 ? "" : "s") of unknown cost)" : ""))
        }
        var text = parts.joined(separator: ", ")
        if let topTitle {
            text += "; most expensive: \(topTitle) (" + (topCost.map { "est. \(LeadReceipt.dollars($0))" } ?? "\(LeadReceipt.count(topTokens ?? 0)) tokens") + ")"
        }
        return text
    }

    /// The tasks whose receipts status and the scorecard sum: those finished since the last all-done card; with none
    /// since, the last card's batch. `last`: the card's time when it's the last card's.
    public static func current(_ board: LeadBoard) -> (totals: LeadReceiptTotals, last: Double?)? {
        if let open = LeadReceiptTotals(BatchSummary.batch(board)) { return (open, nil) }
        guard let mark = board.allDone?.last else { return nil }
        let slugs = Set(mark.tasks.map(\.slug))
        let held = board.tasks.filter { slugs.contains($0.slug) }
        // Some of its tasks archived (`BoardStore.archive`): the sums the card kept when it was made.
        guard held.count == slugs.count else { return mark.receipts.map { ($0, mark.at) } }
        return LeadReceiptTotals(held).map { ($0, mark.at) }
    }

    /// "Receipts (this batch): …" or "Receipts (last batch, all done at 14:02): …"; nil when there are none.
    public static func line(_ board: LeadBoard) -> String? {
        guard let (totals, last) = current(board) else { return nil }
        return "Receipts (" + (last.map { "last batch, all done at \(LeadBoard.clock($0))" } ?? "this batch") + "; costs are estimates at prices of \(totals.pricesAsOf)): " + totals.text + "."
    }
}
