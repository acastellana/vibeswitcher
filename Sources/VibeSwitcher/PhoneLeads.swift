import CryptoKit
import Foundation
import VibeCore

/// The project leads as the phone shows them, read from what the Mac shows (`LeadController`, the window's rows): each
/// lead's questions for you (`LeadBoard.questionStack`, as the Mac's question stack), its team's summary (the sidebar's,
/// `TeamRows.summary`), and, on its own page, its all-done card, its latest results, its tasks as the Team tab reads
/// them (`TeamRows.rows`) and the scorecard. Titles, states, counts and the lead's own words only: no transcript text
/// (the Team view's AI summaries of transcripts are left out), credentials masked (`Redaction`), no paths.
enum PhoneLeads {
    /// One running lead: its repository, its board as last read, and what the window reads of its team.
    struct Lead {
        var root: String
        var board: LeadBoard
        /// "team: 2 working · 1 waits on lead", as the sidebar's lead row says it; nil with no team listed.
        var summary: String?
        /// Its tasks as the Team tab's rows.
        var rows: [TeamRow]
    }

    /// The leads the Mac shows: each running lead's board (`LeadController.boards`) with its team's rows, from the
    /// window's rows (`rows`, labelled by `label`) as the sidebar and the Team tab read them, through their caches.
    static func leads(_ controller: LeadController, sections: [WindowSection], label: (WindowRow) -> String?, now: Date = Date()) -> [Lead] {
        let rows = sections.flatMap(\.rows)
        let teams = LeadTeams.arrange(sections, label: label, expanded: []).teams
        return controller.boards.keys.sorted().compactMap { root in
            guard let board = controller.boards[root] else { return nil }
            let leadRow = rows.first { LeadTeams.role(label: label($0)) == .lead && $0.cwd.map { ($0 as NSString).standardizingPath } == root }
            var summary: String?
            if let leadRow, let team = teams[leadRow.id], !team.isEmpty {
                let key = "sidebar|" + root
                summary = TeamRows.summary(controller.teamRows.rows(key, board: board, seen: controller.teamRows.seen(key, board: board, rows: team, now: now)))
            }
            let seen = controller.teamRows.seen(root, board: board, rows: rows, now: now)
            return Lead(root: root, board: board, summary: summary, rows: controller.teamRows.rows(root, board: board, seen: seen))
        }
    }

    /// Phone Access reading `controller`'s leads as the window shows them (`model`), and answering their questions
    /// through the Mac's answer path (`LeadController.answer`), as the phone's.
    static func wire(_ access: PhoneAccess, controller: LeadController, model: WindowModel) {
        access.leads = { [weak controller, weak model] in
            guard let controller, let model else { return [] }
            return leads(controller, sections: model.sections, label: model.label(of:))
        }
        access.answerLead = { [weak controller] root, question, saw, text, done in
            guard let controller else { return done(.missing, nil) }
            controller.answer(question, root: root, with: text, saw: saw, from: .phone, done: done)
        }
    }

    /// A lead's id on the phone: short, stable, and no path.
    static func id(root: String) -> String {
        Base64URL.encode(Data(SHA256.hash(data: Data(("lead|" + (root as NSString).standardizingPath).utf8))).prefix(9))
    }

    /// The lead id of a session: a lead's own, or the one a worker's or verifier's worktree belongs to.
    static func id(of session: Session) -> String? {
        guard let cwd = session.cwd else { return nil }
        switch session.teamRole {
        case .lead: return id(root: cwd)
        case .worker, .verifier: return LeadTeams.root(ofWorktree: cwd).map { id(root: $0) }
        case nil: return nil
        }
    }

