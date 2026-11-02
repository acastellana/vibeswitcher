import Foundation

// Compared with working solo: what VibeSwitcher's process (a lead planning, verifiers auditing, merges tested and
// rerun, attempts re-rolled) adds and costs against one plain Claude Code or Codex session per task. Every figure is
// an estimate, never a measurement: nothing is replayed or run solo to compare against (the user chose estimates
// only, 2026-11-02). Each is worked out once, here, from `QualityFigures` (so over the same merges, split the same way
// by Claude and Codex), and says the assumption it rests on. One whose inputs aren't recorded is nil ("Not recorded"),
// never a guess.

/// What the process costs on top of the solo baseline, over the merges it can be worked out for.
public struct ProcessCost: Equatable, Sendable {
    /// The merges it's worked out over (`QualityFigures.soloMerges`).
    public var merges: Int
    /// Their workers' cost: what one plain session per task would have cost.
    public var solo: Double
    /// Their verifiers' (and finders') cost.
    public var verifiers: Double
    /// The baseline merges' share of the project lead's cost on the range's days (spread evenly over the range's
    /// merges); nil when not recorded, or for one agent's merges (the lead isn't split by agent).
    public var lead: Double?
    /// The lead's cost on the range's days, whole, and the range's merges it's spread over.
    public var leadWhole: Double?
    public var merged: Int
    /// The lead's days with a model that has no price, or days its ledger doesn't cover: their cost isn't in `lead`.
    public var leadUnpricedDays: Int
    public var leadPartial: Bool
    /// Of `merges`, those whose merge's tests were rerun: what the reruns cost isn't recorded.
    public var reran: Int
    /// Merges with a known cost left out: re-rolled (their attempts' worker tokens aren't split, so their re-rolled
    /// attempts' cost isn't recorded either), and Codex's (no price).
    public var rerolledLeftOut: Int
    public var codexLeftOut: Int

    /// The process's part: verifiers and the lead (merge reruns and re-rolled attempts not recorded).
    public var process: Double { verifiers + (lead ?? 0) }
    public var total: Double { solo + process }
    /// The process's share of the total, 0…1.
    public var share: Double? { total > 0 ? process / total : nil }
    /// A part of the process's cost isn't recorded (the lead's, a priced day of it, a merge rerun's, a re-rolled
    /// attempt's): the real share is at least `share`.
    public var atLeast: Bool { lead == nil || leadUnpricedDays > 0 || leadPartial || reran > 0 || rerolledLeftOut > 0 }
}

extension QualityFigures {
    // MARK: (1) What it costs

    /// Process cost: the share of the total that isn't the implementing worker's. Assumes a plain session per task
    /// would have spent what the worker of the attempt that merged spent, and nothing else: the merges whose cost is
    /// known, not re-rolled (their workers' tokens aren't split by attempt) and not worked by Codex (its tokens have no
    /// price) are the baseline; their verifiers' cost and their share of the lead's are the process's. The lead's
    /// tokens aren't kept by task, so its cost on the range's days (tasks that didn't merge included) is taken as
    /// spread evenly over the range's merges, and the baseline merges carry their count's share of it. Merge reruns,
    /// re-rolled attempts and the lead's unpriced or unrecorded days aren't priced, so the share is a lower bound when
    /// any happened. Nil when no merge fits the baseline.
    public var processCost: ProcessCost? {
        guard soloMerges > 0, merged > 0 else { return nil }
        let share = lead?.cost.map { $0 * Double(soloMerges) / Double(merged) }
        return ProcessCost(merges: soloMerges, solo: soloWorkerCost, verifiers: soloVerifierCost, lead: share, leadWhole: lead?.cost,
                           merged: merged, leadUnpricedDays: lead?.unpricedDays ?? 0, leadPartial: lead?.partial ?? false, reran: soloReran,
                           rerolledLeftOut: rerolledLeftOut, codexLeftOut: codexLeftOut)
    }

    // MARK: (2) What it caught before merge, per 100 merged tasks

    /// Important findings the audits raised that a later audit saw fixed, per 100 merges whose audits are kept.
    /// Assumes a solo session would have shipped each of them: none would have been caught before merge. Nil when no
    /// merge's audits are kept.
    public var importantFixedPer100: Double? { Self.per100(importantFixed, auditsKept) }

    /// Merges whose first test run failed and were sent back to their worker (not flakes: those passed on the rerun),
    /// per 100 merges the merges recorder saw. Assumes a solo session would have merged without that test run. Nil
    /// when the recorder saw none of the merges.
    public var sentBackPer100: Double? { Self.per100(sentBack, mergeFirstTry?.counted ?? 0) }

    /// Flaky tests a merge's rerun caught (the flake ledger's entries in the range), per 100 merged tasks. Assumes a
    /// solo session would have shrugged each off or been blocked by it, with nothing to plan a fix from. Nil when no
    /// project keeps a flake ledger, or nothing merged.
    public var flakesCaughtPer100: Double? { flakesCaught.flatMap { Self.per100($0, merged) } }

    // MARK: (3) What escaped after merge, per 100 merged tasks (beside what it caught)

    /// Merges since reverted, per 100 merged tasks: what the process missed. Nil when nothing merged.
    public var revertsPer100: Double? { Self.per100(reverts, merged) }

    /// Merges named by an incident recorded after they merged, per 100 merged tasks. The lead records incidents
    /// (incidents.md, made on the first): a project without the file has had none. Nil when nothing merged.
    public var incidentsPer100: Double? { Self.per100(incidents, merged) }

    // MARK: (4) Parallel time saved

    /// Hours of work per hour: the workers' hours over the wall-clock hours with a task under way (`parallelism`).
    /// Assumes a solo session works one task at a time, an hour of work an hour; a task counts as under way from its
    /// receipt's start to its end, audits and merges included, so this understates the workers' overlap. Nil when no
    /// receipt with a start ended in the range.
    public var hoursOfWorkPerHour: Double? { parallelism }

    // MARK: (5) Your time

    /// The worker hours a merged task took, over the merges whose working time is known; nil when none's is.
    public var workerHoursPerMergedTask: Double? { timed > 0 ? timedWorked / 3600 / Double(timed) : nil }

    /// Hands-off work per minute of yours: a merged task's worker minutes over your minutes per merged task
    /// (`userMinutesPerMergedTask`). Assumes the time a question waited on your answer is the attention you gave it
    /// (an overestimate: you weren't watching all of it), and that a solo session would have needed you for every
    /// minute it worked. Nil when either isn't known, or no question waited on you (no minute to divide by).
    public var handsOffMinutesPerUserMinute: Double? {
        guard let work = workerHoursPerMergedTask, let yours = userMinutesPerMergedTask, yours > 0 else { return nil }
        return work * 60 / yours
    }

    static func per100(_ count: Int, _ over: Int) -> Double? { over > 0 ? Double(count) * 100 / Double(over) : nil }
}
