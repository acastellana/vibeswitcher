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
        }
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