    private static func masked(_ text: String) -> String { Redaction.secrets(in: text) }
    private static func clipped(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    /// `/api/state`'s `leads`: each lead's questions for you and its team's summary.
    static func state(_ leads: [Lead], now: Double = Date().timeIntervalSince1970) -> [[String: Any]] {
        leads.map { lead in
            let open = lead.board.openQuestions
            var object: [String: Any] = [
                "id": id(root: lead.root), "project": masked((lead.root as NSString).lastPathComponent),
                "questions": lead.board.questionStack(now: now).map(question),
                "open": open.count, "blocking": lead.board.blockingQuestions,
                "allDone": lead.board.hasUnseenAllDone,
            ]
            if let summary = lead.summary { object["summary"] = summary }
            return object
        }
    }

    /// A question as the Mac's card shows it: its wording, options, priority, why now, its proposal's timer (or held),
    /// its revision, and what closed it.
    static func question(_ question: LeadQuestion) -> [String: Any] {
        var object: [String: Any] = [
            "id": question.id, "version": question.version, "text": masked(question.text), "options": question.options.map(masked),
            "priority": question.rank.rawValue, "state": question.state.rawValue, "askedAt": question.askedAt,
        ]
        if let why = question.whyNow { object["whyNow"] = masked(why) }
        if let proposal = question.proposal {
            object["proposal"] = masked(proposal)
            object["decideIn"] = question.decideIn ?? LeadQuestion.defaultDecideIn
            if question.isCounting, let deadline = question.decideBy { object["decideBy"] = deadline }
            if question.heldAt != nil { object["held"] = true }
        }
        if let revisions = question.revisions, let last = revisions.last {
            object["revised"] = ["at": last.at, "note": masked(last.note),
                                 "earlier": revisions.enumerated().map { index, earlier in
                                     ["version": index + 1, "text": masked(earlier.text), "options": earlier.options.map(masked), "until": earlier.at] as [String: Any]
                                 }]
        }
        switch question.state {
        case .withdrawn:
            object["withdrawReason"] = masked(question.withdrawReason ?? "no reason given")
            object["closedAt"] = question.withdrawnAt ?? question.askedAt
        case .autoDecided:
            object["closedAt"] = question.autoDecidedAt ?? question.askedAt
        case .answered, .open:
            break
        }
        if let answer = question.answer { object["answer"] = masked(answer) }
        if let from = question.answeredFrom { object["answeredFrom"] = from.rawValue }
        return object
    }

    /// The finished tasks the lead page lists (the latest; the rest are counted in `finished`).
    static let finishedShown = 8
    /// The results the lead page shows, newest first, and how much of each one's text.
    static let updatesShown = 3
    static let updateLimit = 1_500

    /// `/api/lead`: one lead's page: its all-done card, its latest results, its tasks by state, the scorecard.
    static func page(_ lead: Lead, now: Date = Date()) -> [String: Any] {
        let board = lead.board
        var object: [String: Any] = ["id": id(root: lead.root), "project": masked((lead.root as NSString).lastPathComponent)]
        if let summary = lead.summary { object["summary"] = summary }
        if let mark = board.allDone?.last, !BatchSummary.hasOpenWork(board) || mark.seenAt == nil {
            var card: [String: Any] = ["at": mark.at, "count": AllDoneCard.count(mark),
                                       "tasks": mark.tasks.map { ["title": masked($0.title), "outcome": $0.outcome.rawValue] }]
            if let summary = mark.summary {
                card["headline"] = masked(summary.headline)
                card["bullets"] = summary.bullets.map(masked)
            }
            if let receipts = mark.receipts { card["cost"] = AllDoneCard.cost(receipts) }
            object["allDone"] = card
        }
        object["updates"] = board.updates.reversed().prefix(updatesShown).map { update in
            ["title": masked(update.title), "body": masked(clipped(update.body, updateLimit)), "at": update.at, "images": update.images.count] as [String: Any]
        }
        let finished = lead.rows.filter { $0.group == .finished }
        let shown = lead.rows.filter { $0.group != .finished } + finished.prefix(finishedShown)
        object["tasks"] = shown.map { task($0, now: now) }
        object["finished"] = ["title": TeamRows.finishedTitle(finished), "count": finished.count, "shown": min(finished.count, finishedShown)] as [String: Any]
        if !board.tasks.isEmpty { object["scorecard"] = LeadScorecard(board, now: now.timeIntervalSince1970).line }
        if let receipts = LeadReceiptTotals.current(board) { object["cost"] = ScorecardView.cost(receipts.totals, last: receipts.last) }
        return object
    }

    /// A task as the Team tab's row says it: its title, its state in words and since when, its group and mark, and the
    /// dim line under it (what it waits on, why it's red, its latest checkpoint; a task needing an audit, why).
    static func task(_ row: TeamRow, now: Date) -> [String: Any] {
        var object: [String: Any] = ["title": masked(row.task.title), "state": row.state, "stateText": row.stateText(now: now),
                                     "group": "\(row.group)", "mark": "\(row.mark)"]
        let line = row.state == "Needs audit" ? row.activity : row.line(summary: nil)
        if let line, !line.isEmpty { object["line"] = masked(clipped(line, 300)) }
        return object
    }
}
