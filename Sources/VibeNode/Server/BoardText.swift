import Foundation
import VibeCore

/// A board as `vibeswitcher board` prints it (`BoardValue`'s value): the project's folder, then its tasks grouped as the
/// page groups them (needs attention, running, waiting, done today), one short line each: its state and for how long,
/// its title, and its dim line (a blocked task's blocker's first line, what it waits on, why it failed, its last
/// checkpoint); then a count line. Every field the sessions wrote goes through `ConfigSeal.inert` again here (the value
/// is inert already; this is the terminal's own lock), so no escape sequence or bidirectional character reaches it.
public enum BoardText {
    /// The groups' headings, in `BoardValue.groups`' order.
    static let headings = ["attention": "Needs attention", "running": "Running", "waiting": "Waiting", "done": "Done today"]
    /// The longest a line's dim part is printed.
    static let dimLimit = 100

    static func inert(_ text: String?, limit: Int = .max) -> String { ConfigSeal.inert(text ?? "", limit: limit) }

    /// The lines for one board at `now`; `calendar` says where today began (a finished task from before it isn't shown).
    public static func lines(_ board: NodeWire.Value, now: Date = Date(), calendar: Calendar = .current, home: String? = nil) -> [String] {
        var root = inert(board["root"]?.string)
        if let home, !home.isEmpty, root == home || root.hasPrefix(home + "/") { root = "~" + root.dropFirst(home.count) }
        let base = board["baseBranch"]?.string.map { " · base \(inert($0, limit: 80))" } ?? ""
        var lines = ["\(root)\(base)"]
        if let unreadable = board["unreadable"]?.string {
            lines.append("  the board can't be shown: \(inert(unreadable))")
            return lines
        }
        lines += allDoneLines(board["allDone"], now: now)
        let today = calendar.startOfDay(for: now)
        let tasks = (board["tasks"]?.array ?? []).filter { task in
            guard task["group"]?.string == "done" else { return true }
            let finished = (task["merged"]?["at"]?.string ?? task["since"]?.string).flatMap(NodeWire.date)
            return finished.map { $0 >= today } ?? false
        }
        var counts: [String] = []
        for group in BoardValue.groups {
            let shown = tasks.filter { $0["group"]?.string == group }
            guard !shown.isEmpty else { continue }
            lines.append(headings[group] ?? group)
            lines += shown.map { line($0, now: now) }
            counts.append(count(group, shown.count))
        }
        if tasks.isEmpty { lines.append("  nothing on the board yet") }
        let more = board["more"]?.int ?? 0
        lines.append((counts.isEmpty ? "no tasks" : counts.joined(separator: " · ")) + (more > 0 ? " · \(more) more not shown" : ""))
        // The lead's latest decisions: a long one by its AI summary when one came (the app's `DecisionFeed.line`).
        let decisions = board["decisions"]?.array ?? []
        if !decisions.isEmpty {
            lines.append("Decisions")
            lines += decisions.prefix(decisionsShown).map { decision in
                let text = decision["summary"]?.string ?? decision["text"]?.string
                let when = decision["at"]?.string.flatMap(NodeWire.date).map { " (" + Durations.short(now.timeIntervalSince($0)) + " ago)" } ?? ""
                return "  Decided: " + lowercasedFirst(inert(text, limit: dimLimit)) + when
            }
            if decisions.count > decisionsShown { lines.append("  \(decisions.count - decisionsShown) earlier (--json shows them, each with why)") }
        }
        lines += records(board, now: now, calendar: calendar)
        return lines
    }

