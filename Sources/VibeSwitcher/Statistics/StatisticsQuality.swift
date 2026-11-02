import Foundation
import VibeCore

/// What the page shows of a `SetupQuality`: four sections of figures (quality, autonomy, where time goes, cost), each
/// with a line on hover saying what it is; the breakdown by who did the work; and the 8-week trend. A figure whose
/// inputs aren't kept reads "Not recorded"; one with nothing to count in the range reads "–".
struct QualityPage: Equatable {
    var sections: [Section]
    var breakdown: [BreakdownRow]
    /// Said under the breakdown when no merge's model is recorded.
    var modelsNote: String?
    var trend: [TrendWeek]

    typealias Figure = StatisticsPage.Figure

    struct Section: Equatable, Identifiable {
        var title: String
        var figures: [Figure]
        var id: String { title }
    }

    /// The breakdown's columns, in order.
    static let columns = ["Merged", "First audit", "Rounds to pass", "Important / audited", "First-try merge", "Questions / task",
                          "Needed nobody", "Median to merge", "Cost / task"]

    /// What each column is, on hover over its title.
    static let columnHelp = [
        "Tasks merged in the range.",
        "The share of the audited merges that passed their first audit (the Team tab's scorecard's definition).",
        "The audits an audited merge took to pass, on average (the scorecard's definition).",
        "Important findings the audits raised, per audited merge.",
        "The share of the merges the merges recorder saw whose first test run passed, with no rerun or send-back.",
        "The lead's questions to you about these merges, per merge.",
        "The share of merges with no question to you, no lead message to the worker after it started, and no re-roll.",
        "Median time from the task's creation to its merge.",
        "Estimated cost (worker and verifier) per merge whose cost is known.",
    ]

    struct BreakdownRow: Equatable, Identifiable {
        var name: String
        /// Indented under Claude: a model's row.
        var model: Bool
        var cells: [String]
        var id: String { name }
        var spoken: String { ([name] + zip(QualityPage.columns, cells).map { "\($0) \($1)" }).joined(separator: ", ") }
    }

    /// One week: its first day, its figures as text, and each bar's height (0–1; nil: no bar).
    struct TrendWeek: Equatable, Identifiable {
        var label: String
        var merged: Int
        var passRate: String
        var passBar: Double?
        var cost: String
        var costBar: Double?
        var id: String { label }
        var spoken: String { "Week of \(label): \(merged) merged, first-audit pass rate \(passRate), cost per merged task \(cost)" }
    }

    init(_ quality: SetupQuality, calendar: Calendar = .current) {
        let all = quality.all
        sections = [Self.quality(all), Self.autonomy(all), Self.time(all), Self.cost(all)]
        breakdown = quality.byAgent.flatMap { group -> [BreakdownRow] in
            let row = BreakdownRow(name: group.name, model: false, cells: Self.cells(group.figures))
            guard group.name == "Claude" else { return [row] }
            return [row] + quality.byModel.map { BreakdownRow(name: $0.name, model: true, cells: Self.cells($0.figures)) }
        }
        modelsNote = quality.byModel.isEmpty ? "Models: \(StatisticsPage.notRecorded) (no merge's worker model is kept)" : nil
        let style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day()
        let costs = quality.weeks.compactMap(\.costPerMergedTask)
        let top = costs.max() ?? 0
        trend = quality.weeks.map { week in
            TrendWeek(label: week.start.formatted(style), merged: week.merged,
                      passRate: week.firstAuditPassRate.map(Self.percent) ?? StatisticsPage.none, passBar: week.firstAuditPassRate,
                      cost: week.costPerMergedTask.map(StatisticsPage.money) ?? StatisticsPage.none,
                      costBar: week.costPerMergedTask.map { top > 0 ? $0 / top : 0 })
        }
    }

    // MARK: Sections

    static let notRecorded = StatisticsPage.notRecorded
    static let none = StatisticsPage.none

