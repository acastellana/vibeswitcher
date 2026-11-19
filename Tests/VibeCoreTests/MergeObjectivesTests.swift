import Foundation
import Testing
@testable import VibeCore

/// The merge gate's error budget (`MergeObjectives`, docs/process/reviews/books-patterns.md shortlist 1, 2 and 8): the
/// two figures counted from the Mac's merge stats, the lead's status line while one is missed, and the three rules the
/// lead's brief carries.
struct MergeObjectivesTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A merge's line: `result` as the recorder writes it, started `hoursAgo` before `now`.
    static func sample(_ result: String, project: String = "proj", hoursAgo: Double = 1, load: Double = 3, minutes: Double = 8,
                       now: Date = MergeObjectivesTests.now) -> MergeSample {
        let firstRun: String? = switch result {
        case "passed": "passed"
        case "conflict", "error": nil
        default: "failed"
        }
        return MergeSample(t: LoadStats.stamp(now.addingTimeInterval(-hoursAgo * 3600)), project: project, task: "t", load: [load, load, load],
                           waitedS: 0, slotWaitS: 0, durationS: Int(minutes * 60), firstRun: firstRun,
                           reran: result == "passed" ? nil : [], rerunWhole: result == "passed" ? nil : true, result: result)
    }

    /// The week the review counted: 89 runs that record a first run, 16 of them passing only on their rerun.
    static func reviewWeek(now: Date = MergeObjectivesTests.now) -> [MergeSample] {
        (0..<65).map { _ in sample("passed", load: 20, minutes: 30, now: now) }
            + (0..<16).map { _ in sample("passed_on_rerun", load: 20, minutes: 40, now: now) }
            + (0..<8).map { _ in sample("failed", load: 4, minutes: 17, now: now) }
            + (0..<7).map { _ in sample("conflict", load: 2, minutes: 0.1, now: now) }
    }

    @Test func theFiguresCountThisProjectsRunsThatRecordAFirstRun() {
        let samples = Self.reviewWeek()
            + [Self.sample("passed_on_rerun", project: "other"), Self.sample("passed_on_rerun", hoursAgo: 8 * 24)]
        let objectives = MergeObjectives(samples, project: "proj", now: Self.now)
        // Not the 7 conflicts (no first run), the other project's, or the one from 8 days ago.
        #expect(objectives == MergeObjectives(runs: 89, passedOnRerun: 16, calmRuns: 8, calmMedianS: 17 * 60))
        #expect(objectives.rerunsMissed && objectives.calmMissed && objectives.missed)
        #expect(objectives.statusLine == "Merge objectives (last 7 days): 18% passed only on rerun (16 of 89; objective 5%), "
            + "median calm-Mac merge 17.0 min (8 runs; objective 10): missed, plan test and flake fixes first.")
    }

    /// Calm is a 1-minute load of at most 6, and the median of an even count is the middle two's mean.
    @Test func calmIsALoadOfAtMostSixAndTheMedianIsTheMiddle() {
        let samples = [Self.sample("passed", load: 6, minutes: 8), Self.sample("passed", load: 5.9, minutes: 11),
                       Self.sample("passed", load: 6.01, minutes: 50), Self.sample("passed", load: 40, minutes: 60)]
        let objectives = MergeObjectives(samples, project: "proj", now: Self.now)
        #expect(objectives.calmRuns == 2 && objectives.calmMedianS == 9.5 * 60)
        #expect(!objectives.missed)
        // Four runs are too few to judge the reruns: the figures, no verdict.
        #expect(objectives.statusLine == "Merge objectives (last 7 days): 0.0% passed only on rerun (0 of 4; objective 5%, too few runs to judge), "
            + "median calm-Mac merge 9.5 min (2 runs; objective 10).")
    }

    /// Each objective alone misses: exactly 5% on rerun is met, one more isn't; 10 minutes is met, over it isn't.
    @Test func eitherObjectiveAloneIsAMiss() {
        let atLimit = (0..<19).map { _ in Self.sample("passed") } + [Self.sample("passed_on_rerun", minutes: 10)]
        #expect(!MergeObjectives(atLimit, project: "proj", now: Self.now).missed)
        let noisy = MergeObjectives(atLimit + [Self.sample("passed_on_rerun")], project: "proj", now: Self.now)
        #expect(noisy.rerunsMissed && !noisy.calmMissed)
        #expect(noisy.statusLine?.contains("9.5% passed only on rerun (2 of 21; objective 5%)") == true && noisy.statusLine?.hasSuffix("missed, plan test and flake fixes first.") == true)
        let slow = MergeObjectives([Self.sample("passed", minutes: 10.5)], project: "proj", now: Self.now)
        #expect(slow.calmMissed && !slow.rerunsMissed)
        #expect(slow.statusLine?.contains("0.0% passed only on rerun (0 of 1; objective 5%, too few runs to judge), median calm-Mac merge 10.5 min (1 run; objective 10): missed") == true)
    }

    /// No run on a calm Mac: the median isn't judged, and the line says so when the reruns miss.
    @Test func withNoCalmRunOnlyTheRerunsAreJudged() {
        let passed = (0..<9).map { _ in Self.sample("passed", load: 30, minutes: 40) }
        let busy = passed + [Self.sample("passed_on_rerun", load: 30, minutes: 40)]
        let objectives = MergeObjectives(busy, project: "proj", now: Self.now)
        #expect(objectives.calmMedianS == nil && !objectives.calmMissed && objectives.rerunsMissed)
        #expect(objectives.statusLine == "Merge objectives (last 7 days): 10% passed only on rerun (1 of 10; objective 5%), "
            + "no merge ran on a calm Mac (objective: median 10 min): missed, plan test and flake fixes first.")
        #expect(MergeObjectives(passed + [Self.sample("passed", load: 30)], project: "proj", now: Self.now).statusLine == "Merge objectives (last 7 days): met.")
    }

    /// Audit nit 1: the reruns are judged from `minimumRuns` runs; below that one flaky run isn't a miss.
    @Test func tooFewRunsToJudgeTheReruns() {
        let one = MergeObjectives([Self.sample("passed_on_rerun")], project: "proj", now: Self.now)
        #expect(!one.rerunsJudged && !one.rerunsMissed && !one.missed)
        #expect(one.statusLine == "Merge objectives (last 7 days): 100% passed only on rerun (1 of 1; objective 5%, too few runs to judge), "
            + "median calm-Mac merge 8.0 min (1 run; objective 10).")
        let nine = MergeObjectives((0..<9).map { _ in Self.sample("passed_on_rerun") }, project: "proj", now: Self.now)
        #expect(!nine.rerunsMissed && nine.rerunText.hasSuffix("too few runs to judge)"))
        let ten = MergeObjectives((0..<9).map { _ in Self.sample("passed") } + [Self.sample("passed_on_rerun")], project: "proj", now: Self.now)
        #expect(ten.rerunsJudged && ten.rerunsMissed && ten.rerunText == "10% passed only on rerun (1 of 10; objective 5%)")
        // A calm-Mac median over its objective is still a miss with few runs.
        #expect(MergeObjectives([Self.sample("passed_on_rerun", minutes: 12)], project: "proj", now: Self.now).missed)
    }

    /// Audit nit 2: under 10% the share has one decimal, so a miss never prints as the objective (3 of 55: 5.5%).
    @Test func aShareUnderTenPercentHasADecimal() {
        let samples = (0..<52).map { _ in Self.sample("passed") } + (0..<3).map { _ in Self.sample("passed_on_rerun") }
        let objectives = MergeObjectives(samples, project: "proj", now: Self.now)
        #expect(objectives.rerunsMissed)
        #expect(objectives.statusLine?.contains("5.5% passed only on rerun (3 of 55; objective 5%), ") == true, "\(objectives.statusLine ?? "")")
        #expect(MergeObjectives.percent(18.0) == "18%" && MergeObjectives.percent(9.96) == "10.0%" && MergeObjectives.percent(0) == "0.0%")
        #expect(MergeObjectives.percent(5) == "5.0%" && MergeObjectives.percent(5.04) == "5.04%" && MergeObjectives.percent(4.98) == "4.98%")
    }

    @Test func noRunsSayNothing() {
        #expect(MergeObjectives([Self.sample("conflict"), Self.sample("passed", project: "other")], project: "proj", now: Self.now).statusLine == nil)
    }

    /// Read from merges-<day>.jsonl as the recorder writes them: the week's days, lines that aren't merges skipped.
    @Test func theStatsFolderIsReadForTheWeeksDays() throws {
        let folder = temp.url("stats")
        for sample in Self.reviewWeek() + [Self.sample("passed_on_rerun", hoursAgo: 6 * 24 + 23), Self.sample("passed_on_rerun", hoursAgo: 7 * 24 + 1),
                                           Self.sample("passed_on_rerun", project: "other")] {
            let at = try #require(ISO8601DateFormatter().date(from: sample.t))
            try sample.append(in: folder, at: at)
        }
        try LoadStats.append("not json", to: LoadStats.fileName("merges", for: Self.now), in: folder)
        let objectives = MergeObjectives.read(folder, project: "proj", now: Self.now)
        #expect(objectives.runs == 90 && objectives.passedOnRerun == 17, "\(objectives)")
        #expect(MergeObjectives.read(temp.url("none"), project: "proj", now: Self.now).statusLine == nil)
    }

    func project() throws -> String {
        let url = temp.url("proj")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    /// status tells the lead while an objective is missed, says "met" in a short line when both are, and nothing
    /// with no merge stats.
    @Test func statusSaysWhenAnObjectiveIsMissed() throws {
        let root = try project()
        let lead = try lead(root, FakeRuntime())
        let stats = temp.url("lead-stats")
        lead.mergeStats = { stats }
        #expect(!lead.call("status", [:]).text.contains("Merge objectives"))

        // The project is its folder's name, as merge records it.
        let name = (root as NSString).lastPathComponent
        let now = Date()
        for sample in [Self.sample("passed", project: name, now: now), Self.sample("passed", project: "other", load: 2, minutes: 90, now: now)] {
            try sample.append(in: stats, at: now)
        }
        #expect(lead.call("status", [:]).text.contains("\nMerge objectives (last 7 days): 0.0% passed only on rerun (0 of 1; objective 5%, "
            + "too few runs to judge), median calm-Mac merge 8.0 min (1 run; objective 10).\n"))

        for var sample in Self.reviewWeek(now: now) {
            sample.project = name
            try sample.append(in: stats, at: now)
        }
        let status = lead.call("status", [:]).text
        #expect(status.contains("\nMerge objectives (last 7 days): 18% passed only on rerun (16 of 90; objective 5%), "
            + "median calm-Mac merge 17.0 min (9 runs; objective 10): missed, plan test and flake fixes first.\n"), "\(status)")

        lead.mergeStats = { nil }
        #expect(!lead.call("status", [:]).text.contains("Merge objectives"))
    }

    // MARK: the lead's brief

    static let prompt = LeadPrompts.lead(project: "p", root: "/r", workflow: LeadWorkflow(), policy: "", limits: MacLimits())

    /// The numbered step of the lead's brief that starts with "\(number). ", up to the next step.
    static func step(_ number: Int) throws -> String {
        let start = try #require(prompt.range(of: "\n\(number). "))
        let end = prompt.range(of: "\n\(number + 1). ", range: start.upperBound..<prompt.endIndex)?.lowerBound
            ?? prompt.range(of: "\n\n", range: start.upperBound..<prompt.endIndex)?.lowerBound ?? prompt.endIndex
        return String(prompt[start.upperBound..<end])
    }

    /// The rule of `text` that starts with `opening`, up to the end of its line.
    static func rule(_ opening: String, in text: String) throws -> String {
        let start = try #require(text.range(of: opening), "no '\(opening)'")
        let rest = text[start.lowerBound...]
        let end = rest.range(of: ".\n")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    /// At most two sentences: a full stop followed by a space and a capital starts another.
    static func sentences(_ rule: String) -> Int { rule.matches(of: #/\.\s+[A-Z]/#).count + 1 }

    @Test func theBriefsPlanningStepHasTheErrorBudget() throws {
        let rule = try Self.rule("Error budget:", in: try Self.step(2))
        for words in ["status says", "last 7 days", "more than 5% of merge runs passing only on a rerun", "calm-Mac median merge over 10 minutes",
                      "the next tasks you plan", "flake ledger's top entries", "failures that name no test", "slowest suites",
                      "ahead of new features", "until both are met"] {
            #expect(rule.contains(words), "missing '\(words)' in: \(rule)")
        }
        #expect(Self.sentences(rule) <= 2, "\(rule)")
    }

    @Test func theBriefsPlanningStepHasTidyFirst() throws {
        let rule = try Self.rule("Tidy first:", in: try Self.step(2))
        for words in ["easier after restructuring", "moving a tool family out of a large file", "extracting a function",
                      "as its own task first", "no behaviour change", "tests unchanged and green", "the behaviour task runs `after` it"] {
            #expect(rule.contains(words), "missing '\(words)' in: \(rule)")
        }
        #expect(Self.sentences(rule) <= 2, "\(rule)")
    }

    @Test func theBriefsRetrospectiveStepLooksForRecurrences() throws {
        let rule = try Self.rule("For each incident since the last retrospective", in: try Self.step(10))
        for words in ["whose check task merged", "look for a recurrence", "incidents.md", "the flake list", "the merge records",
                      "a recurrence becomes an incident of its own", "naming the check that missed it"] {
            #expect(rule.contains(words), "missing '\(words)' in: \(rule)")
        }
        #expect(Self.sentences(rule) <= 2, "\(rule)")
    }

    /// The brief's objectives are the ones status judges by.
    @Test func theBriefsFiguresAreTheObjectives() {
        #expect(MergeObjectives.days == 7 && MergeObjectives.rerunShare == 0.05 && MergeObjectives.calmMedian == 600 && MergeObjectives.calmLoad == 6)
    }
}