    /// "Run them" → "run them"; "API keys…" and "VibeSwitcher…" stay (the app's `DecisionFeed.lowercasedFirst`).
    static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        if text.prefix { $0 != " " }.dropFirst().contains(where: \.isUppercase) { return text }
        return first.lowercased() + text.dropFirst()
    }

    /// The board's all-done card (`BoardValue.allDone`, the app's): "All tasks finished 12m ago · 5 tasks · 4 merged",
    /// its summary's headline and bullets, and what it cost; nothing when none.
    static func allDoneLines(_ mark: NodeWire.Value?, now: Date) -> [String] {
        guard let mark, mark.object != nil else { return [] }
        let tasks = mark["tasks"]?.array?.count ?? 0
        let when = mark["at"]?.string.flatMap(NodeWire.date).map { " " + Durations.short(now.timeIntervalSince($0)) + " ago" } ?? ""
        var lines = ["All tasks finished\(when) · \(tasks) task\(tasks == 1 ? "" : "s") · \(mark["merged"]?.int ?? 0) merged"]
        if let summary = mark["summary"], summary.object != nil {
            lines.append("  " + inert(summary["headline"]?.string, limit: 200))
            lines += (summary["bullets"]?.array ?? []).map { "  - " + inert($0.string, limit: 200) }
        }
        if let cost = mark["receipts"]?.string {
            lines.append("  Cost: " + inert(cost, limit: 300) + (mark["pricesAsOf"]?.string.map { " (estimates at the API prices of \(inert($0, limit: 40)))" } ?? ""))
        }
        return lines
    }

    /// How many closed questions are printed (the rest: `--json`).
    static let recordsShown = 5

    /// The Team tab's other records under the tasks and decisions (2026-11-21, `BoardRecords`, `BoardDetails`): the
    /// scorecard, the lead's newest results, the newest answered and withdrawn questions, and where the lead's files are.
    static func records(_ board: NodeWire.Value, now: Date, calendar: Calendar) -> [String] {
        var lines: [String] = []
        if let card = board["scorecard"], card != .null, !(board["tasks"]?.array ?? []).isEmpty {
            lines.append("Scorecard")
            let tiles = card["tiles"]?.array ?? []
            if tiles.isEmpty {
                lines.append("  Nothing merged yet: the numbers start with the first merge.")
            } else {
                lines.append("  " + tiles.map { "\(inert($0["value"]?.string, limit: 20)) \(inert($0["label"]?.string, limit: 80))" }.joined(separator: " · "))
                if let footnote = card["footnote"]?.string { lines.append("  " + inert(footnote, limit: 300)) }
            }
            if let receipts = card["receipts"]?.string { lines.append("  " + inert(receipts, limit: 600)) }
        }
        let results = board["results"]?.array ?? []
        if !results.isEmpty {
            lines.append("Results")
            lines += results.prefix(recordsShown).map { result in
                "  \(when(result["at"], now: now, calendar: calendar))  \(inert(result["title"]?.string, limit: 140))"
                    + ((result["images"]?.int ?? 0) > 0 ? " (\(result["images"]?.int ?? 0) screenshot\(result["images"]?.int == 1 ? "" : "s"))" : "")
            }
            if results.count > recordsShown { lines.append("  \(results.count - recordsShown) earlier (--json shows them, each with its text)") }
        }
        let answered = board["answered"]?.array ?? []
        if !answered.isEmpty {
            lines.append("Answered and withdrawn")
            lines += answered.prefix(recordsShown).map(question)
            if answered.count > recordsShown { lines.append("  \(answered.count - recordsShown) earlier (--json)") }
        }
        let files = board["files"]?.array ?? []
        if !files.isEmpty {
            let said = files.map { file in
                inert(file["path"]?.string, limit: 200) + (file["present"]?.bool == true ? "" : " (not there yet)")
            }
            lines.append("Files: " + said.joined(separator: ", "))
        }
        return lines
    }

    /// "  Which colour? → blue", "  Withdrawn: Rename it? (Settled by the spec.)", "  Name it? → Parser (no answer in time)".
    static func question(_ question: NodeWire.Value) -> String {
        let gist = inert(question["text"]?.string.flatMap { $0.split(whereSeparator: \.isNewline).first.map(String.init) }, limit: 100)
        switch question["state"]?.string {
        case "withdrawn":
            return "  Withdrawn: \(gist)" + (question["why"]?.string.map { " (\(inert($0, limit: 100)))" } ?? "")
        case "autoDecided":
            return "  \(gist) → \(inert(question["proposal"]?.string, limit: 60)) (no answer in time: the lead went ahead)"
        default:
            return "  \(gist) → \(inert(question["answer"]?.string, limit: 60))"
        }
    }

    /// "14:05" today, "Nov 19" before.
    static func when(_ value: NodeWire.Value?, now: Date, calendar: Calendar) -> String {
        guard let date = value?.string.flatMap(NodeWire.date) else { return "     " }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "MMM d"
        return formatter.string(from: date)
    }
    /// The decisions `vibeswitcher board` lists, newest first.
    static let decisionsShown = 5

    /// "  Blocked 18m  Fix the flaky upload test — Waits on Sync landing-base with main".
    static func line(_ task: NodeWire.Value, now: Date) -> String {
        var state = inert(task["state"]?.string, limit: 40)
        if task["group"]?.string != "done", let since = task["since"]?.string.flatMap(NodeWire.date) {
            state += " " + Durations.short(now.timeIntervalSince(since))
        }
        var text = "  \(state)  \(inert(task["title"]?.string, limit: 120))"
        let dim: String?
        if task["status"]?.string == "done", let merged = task["merged"], let commit = merged["commit"]?.string {
            dim = "merged \(inert(commit, limit: 12))" + (merged["tested"]?.bool == true ? ", tests passed" : "")
        } else {
            // A task at work: the AI summary's line of what its agent is doing, when one came.
            dim = task["summary"]?.string ?? task["line"]?.string
        }
        if let dim, !dim.isEmpty { text += " — " + inert(dim, limit: dimLimit) }
        return text
    }

    /// "2 need attention", "1 running", "1 waiting", "4 done today".
    static func count(_ group: String, _ count: Int) -> String {
        switch group {
        case "attention": return count == 1 ? "1 needs attention" : "\(count) need attention"
        case "done": return "\(count) done today"
        default: return "\(count) \(group)"
        }
    }
}