    static func quality(_ f: QualityFigures) -> Section {
        let merged = f.merged > 0, audited = f.audited > 0
        let noAudit = merged && !audited ? "no audited merge" : nil
        var figures: [Figure] = []
        let firstPass = f.firstAuditPassRate.map { Int(($0 * Double(f.audited)).rounded()) } ?? 0
        figures.append(Figure(label: "First-audit pass rate", value: f.firstAuditPassRate.map(percent) ?? none,
                              detail: audited ? "\(firstPass) of \(count(f.audited, "audited merge")) passed their first audit" : noAudit,
                              meter: f.firstAuditPassRate.map(share),
                              help: "The share of the audited merges that passed their first audit: the Team tab's scorecard's definition."))
        figures.append(Figure(label: "Audit rounds to pass", value: f.meanRoundsToPass.map { StatisticsPage.number($0) } ?? none,
                              detail: audited ? "mean over \(count(f.audited, "audited merge"))" : noAudit,
                              help: "The audits an audited merge took to pass, on average: the scorecard's definition."))
        figures.append(Figure(label: "Important findings per audited task", value: f.importantPerAudited.map { StatisticsPage.number($0) } ?? none,
                              detail: audited ? "\(f.importantFindings) over \(count(f.audited, "audited merge"))" : noAudit,
                              help: "The Important findings the audits raised and most finders confirmed, per audited merge."))
        if let o = f.findings {
            let parts = [(o.fixed, "fixed by the worker"), (o.disagreementAccepted, "disagreement accepted by the verifier"),
                         (o.dismissedByLead, "dismissed by the lead"), (o.movedToTask, "moved to a task"),
                         (o.dismissedByVerifier, "dismissed by the verifier"), (o.leftOpen, "left open (Nits, Pre-existing)")]
            figures.append(Figure(label: "What became of findings", value: o.total == 0 ? "none raised" : count(o.total, "finding"),
                                  detail: o.total == 0 ? nil : parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · "),
                                  help: "Every finding the merges' audits raised (\(o.important) Important), by how it ended: fixed and seen fixed by "
                                      + "a later audit, dismissed after the worker disagreed, dismissed by the lead, turned into a task, or still open."))
        } else {
            figures.append(Figure(label: "What became of findings", value: merged ? notRecorded : none,
                                  detail: merged ? "no merge's audits are kept" : nil,
                                  help: "Every finding the merges' audits raised, by how it ended."))
        }
        if let runs = f.mergeFirstTry {
            figures.append(Figure(label: "Merge first try", value: runs.rate.map(percent) ?? none,
                                  detail: "\(runs.firstTry) of \(count(runs.counted, "merge")) the merges recorder saw", meter: runs.rate.map(share),
                                  help: "The share of merges whose first test run passed, with no rerun, failure, conflict or send-back before it landed "
                                      + "(the Mac's merges recorder, from 14 days before the range)."))
        } else {
            figures.append(Figure(label: "Merge first try", value: merged ? notRecorded : none, detail: merged ? "the merges recorder saw none of them" : nil,
                                  help: "The share of merges whose first test run passed, with no rerun or send-back."))
        }
        figures.append(Figure(label: "Re-rolls", value: "\(f.rerolls)",
                              help: "Times a merged task was started again from the base after failed audit rounds."))
        figures.append(Figure(label: "Reverts", value: "\(f.reverts)", help: "Merges the base later reverted: the scorecard's definition."))
        figures.append(Figure(label: "Escapes", value: "\(f.escapes)", detail: "reverted, or named by a later incident",
                              help: "Merges that let a problem through: reverted since, or named by an incident recorded after they merged."))
        return Section(title: "Quality", figures: figures)
    }

    static func autonomy(_ f: QualityFigures) -> Section {
        let merged = f.merged > 0
        return Section(title: "Autonomy", figures: [
            Figure(label: "Questions to you per merged task", value: f.questionsPerMergedTask.map { StatisticsPage.number($0, digits: 2) } ?? none,
                   detail: merged ? "\(count(f.questions, "question")) over \(count(f.merged, "merge"))" : nil,
                   help: "The lead's questions to you about the merged tasks, and those about no task asked in the range, per merged task."),
            Figure(label: "Your wait per merged task", value: f.userMinutesPerMergedTask.map { "\(StatisticsPage.number($0)) min" } ?? none,
                   help: "The minutes those questions waited on your answer, per merged task: the scorecard's definition."),
            Figure(label: "Needed nobody", value: f.neededNobodyShare.map(percent) ?? none,
                   detail: merged ? "\(f.neededNobody) of \(count(f.merged, "merge"))" : nil, meter: f.neededNobodyShare.map(share),
                   help: "The share of merged tasks with no question to you, no message from the lead to the worker after it started, and no re-roll."),
        ])
    }

