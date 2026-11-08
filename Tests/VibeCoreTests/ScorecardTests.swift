import Foundation
import Testing
@testable import VibeCore

/// The weekly scorecard (backlog A1, small version): add_task's origin and status's count of it by week; the
/// Statistics scorecard's two weeks (origins, questions per delivered task, cost with the lead's share, time to install)
/// from a scratch project's board and lead ledger; and which builds hold a merge, by git.
struct ScorecardTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func date(_ month: Int, _ day: Int, _ hour: Int = 0) -> Double {
        utc.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!.timeIntervalSince1970
    }

    func repo() throws -> String {
        let url = temp.url("lead")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    // MARK: add_task's origin, status's count

    @Test func addTaskTakesAnOriginAndStatusCountsOriginsByWeek() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        let schema = try #require(lead.tools.first { $0.name == "add_task" }?.properties["origin"])
        #expect(schema.options == ["user_report", "incident", "log_watcher", "flake", "audit", "lead", "other"])

        let added = lead.call("add_task", ["title": "Crash on paste", "goal": "g", "acceptance": ["a"], "origin": "user_report"])
        #expect(!added.isError, "\(added.text)")
        _ = lead.call("add_task", ["title": "Flaky timer", "goal": "g", "acceptance": ["a"], "origin": " Flake "])
        _ = lead.call("add_task", ["title": "Plain", "goal": "g", "acceptance": ["a"]])
        let refused = lead.call("add_task", ["title": "Bad", "goal": "g", "acceptance": ["a"], "origin": "customer"])
        #expect(refused.isError && refused.text.contains("origin is one of user_report, incident"), "\(refused.text)")
        let board = BoardStore(root: root).load()
        #expect(board.task("crash-on-paste")?.originKind == .userReport && board.task("flaky-timer")?.origin == "flake")
        #expect(board.task("plain")?.origin == nil && board.task("bad") == nil)

        let status = lead.call("status", [:]).text
        #expect(status.contains("Task origins (by creation; last 7 days): 1 user_report, 1 flake, 1 not said (n = 3)"), "\(status)")
        #expect(status.contains("bugs you reported 1 vs found by the system 1 this week (0 vs 0 the week before)"), "\(status)")
    }

    @Test func originsAreCountedByCreationWeekAnUnknownOneAsOther() {
        let now = Self.date(11, 8, 12)
        func task(_ slug: String, _ created: Double, _ origin: String?, removed: Bool = false) -> LeadTask {
            var task = LeadTask(slug: slug, title: slug, contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""))
            task.createdAt = created
            task.origin = origin
            if removed { task.removedAt = created + 1 }
            return task
        }
        let tasks = [task("a", now - 3600, "user_report"), task("b", now - 2 * 86_400, "incident"), task("c", now - 3 * 86_400, "from-the-future"),
                     task("d", now - 8 * 86_400, "audit"), task("e", now - 9 * 86_400, "user_report"), task("f", now - 20 * 86_400, "log_watcher"),
                     task("g", now - 3600, "flake", removed: true)]
        let line = LeadOrigins.statusLine(tasks, now: now)
        #expect(line == "Task origins (by creation; last 7 days): 1 user_report, 1 incident, 1 other (n = 3) · the 7 days before: "
            + "1 user_report, 1 audit (n = 2) · bugs you reported 1 vs found by the system 1 this week (1 vs 1 the week before).", "\(line ?? "nil")")
        #expect(LeadOrigins.statusLine([task("old", now - 30 * 86_400, "lead")], now: now) == nil)
    }

    // MARK: Statistics' scorecard

    /// A merged task as the board keeps it, with a receipt naming the build that ran its merge.
    static func merged(_ slug: String, created: Double, at: Double, origin: String?, cost: Double?, build: String?) -> LeadTask {
        var task = LeadTask(id: slug.uppercased(), slug: slug, title: "Task \(slug)", contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""),
                            status: .done)
        task.createdAt = created
        task.startedAt = created + 600
        task.origin = origin
        task.merged = LeadMergeRecord(commit: "c-\(slug)", tested: true, at: at)
        if let cost {
            var tokens = LeadTokens(input: 10, sessions: 1, models: ["claude-opus-5-5"])
            tokens.cost = cost
            var receipt = LeadReceipt(ending: .merged, startedAt: created + 600, endedAt: at, worked: 600, worker: tokens, verifier: nil)
            receipt.build = build
            task.receipt = receipt
        }
        return task
    }

    @Test func theScorecardCountsTwoWeeksSpreadsTheLeadsDailyCostAndTimesInstalls() async throws {
        let root = temp.url("scorecard")
        let project = root.appendingPathComponent("proj"), home = root.appendingPathComponent("home")
        let folder = project.appendingPathComponent(".vibeswitcher")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var board = LeadBoard()
        // This week (Nov 2 – 8): u1 (you reported it), a1 (an audit's finding; its merge ran on a build holding u1's
        // merge), n1 (origin not said, no receipt), i1 (an incident, not merged), and a removed task (never counted).
        let u1 = Self.merged("u1", created: Self.date(11, 3), at: Self.date(11, 4, 10), origin: "user_report", cost: 2, build: "aaaaaaaaaaaa")
        let a1 = Self.merged("a1", created: Self.date(11, 3, 6), at: Self.date(11, 4, 14), origin: "audit", cost: 4,
                             build: "bbbbbbbbbbbb with changes not committed")
        let n1 = Self.merged("n1", created: Self.date(11, 5), at: Self.date(11, 6, 9), origin: nil, cost: nil, build: nil)
        var i1 = LeadTask(id: "I1", slug: "i1", title: "Incident", contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""))
        i1.createdAt = Self.date(11, 5, 3)
        i1.origin = "incident"
        var gone = i1
        gone.id = "GONE"
        gone.slug = "gone"
        gone.origin = "flake"
        gone.removedAt = Self.date(11, 5, 4)
        // The week before (Oct 26 – Nov 1): p1, reported by you.
        let p1 = Self.merged("p1", created: Self.date(10, 28), at: Self.date(10, 29, 12), origin: "user_report", cost: 1, build: "cccccccccccc")
        board.tasks = [u1, a1, n1, i1, gone, p1]
        // A question about u1 that waited 30 minutes on the user.
        var question = LeadQuestion(text: "Which?", options: ["a", "b"], at: Self.date(11, 3, 12))
        question.task = "u1"
        question.answeredAt = Self.date(11, 3, 12) + 1800
        board.questions = [question]
        try JSONEncoder().encode(board).write(to: folder.appendingPathComponent("board.json"))
        // The lead's days: Nov 4 (two merges: spread), Nov 5 (none: not spread), Nov 6 (n1's), Nov 7 (a model with no price).
        func day(_ cost: Double, unpriced: Bool = false) -> [String: Any] {
            var day: [String: Any] = ["input": 100, "output": 10, "cacheRead": 0, "cacheWrite": 0, "cacheWrite1h": 0, "cost": cost, "models": [:], "sessions": []]
            if unpriced { day["unpriced"] = ["x"] }
            return day
        }
        let ledger: [String: Any] = ["since": Self.date(10, 1), "at": Self.date(11, 8), "files": [:],
                                     "days": ["2026-11-04": day(3), "2026-11-05": day(1), "2026-11-06": day(0.6), "2026-11-07": day(0, unpriced: true),
                                              "2026-10-29": day(0.5)]]
        try JSONSerialization.data(withJSONObject: ledger).write(to: folder.appendingPathComponent("lead-tokens.json"))

        let now = Date(timeIntervalSince1970: Self.date(11, 8, 12))
        let collector = SetupStatsCollector(home: home, codexHome: nil, calendar: Self.utc, now: { now })
        // Only build bbbbbbbbbbbb holds u1's merge commit.
        let asked = Asked()
        collector.installsReader = { _, _ in
            { build, commit in
                asked.add(build + " " + commit)
                return build == "bbbbbbbbbbbb" && commit == "c-u1"
            }
        }
        let range = DateInterval(start: Date(timeIntervalSince1970: Self.date(11, 2)), end: Date(timeIntervalSince1970: Self.date(11, 9)))
        let stats = await collector.collect(projects: [project.path], range: range)
        let card = try #require(stats.quality?.scorecard)
        let week = card.week, before = card.previous
        #expect(week.start.timeIntervalSince1970 == Self.date(11, 2) && before.start.timeIntervalSince1970 == Self.date(10, 26))

        #expect(week.origins == LeadOrigins(counts: [.userReport: 1, .audit: 1, .incident: 1], unsaid: 1))
        #expect(week.origins.userReported == 1 && week.origins.systemFound == 2 && week.origins.total == 4)
        #expect(before.origins == LeadOrigins(counts: [.userReport: 1]))

        #expect(week.merged == 3 && week.questions == 1 && abs((week.questionsPerTask ?? 0) - 1.0 / 3) < 1e-9)
        #expect(abs((week.userMinutesPerTask ?? 0) - 10) < 1e-9, "\(String(describing: week.userMinutesPerTask))")
        #expect(before.merged == 1 && before.questions == 0)

        // Receipts: $6 over 2 costed merges; the lead's $3 + $0.60 on merge days over 3 merges; $1 on Nov 5 not spread.
        #expect(week.costed == 2 && week.cost == 6 && week.receiptCostPerTask == 3)
        #expect(abs(week.leadSpread - 3.6) < 1e-9 && week.leadUnspread == 1 && week.leadUnpricedDays == 1 && week.leadKept)
        #expect(abs((week.costPerTask ?? 0) - 4.2) < 1e-9, "\(String(describing: week.costPerTask))")
        #expect(abs((before.costPerTask ?? 0) - 1.5) < 1e-9)
        // Receipts themselves carry no lead share.
        #expect(stats.quality?.all.cost == 6)

        // u1 was first seen installed when a1 merged on a build holding it; a1 and n1 aren't installed yet.
        #expect(week.installTimes == [Self.date(11, 4, 14) - Self.date(11, 3)] && week.notInstalled == 2)
        #expect(card.installs.map(\.slug) == ["n1", "a1", "u1"])
        #expect(card.installs.first { $0.slug == "u1" }?.toInstall == Self.date(11, 4, 14) - Self.date(11, 3))
        #expect(card.installs.first { $0.slug == "a1" }?.installedAt == nil)
        #expect(before.installTimes.isEmpty && before.notInstalled == 1)
        // Each build and merge asked once at most; a build named "unknown …" never.
        #expect(asked.all.count == Set(asked.all).count && !asked.all.isEmpty)
    }

    @Test func aBuildHoldsTheMergesItsHistoryHas() throws {
        let root = try repo()
        let first = Git.run(["rev-parse", "HEAD"], in: root).output.trimmingCharacters(in: .whitespacesAndNewlines)
        try "two\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["commit", "-q", "-am", "second"], in: root)
        let second = Git.run(["rev-parse", "HEAD"], in: root).output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(first.count == 40 && second.count == 40 && first != second)
        let probe = Git.run(["rev-list", String(second.prefix(12)), "--"], in: root)
        #expect(probe.status == 0, "\(probe.error)")
        let contains = SetupInstalls.gitContains(root: root, since: Date().timeIntervalSince1970 - 86_400)
        #expect(contains(String(second.prefix(12)), first) && contains(String(second.prefix(12)), second))
        #expect(!contains(String(first.prefix(12)), second))
        #expect(!contains("0123456789ab", first))

        #expect(SetupInstalls.commit(ofBuild: "3f2a1b4c5d6e") == "3f2a1b4c5d6e")
        #expect(SetupInstalls.commit(ofBuild: "3F2A1B4C5D6E with changes not committed") == "3f2a1b4c5d6e")
        #expect(SetupInstalls.commit(ofBuild: "unknown (no commit recorded)") == nil)
        let found = SetupInstalls.firstInstalls(merges: [(slug: "x", commit: first), (slug: "y", commit: "dead")],
                                                seen: [(build: "unknown (no commit recorded)", at: 5), (build: String(second.prefix(12)), at: 20),
                                                       (build: String(second.prefix(12)), at: 10)],
                                                contains: contains)
        #expect(found == ["x": 10])
    }
}

/// The pairs a fake `installsReader` was asked, from the collector's queue.
final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var pairs: [String] = []
    func add(_ pair: String) { lock.withLock { pairs.append(pair) } }
    var all: [String] { lock.withLock { pairs } }
}
