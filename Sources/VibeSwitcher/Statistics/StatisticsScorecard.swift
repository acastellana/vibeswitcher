import Foundation
import VibeCore

/// The scorecard's section of the Statistics page (see `SetupScorecard`): the last 7 days against the 7 before, each
/// line with its n, and a trend said only when both weeks have at least `SetupScorecard.trendFloor`.
extension QualityPage {
    static let scorecardTitle = "Scorecard: the last 7 days and the 7 before"

    static func scorecard(_ card: SetupScorecard) -> Section {
        let w = card.week, p = card.previous
        func money(_ value: Double?) -> String { value.map(StatisticsPage.money) ?? none }
        func minutes(_ value: Double?) -> String { value.map { "\(StatisticsPage.number($0)) min" } ?? none }
        func perTask(_ value: Double?) -> String { value.map { StatisticsPage.number($0, digits: 2) } ?? none }
        func duration(_ value: Double?) -> String { value.map(StatisticsPage.duration) ?? none }

        var figures: [Figure] = []
        figures.append(Figure(
            label: "Bugs you reported vs found by the system", value: "\(w.origins.userReported) vs \(w.origins.systemFound)",
            detail: "Tasks created: \(w.origins.text) · the 7 days before: \(p.origins.userReported) vs \(p.origins.systemFound); "
                + "\(p.origins.text) · " + trend(Double(w.origins.userReported), Double(p.origins.userReported), n: w.origins.total,
                                                  before: p.origins.total, what: "bugs you reported"),
            help: "The tasks put on the board in each week, by where add_task said they came from: user_report (you reported it) against "
                + "incident, log_watcher, flake and audit (the system found it); lead and other are neither; not said: tasks from before "
                + "origins were kept. n: the tasks created that week."))
        figures.append(Figure(
            label: "Questions per delivered task", value: perTask(w.questionsPerTask),
            detail: "n = \(count(w.merged, "merge")): \(count(w.questions, "question")), \(minutes(w.userMinutesPerTask)) of your waiting per task · "
                + "the 7 days before: \(perTask(p.questionsPerTask)), \(minutes(p.userMinutesPerTask)) waiting (n = \(p.merged)) · "
                + trend(w.questionsPerTask, p.questionsPerTask, n: w.merged, before: p.merged, what: "questions per task"),
            help: "The lead's questions to you about the week's merged tasks (whenever asked), and those about no task asked that week, per "
                + "merged task; and the minutes they waited on your answer, per merged task. n: the week's merges."))
        let leadNote: String
        if w.leadKept {
            leadNote = "lead \(money(w.leadPerTask)) per task (its cost on the days with a merge, spread over that day's merges)"
                + (w.leadUnspread > 0 ? " · lead \(StatisticsPage.money(w.leadUnspread)) on days with no merge, not spread" : "")
                + (w.leadUnpricedDays > 0 ? " · \(count(w.leadUnpricedDays, "lead day")) with a model that has no price, not in it" : "")
        } else {
            leadNote = "the lead's share: \(StatisticsPage.notRecorded) (no lead ledger covers the week)"
        }
        figures.append(Figure(
            label: "Cost per merged task, with the lead's share", value: money(w.costPerTask),
            detail: "n = \(w.costed) of \(count(w.merged, "merge")) with a known cost: receipts \(money(w.receiptCostPerTask)) per task + \(leadNote) · "
                + "the 7 days before: \(money(p.costPerTask)) (n = \(p.costed)) · "
                + trend(w.costPerTask, p.costPerTask, n: w.costed, before: p.costed, what: "cost per task"),
            help: "The receipts' estimated cost (workers and verifiers, Codex at its own prices) per merged task whose cost is known, plus the "
                + "project lead's own cost: each day's spread over that day's merges in its project. Receipts don't carry the lead's share. "
                + "n: the merges whose cost is known."))
        let installed = w.installTimes.count
        figures.append(Figure(
            label: "Time to install", value: w.medianInstall.map { "median \(StatisticsPage.duration($0))" } ?? none,
            detail: "n = \(installed) of \(count(w.merged, "merge")) installed, \(w.notInstalled) not installed yet · the 7 days before: "
                + "\(duration(p.medianInstall)) (n = \(p.installTimes.count) of \(p.merged)) · "
                + trend(w.medianInstall, p.medianInstall, n: installed, before: p.installTimes.count, what: "time to install"),
            help: "From a task's creation to the first install that contained its merge: a build a later merge's receipt records as the one "
                + "that ran it holds every commit before its own. A merge no recorded build holds yet is not installed yet. n: the merges installed."))
        if !card.installs.isEmpty {
            let shown = card.installs.prefix(Self.installRows)
            var lines = shown.map { install in
                "\(clip(install.title)): " + (install.toInstall.map { StatisticsPage.duration($0) + " to install" } ?? "not installed yet")
            }
            if card.installs.count > shown.count { lines.append("… and \(card.installs.count - shown.count) more") }
            figures.append(Figure(label: "Time to install, per task", value: count(card.installs.count, "merge"),
                                  detail: lines.joined(separator: "\n"),
                                  help: "Each of the last 7 days' merged tasks, latest first: from its creation to the first install that contained "
                                      + "its merge, or not installed yet."))
        }
        return Section(title: scorecardTitle, figures: figures)
    }

    /// The per-task lines shown at most.
    static let installRows = 15

    /// "up from the week before" / "down …" / "same as the week before" when both weeks have n ≥ the floor; else
    /// "n < 10 in a week: no trend".
    static func trend(_ now: Double?, _ before: Double?, n: Int, before nBefore: Int, what: String) -> String {
        let floor = SetupScorecard.trendFloor
        guard n >= floor, nBefore >= floor, let now, let before else { return "n < \(floor) in a week: no trend" }
        if abs(now - before) < 1e-9 { return "\(what): same as the week before" }
        return "\(what): " + (now > before ? "up" : "down") + " from the week before"
    }

    static func clip(_ text: String, _ limit: Int = 70) -> String { text.count > limit ? String(text.prefix(limit - 1)) + "…" : text }
}