    static func time(_ f: QualityFigures) -> Section {
        let merged = f.merged > 0
        let span: String
        if let median = f.medianCreatedToMerged, let p90 = f.p90CreatedToMerged {
            span = "median \(StatisticsPage.duration(median)) · p90 \(StatisticsPage.duration(p90))"
        } else {
            span = none
        }
        let unknownWork = merged && f.workingShare == nil
        return Section(title: "Where time goes", figures: [
            Figure(label: "Created → merged", value: span, detail: merged ? "over \(count(f.merged, "merge"))" : nil,
                   help: "From the task's creation on the board to its merge."),
            Figure(label: "Worker working", value: f.workingShare.map(percent) ?? (unknownWork ? notRecorded : none),
                   detail: f.workingShare == nil ? (unknownWork ? "no merge's working time is kept" : nil)
                       : "of created → merged, over \(count(f.timed, "merge")) whose working time is known",
                   meter: f.workingShare.map(share),
                   help: "The workers' counted working time over created → merged, summed over the merges whose working time is known."),
            Figure(label: "Waiting for its audit", value: f.auditWaitShare.map(percent) ?? (merged ? notRecorded : none),
                   detail: f.auditWaitShare == nil && merged ? "the board keeps no time an audit was asked for: in the rest" : nil,
                   meter: f.auditWaitShare.map(share),
                   help: "From the worker's done report to the audit's verdict. Not kept yet: a separate task records it."),
            Figure(label: "The rest", value: f.restShare.map(percent) ?? (unknownWork ? notRecorded : none),
                   detail: f.restShare == nil ? nil : "planning, queueing, audits and merging", meter: f.restShare.map(share),
                   help: "Created → merged less the workers' working time (and the audit wait, once it's kept)."),
            Figure(label: "Parallelism", value: f.parallelism.map { "\(StatisticsPage.number($0))×" } ?? notRecorded,
                   detail: f.parallelism == nil ? "no receipt with a start ended in the range"
                       : "\(StatisticsPage.hours(f.workerHours)) of work over \(StatisticsPage.hours(f.busyHours)) with a task under way",
                   help: "Worker hours of the tasks that ended in the range over the wall-clock hours from the start to the end of any of them."),
        ])
    }

    static func cost(_ f: QualityFigures) -> Section {
        let merged = f.merged > 0
        func part(_ dollars: Double, _ share: Double?) -> String {
            share.map { "\(StatisticsPage.money(dollars)) · \(percent($0))" } ?? (f.costed > 0 ? StatisticsPage.money(dollars) : (merged ? notRecorded : none))
        }
        return Section(title: "Cost", figures: [
            Figure(label: "Cost per merged task", value: f.costPerMergedTask.map(StatisticsPage.money) ?? (merged ? notRecorded : none),
                   detail: f.costed > 0 ? "\(StatisticsPage.money(f.cost)) over \(count(f.costed, "merge")) whose cost is known"
                       : merged ? "no merge's cost is known" : nil,
                   help: "The estimated cost (prices as of the receipt) of the merges whose cost is known, per merge."),
            Figure(label: "Implementation (worker)", value: part(f.workerCost, f.implementationShare), meter: f.implementationShare.map(share),
                   help: "The workers' part of that cost, and its share."),
            Figure(label: "Verification (verifier)", value: part(f.verifierCost, f.verificationShare), meter: f.verificationShare.map(share),
                   help: "The verifiers' (and finders') part of that cost, and its share."),
            Figure(label: "Merge reruns", value: f.mergeRerunCost.map(StatisticsPage.money) ?? (merged ? notRecorded : none),
                   detail: f.mergeRerunCost == nil && merged ? "receipts count a rerun, not what it cost" : nil,
                   help: "What the merges' test reruns cost. Not kept yet: a separate task records it."),
        ])
    }

    // MARK: Breakdown

    static func cells(_ f: QualityFigures) -> [String] {
        let merged = f.merged > 0
        let audited = f.audited > 0
        func known(_ value: String?) -> String { value ?? (merged ? notRecorded : none) }
        return ["\(f.merged)",
                audited ? f.firstAuditPassRate.map(percent) ?? none : none,
                audited ? f.meanRoundsToPass.map { StatisticsPage.number($0) } ?? none : none,
                audited ? f.importantPerAudited.map { StatisticsPage.number($0) } ?? none : none,
                known(f.mergeFirstTry?.rate.map(percent)),
                f.questionsPerMergedTask.map { StatisticsPage.number($0, digits: 2) } ?? none,
                f.neededNobodyShare.map(percent) ?? none,
                f.medianCreatedToMerged.map(StatisticsPage.duration) ?? none,
                known(f.costPerMergedTask.map(StatisticsPage.money))]
    }

    // MARK: Formatting

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    static func share(_ value: Double) -> StatisticsPage.Meter { StatisticsPage.Meter(used: min(1, max(0, value)), elapsed: nil, reached: false) }

    /// "1 merge", "3 merges".
    static func count(_ value: Int, _ noun: String) -> String { "\(value) \(noun)\(value == 1 ? "" : "s")" }
}
