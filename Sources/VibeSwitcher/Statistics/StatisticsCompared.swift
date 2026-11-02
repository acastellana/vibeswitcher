import Foundation
import VibeCore

/// What the page shows of the comparison with working solo (`QualityFigures.processCost` and the figures beside it in
/// SetupStatsCompared.swift): a row per figure, a column for all merges, Claude's and Codex's, under groups that put
/// what the process caught before merge beside what escaped after it. Labelled an estimate, its method said on hover:
/// nothing here is measured against a real solo run. A figure whose inputs aren't kept reads "Not recorded"; one with
/// nothing to count reads "–".
struct ComparedPage: Equatable {
    static let title = "Compared with working solo"
    static let badge = "Estimate"
    /// The method, in one line: shown on hover over the section's title.
    static let method = "Estimated, not measured: nothing was run solo. Solo is one plain Claude Code or Codex session per task, spending what "
        + "the worker of the attempt that merged spent, with no lead, audits, merge test runs or re-rolls."
    static let columns = ["All", "Claude", "Codex"]

    var groups: [Group]

    struct Group: Equatable, Identifiable {
        var title: String
        var rows: [Row]
        var id: String { title }
    }

    struct Row: Equatable, Identifiable {
        var label: String
        /// What it is and what it assumes, in a line: shown on hover.
        var help: String
        /// One per column.
        var cells: [Cell]
        var id: String { label }
        var spoken: String {
            ([label] + zip(ComparedPage.columns, cells).map { column, cell in
                [column + " " + cell.value, cell.detail].compactMap { $0 }.joined(separator: ", ")
            }).joined(separator: "; ")
        }
    }

    struct Cell: Equatable {
        var value: String
        var detail: String?
    }

    /// `all` with Claude's and Codex's (from `byAgent`, by name; a missing one reads as nothing merged).
    init(all: QualityFigures, byAgent: [QualityGroup]) {
        let columns = [all] + ["Claude", "Codex"].map { name in byAgent.first { $0.name == name }?.figures ?? QualityFigures() }
        func row(_ label: String, _ help: String, _ cell: (QualityFigures, Bool) -> Cell) -> Row {
            Row(label: label, help: help, cells: columns.enumerated().map { cell($1, $0 == 0) })
        }
        groups = [
            Group(title: "What it costs", rows: [
                row("Process cost", "The lead's and verifiers' share of the cost (merge reruns and re-rolled attempts aren't priced) over the "
                    + "merges whose solo cost is known: their workers' cost is the solo baseline. ≥: a part isn't recorded.", Self.processCost),
            ]),
            Group(title: "Caught before merge, per 100 merged", rows: [
                row("Important findings fixed", "Important findings a later audit saw fixed, per 100 merges whose audits are kept: a solo "
                    + "session is taken to have shipped them.") { f, _ in
                    Self.per100(f.importantFixedPer100, f.importantFixed, over: f.auditsKept, "whose audits are kept", f,
                                missing: "no merge's audits are kept")
                },
                row("Test failures sent back", "Merges whose first test run failed (not a flake) and went back to their worker, per 100 "
                    + "merges the merges recorder saw: a solo session is taken to have merged them as they were.") { f, _ in
                    Self.per100(f.sentBackPer100, f.sentBack, over: f.mergeFirstTry?.counted ?? 0, "the merges recorder saw", f,
                                missing: "the merges recorder saw none of them")
                },
                row("Flaky tests caught by reruns", "Flaky tests a merge's rerun caught (the flake ledger), per 100 merges: a solo session "
                    + "is taken to have had no rerun to tell them apart.") { f, _ in
                    Self.per100(f.flakesCaughtPer100, f.flakesCaught ?? 0, over: f.merged, nil, f, missing: "no board keeps a flake ledger")
                },
            ]),
            Group(title: "Escaped after merge, per 100 merged", rows: [
                row("Reverts", "Merges since reverted, per 100 merges: what the process let through.") { f, _ in
                    Self.per100(f.revertsPer100, f.reverts, over: f.merged, nil, f, missing: "")
                },
                row("Incidents", "Merges named by an incident recorded after they merged, per 100 merges whose project keeps an incidents "
                    + "record.") { f, _ in
                    Self.per100(f.incidentsPer100, f.incidents, over: f.incidentsWatched, "whose project keeps an incidents record", f,
                                missing: "no project keeps an incidents record")
                },
            ]),
            Group(title: "Time", rows: [
                row("Hours of work per hour", "Worker hours over the wall-clock hours with a task under way: a solo session works an hour an "
                    + "hour. A task counts as under way from its start to its end, audits and merges included.") { f, _ in
                    guard let rate = f.hoursOfWorkPerHour else { return Cell(value: Self.notRecorded, detail: "no task with a start ended in the range") }
                    return Cell(value: StatisticsPage.number(rate),
                                detail: "\(StatisticsPage.hours(f.workerHours)) of work over \(StatisticsPage.hours(f.busyHours)) under way")
                },
                row("Your minutes per merged task", "The minutes the lead's questions waited on your answer, per merged task: taken as "
                    + "your attention, which overstates it.") { f, _ in
                    guard let minutes = f.userMinutesPerMergedTask else { return Cell(value: Self.none) }
                    return Cell(value: "\(StatisticsPage.number(minutes)) min", detail: QualityPage.count(f.questions, "question"))
                },
                row("Hands-off work per minute of yours", "A merged task's worker time over your minutes on it: a solo session is taken to "
                    + "need you for every minute it works.", Self.handsOff),
            ]),
        ]
    }

