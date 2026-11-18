import Foundation

/// A project's merge gate against its two objectives over a rolling week (the error budget of
/// docs/process/reviews/books-patterns.md, shortlist 1): at most `rerunShare` of the merge runs pass only on their rerun
/// (that's the noise; a run that fails twice and sends its branch back is the gate working), and the median merge on a
/// calm Mac takes `calmMedian` or less. While either is missed the lead plans test and flake fixes ahead of features
/// (`LeadPrompts.lead`); its status says so (`statusLine`), and the weekly scorecard shows the same two figures.
///
/// Counted from the Mac's merge stats (`MergeSample`, one line a merge in `merges-<day>.jsonl`), this project's lines
/// only, and of those the ones that record a first run: a conflict or an error ran no tests and says nothing of either.
public struct MergeObjectives: Equatable, Sendable {
    /// The window, in days back from now.
    public static let days = 7
    /// The share of runs that may pass only on their rerun.
    public static let rerunShare = 0.05
    /// A merge ran on a calm Mac when the 1-minute load at its start was at most this.
    public static let calmLoad = 6.0
    /// The median a calm-Mac merge may take, in seconds.
    public static let calmMedian = 600.0

    /// The runs that record a first run, and those of them that passed only on their rerun.
    public var runs: Int
    public var passedOnRerun: Int
    /// The calm-Mac runs among them, and their median duration in seconds (nil with none).
    public var calmRuns: Int
    public var calmMedianS: Double?

    public init(runs: Int, passedOnRerun: Int, calmRuns: Int, calmMedianS: Double?) {
        self.runs = runs
        self.passedOnRerun = passedOnRerun
        self.calmRuns = calmRuns
        self.calmMedianS = calmMedianS
    }

    /// `project`'s figures from `samples` (any project's, any day's): the lines started in the `days` days up to `now`.
    /// A line whose stamp can't be read isn't counted.
    public init(_ samples: [MergeSample], project: String, now: Date = Date()) {
        self.init(samples, project: project, after: now.addingTimeInterval(-Double(Self.days) * 86_400), upTo: now)
    }

    /// `project`'s figures from the lines in `samples` started after `after` and up to `upTo` (the scorecard's weeks).
    public init(_ samples: [MergeSample], project: String, after from: Date, upTo now: Date) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let counted = samples.filter { sample in
            guard sample.project == project, sample.firstRun != nil, let at = formatter.date(from: sample.t) else { return false }
            return at > from && at <= now
        }
        let calm = counted.filter { ($0.load.first ?? .infinity) <= Self.calmLoad }.map { Double($0.durationS) }.sorted()
        let median = calm.isEmpty ? nil : calm.count % 2 == 1 ? calm[calm.count / 2] : (calm[calm.count / 2 - 1] + calm[calm.count / 2]) / 2
        self.init(runs: counted.count, passedOnRerun: counted.filter { $0.result == "passed_on_rerun" }.count,
                  calmRuns: calm.count, calmMedianS: median)
    }

    /// `project`'s figures from the merge stats kept in `folder` (`VibePaths.statsDir`); a line that isn't a merge's is skipped.
    public static func read(_ folder: URL, project: String, now: Date = Date()) -> MergeObjectives {
        MergeObjectives(samples(folder, from: now.addingTimeInterval(-Double(days) * 86_400), to: now), project: project, now: now)
    }

    /// Every project's merge lines kept in `folder` for the local days from `from` to `to`, and one more each side (a
    /// line is filed under the local day its run started); a line that isn't a merge's is skipped.
    public static func samples(_ folder: URL, from: Date, to: Date) -> [MergeSample] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var samples: [MergeSample] = []
        let back = Int((max(0, to.timeIntervalSince(from)) / 86_400).rounded(.up))
        for day in -1...(back + 1) {
            let name = LoadStats.fileName("merges", for: to.addingTimeInterval(-Double(day) * 86_400))
            guard let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else { continue }
            samples += text.split(separator: "\n").compactMap { try? decoder.decode(MergeSample.self, from: Data($0.utf8)) }
        }
        return samples
    }

    /// The runs the rerun objective is judged from at least: below it one flaky run would read as a miss.
    public static let minimumRuns = 10

    /// Enough runs to judge the rerun objective by (`minimumRuns`).
    public var rerunsJudged: Bool { runs >= Self.minimumRuns }
    /// Whether more runs passed only on their rerun than the objective allows; false with too few runs to judge.
    public var rerunsMissed: Bool { rerunsJudged && Double(passedOnRerun) > Self.rerunShare * Double(runs) }
    /// Whether the calm-Mac median is over its objective; false with no calm run to judge it by.
    public var calmMissed: Bool { calmMedianS.map { $0 > Self.calmMedian } ?? false }
    public var missed: Bool { rerunsMissed || calmMissed }

    /// The share passed only on rerun, in percent; nil with no run.
    public var rerunPercent: Double? { runs == 0 ? nil : 100 * Double(passedOnRerun) / Double(runs) }

    /// "18%", "5.5%": a whole percent from 10% up, one decimal below it (where the objective is), two when one would
    /// read as the objective itself while the share isn't (5.04% isn't "5.0%", met or not).
    public static func percent(_ value: Double) -> String {
        if value >= 10 { return "\(Int(value.rounded()))%" }
        let objective = rerunShare * 100
        let one = String(format: "%.1f", value)
        if one == String(format: "%.1f", objective), abs(value - objective) > 1e-9 { return String(format: "%.2f", value) + "%" }
        return one + "%"
    }

    /// "18% passed only on rerun (16 of 89; objective 5%)", "100% passed only on rerun (1 of 1; objective 5%, too few
    /// runs to judge)".
    public var rerunText: String {
        "\(Self.percent(rerunPercent ?? 0)) passed only on rerun (\(passedOnRerun) of \(runs); objective \(Int(Self.rerunShare * 100))%"
            + (rerunsJudged ? ")" : ", too few runs to judge)")
    }

    /// "median calm-Mac merge 17.0 min (23 runs; objective 10)", or that no run was on a calm Mac.
    public var calmText: String {
        guard let calmMedianS else { return "no merge ran on a calm Mac (objective: median \(Int(Self.calmMedian / 60)) min)" }
        return "median calm-Mac merge \(String(format: "%.1f", calmMedianS / 60)) min (\(calmRuns) run\(calmRuns == 1 ? "" : "s"); objective \(Int(Self.calmMedian / 60)))"
    }

    /// The lead's status line: both figures with their n and what to do while one is missed, a short "met" when both
    /// are; with too few runs to judge the reruns and the median met, the figures alone. Nil when no run in the window
    /// recorded a first run.
    public var statusLine: String? {
        guard runs > 0 else { return nil }
        let head = "Merge objectives (last \(Self.days) days): "
        if missed { return head + "\(rerunText), \(calmText): missed, plan test and flake fixes first." }
        return rerunsJudged ? head + "met." : head + "\(rerunText), \(calmText)."
    }
}
