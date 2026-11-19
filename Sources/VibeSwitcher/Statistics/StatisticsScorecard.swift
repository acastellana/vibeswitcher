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
            help: "From a task's creation to the first install that contained its merge: the installed app (installed when its copy is dated) "
                + "or a build a later merge's receipt records as the one that ran it, each holding every commit before its own. A merge no "
                + "recorded build holds yet is not installed yet. n: the merges installed."))
        figures += mergeFigures(card)
        figures += messageFigures(card)
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

    /// Each project's merge objectives (`MergeObjectives`): the share of merge runs that passed only on a rerun and the
    /// calm-Mac median, each with its n and the week before; the project named when there's more than one.
    static func mergeFigures(_ card: SetupScorecard) -> [Figure] {
        let w = card.week, p = card.previous
        var figures: [Figure] = []
        let named = w.merges.count > 1
        for current in w.merges {
            let now = current.objectives
            let before = p.merges.first { $0.project == current.project }?.objectives ?? MergeObjectives(runs: 0, passedOnRerun: 0, calmRuns: 0, calmMedianS: nil)
            let suffix = named ? " · \(current.project)" : ""
            func share(_ o: MergeObjectives) -> String { o.rerunPercent.map(MergeObjectives.percent) ?? none }
            func verdict(_ o: MergeObjectives) -> String {
                o.runs == 0 ? "no runs" : !o.rerunsJudged ? "too few runs to judge" : o.rerunsMissed ? "missed" : "met"
            }
            figures.append(Figure(
                label: "Merges passed only on a rerun" + suffix, value: share(now),
                detail: "n = \(count(now.runs, "merge run")): \(now.passedOnRerun) passed only on a rerun; objective \(Int(MergeObjectives.rerunShare * 100))%: "
                    + "\(verdict(now)) · the 7 days before: \(share(before)) (n = \(before.runs)), \(verdict(before)) · "
                    + trend(now.rerunPercent, before.rerunPercent, n: now.runs, before: before.runs, what: "share passed on a rerun"),
                help: "This project's merge runs that recorded a first test run (a conflict or an error ran none), from the Mac's merge "
                    + "stats; the share whose first run failed and whose rerun passed: the noise. A run that failed twice is the gate "
                    + "working, not counted here. Judged from \(MergeObjectives.minimumRuns) runs. n: the merge runs."))
            func median(_ o: MergeObjectives) -> String { o.calmMedianS.map { "\(StatisticsPage.number($0 / 60)) min" } ?? none }
            func calmVerdict(_ o: MergeObjectives) -> String { o.calmMedianS == nil ? "no calm-Mac run" : o.calmMissed ? "missed" : "met" }
            figures.append(Figure(
                label: "Median calm-Mac merge" + suffix, value: median(now),
                detail: "n = \(count(now.calmRuns, "calm-Mac run")) of \(now.runs); objective \(Int(MergeObjectives.calmMedian / 60)) min: \(calmVerdict(now)) · "
                    + "the 7 days before: \(median(before)) (n = \(before.calmRuns)), \(calmVerdict(before)) · "
                    + trend(now.calmMedianS, before.calmMedianS, n: now.calmRuns, before: before.calmRuns, what: "median merge"),
                help: "The median time of this project's merge runs that started on a calm Mac (a 1-minute load of at most "
                    + "\(StatisticsPage.number(MergeObjectives.calmLoad, digits: 0))), from the Mac's merge stats. n: those runs."))
        }
        return figures
    }

    /// The leads' messages to you: per day, by reason, and the share you acted on (`ScorecardMessages`).
    static func messageFigures(_ card: SetupScorecard) -> [Figure] {
        let w = card.week.messages, p = card.previous.messages
        guard w.kept || p.kept else { return [] }
        func perDay(_ value: Double?) -> String { value.map { StatisticsPage.number($0) } ?? none }
        func split(_ m: ScorecardMessages) -> String {
            LeadMessageReason.allCases.map { "\(m.byReason[$0] ?? 0) \($0.label)" }.joined(separator: ", ")
        }
        let needing = w.total > 0 ? " · \(percent(Double(w.byReason[.mustAct] ?? 0) / Double(w.total))) needed you to act" : ""
        let missing = w.chatKept ? "" : " · text replies and shell cards: \(StatisticsPage.notRecorded) (no lead transcript found)"
        var figures: [Figure] = []
        figures.append(Figure(
            label: "Lead's messages to you per day", value: perDay(w.perDay),
            detail: "n = \(count(w.total, "message")): \(split(w))\(needing)\(missing) · the 7 days before: \(perDay(p.perDay)) a day "
                + "(n = \(p.total): \(split(p))) · " + trend(w.perDay, p.perDay, n: w.total, before: p.total, what: "messages per day"),
            help: "What the project leads sent you, by the tool they used, never by what it says: you must act (ask_user, a vs-shell "
                + "card), finished or a problem (post_update), the daily summary (post_update titled \"\(LeadMessages.dailyPrefix)\") and "
                + "other (the lead's text replies in its chat, one per turn). Over the week's 7 days. n: the messages."))
        func share(_ m: ScorecardMessages) -> String { m.actedShare.map(percent) ?? none }
        figures.append(Figure(
            label: "Lead's messages you acted on", value: share(w),
            detail: "n = \(count(w.judged, "message")): \(w.acted) acted on within a day · the 7 days before: \(share(p)) (n = \(p.judged)) · "
                + trend(w.actedShare, p.actedShare, n: w.judged, before: p.judged, what: "share acted on"),
            help: "Of the leads' messages to you, those you acted on within a day: a question answered (not withdrawn or decided on its "
                + "timer), a shell card you ran or declined, an update or a reply followed by your message in the lead's chat. A message "
                + "less than a day old with nothing yet isn't counted. n: the messages counted."))
        return figures
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