    static let notRecorded = StatisticsPage.notRecorded
    static let none = StatisticsPage.none

    static func processCost(_ f: QualityFigures, all: Bool) -> Cell {
        guard f.merged > 0 else { return Cell(value: none) }
        guard let cost = f.processCost else {
            let why: String
            if f.codexLeftOut > 0 || f.codexTokens != nil {
                why = "Codex tokens have no price" + (f.codexTokens.map { ": \(LeadReceipt.count($0)), not in the cost" } ?? "")
            } else if f.rerolledLeftOut > 0 {
                why = "the merges with a known cost were re-rolled: their attempts aren't split"
            } else {
                why = "no merge's cost is known"
            }
            return Cell(value: notRecorded, detail: why)
        }
        guard let share = cost.share else { return Cell(value: none, detail: "nothing spent") }
        var parts = ["\(StatisticsPage.money(cost.process)) of \(StatisticsPage.money(cost.total)) over \(QualityPage.count(cost.merges, "merge"))"]
        var unknown: [String] = []
        if let lead = cost.lead {
            parts.append("lead \(StatisticsPage.money(lead)), verifiers \(StatisticsPage.money(cost.verifiers))")
            if cost.leadUnpricedDays > 0 { unknown.append("the lead's unpriced days") }
        } else {
            parts.append("verifiers \(StatisticsPage.money(cost.verifiers))")
            unknown.append(all ? "the lead's" : "the lead's (in All only)")
        }
        if cost.reran > 0 { unknown.append("\(cost.reran) merge rerun\(cost.reran == 1 ? "" : "s")") }
        if cost.rerolledLeftOut > 0 { unknown.append("\(cost.rerolledLeftOut) re-rolled merge\(cost.rerolledLeftOut == 1 ? "" : "s")") }
        if !unknown.isEmpty { parts.append("not recorded: " + unknown.joined(separator: ", ")) }
        if let tokens = f.codexTokens, tokens > 0 { parts.append("Codex tokens \(LeadReceipt.count(tokens)), not in the cost") }
        return Cell(value: (cost.atLeast ? "≥ " : "") + QualityPage.percent(share), detail: parts.joined(separator: " · "))
    }

    /// A per-100 figure: "–" with nothing merged, "Not recorded" (`missing` said) when its inputs aren't kept, else
    /// the rate with "2 of 20 merges …".
    static func per100(_ rate: Double?, _ count: Int, over: Int, _ which: String?, _ f: QualityFigures, missing: String) -> Cell {
        guard f.merged > 0 else { return Cell(value: none) }
        guard let rate else { return Cell(value: notRecorded, detail: missing.isEmpty ? nil : missing) }
        return Cell(value: StatisticsPage.number(rate, digits: 0), detail: "\(count) of \(QualityPage.count(over, "merge"))" + (which.map { " " + $0 } ?? ""))
    }

    static func handsOff(_ f: QualityFigures, _: Bool) -> Cell {
        guard f.merged > 0 else { return Cell(value: none) }
        guard let work = f.workerHoursPerMergedTask else { return Cell(value: notRecorded, detail: "no merge's working time is kept") }
        let each = "\(StatisticsPage.duration(work * 3600)) of work per merged task"
        guard let ratio = f.handsOffMinutesPerUserMinute else { return Cell(value: none, detail: each + ", no minute of yours") }
        return Cell(value: "\(StatisticsPage.number(ratio, digits: 0)) min", detail: each)
    }
}
