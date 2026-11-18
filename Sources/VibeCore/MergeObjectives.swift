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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let from = now.addingTimeInterval(-Double(Self.days) * 86_400)
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
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var samples: [MergeSample] = []
        // The window's local days, and one more each side: a line is filed under the local day its run started.
        for back in -1...(days + 1) {
            let name = LoadStats.fileName("merges", for: now.addingTimeInterval(-Double(back) * 86_400))
            guard let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else { continue }
            samples += text.split(separator: "\n").compactMap { try? decoder.decode(MergeSample.self, from: Data($0.utf8)) }
        }
        return MergeObjectives(samples, project: project, now: now)
    }

    /// Whether more runs passed only on their rerun than the objective allows.
    public var rerunsMissed: Bool { runs > 0 && Double(passedOnRerun) > Self.rerunShare * Double(runs) }
    /// Whether the calm-Mac median is over its objective; false with no calm run to judge it by.
    public var calmMissed: Bool { calmMedianS.map { $0 > Self.calmMedian } ?? false }
    public var missed: Bool { rerunsMissed || calmMissed }

    /// "18% passed only on rerun (16 of 89; objective 5%)".
    public var rerunText: String {
        let share = runs == 0 ? 0 : (100 * Double(passedOnRerun) / Double(runs)).rounded()
        return "\(Int(share))% passed only on rerun (\(passedOnRerun) of \(runs); objective \(Int(Self.rerunShare * 100))%)"
    }

    /// "median calm-Mac merge 17.0 min (23 runs; objective 10)", or that no run was on a calm Mac.
    public var calmText: String {
        guard let calmMedianS else { return "no merge ran on a calm Mac (objective: median \(Int(Self.calmMedian / 60)) min)" }
        return "median calm-Mac merge \(String(format: "%.1f", calmMedianS / 60)) min (\(calmRuns) run\(calmRuns == 1 ? "" : "s"); objective \(Int(Self.calmMedian / 60)))"
    }

    /// The lead's status line: both figures with their n and what to do while one is missed, a short "met" when both
    /// are; nil when no run in the window recorded a first run.
    public var statusLine: String? {
        guard runs > 0 else { return nil }
        guard missed else { return "Merge objectives (last \(Self.days) days): met." }
        return "Merge objectives (last \(Self.days) days): \(rerunText), \(calmText): missed, plan test and flake fixes first."
    }
}
