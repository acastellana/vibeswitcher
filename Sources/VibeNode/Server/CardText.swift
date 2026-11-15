import Foundation
import VibeCore

/// A card as the command line prints it (`questions`, `answer`, `config held`, `base show`; the engine plan's E6). Every
/// field a worker or the lead wrote (the question and its options, notes, task titles, commit subjects, file names,
/// held names and their changes) goes through `ConfigSeal.inert(_, limit: .max)`, so no escape sequence or
/// bidirectional character reaches the terminal; the lead's words are marked as the lead's beside the engine's facts.
public enum CardText {
    static func inert(_ text: String?) -> String { ConfigSeal.inert(text ?? "", limit: .max) }

    /// `status`'s lines for the leads and the open cards (its result's `leads` and `cards`): per lead its project,
    /// folder and session, its open and blocking questions and its open cards' ids; then the open cards counted by kind.
    public static func statusLines(leads: [NodeWire.Value], cards: NodeWire.Value?) -> [String] {
        var lines = ["leads: \(leads.count)"]
        for lead in leads {
            let questions = lead["questions"]
            let open = questions?["open"]?.int ?? 0, blocking = questions?["blocking"]?.int ?? 0
            let ids = lead["cards"]?.array?.compactMap(\.string) ?? []
            lines.append("  \(inert(lead["project"]?.string))  \(inert(lead["root"]?.string))  session \(inert(lead["session"]?.string ?? "none"))"
                         + ": \(open) open question\(open == 1 ? "" : "s") (\(blocking) blocking)"
                         + (ids.isEmpty ? "" : ", cards \(ids.map(inert).joined(separator: ", "))"))
        }
        if let cards {
            let count = { (kind: String) in cards[kind]?.int ?? 0 }
            lines.append("open cards: \(count("questions")) questions, \(count("approvals")) approvals, \(count("config")) held config, "
                         + "\(count("base")) base moves")
        }
        return lines
    }

    /// The lines for `card` (`CardStore.Card.value`).
    public static func lines(_ card: NodeWire.Value) -> [String] {
        let id = inert(card["id"]?.string)
        let kind = card["kind"]?.string ?? "?"
        let root = card["root"]?.string ?? ""
        let state = card["open"]?.bool == true ? "open" : "closed: " + inert(card["closed"]?.string)
        var lines = ["\(id)  \(kind)  \(inert((root as NSString).lastPathComponent))  \(state)"]
        if let question = card["question"], question != .null {
            lines.append("  the lead asks (its words, not VibeSwitcher's): " + inert(question["text"]?.string))
            let options = question["options"]?.array?.compactMap(\.string) ?? []
            if !options.isEmpty { lines.append("  options (the lead's): " + options.map(inert).joined(separator: " | ")) }
            var about = "  \(inert(question["priority"]?.string)), version \(question["version"]?.int ?? 1)"
            if let task = question["task"]?.string { about += ", about task " + inert(task) }
            lines.append(about)
            if let why = question["whyNow"]?.string { lines.append("  why now (the lead's): " + inert(why)) }
            if let note = question["revisionNote"]?.string { lines.append("  revised (the lead's note): " + inert(note)) }
            if let proposal = question["proposal"]?.string {
                let by = question["decideBy"]?.string.map { " unless answered or held by " + inert($0) } ?? ""
                lines.append("  the lead proposes ‘\(inert(proposal))’\(by)")
            }
            if let answer = question["answer"]?.string {
                lines.append("  answered: \(inert(answer))" + (question["answeredVersion"]?.int.map { " (to version \($0))" } ?? ""))
            }
            if let reason = question["withdrawReason"]?.string { lines.append("  withdrawn (the lead's reason): " + inert(reason)) }
        }
        if let approval = card["approval"], approval != .null {
            lines.append("  approval of commit \(inert(approval["commit"]?.string)), from git: " + inert(approval["subject"]?.string ?? "(no subject)"))
            let tasks = approval["tasks"]?.array?.compactMap(\.string) ?? []
            lines.append("  tasks whose branch is at that commit: " + (tasks.isEmpty ? "none" : tasks.map(inert).joined(separator: ", ")))
            lines.append("  changes from \(inert(approval["base"]?.string ?? "the base")): \(inert(approval["diffstat"]?.string))")
            for file in approval["files"]?.array?.compactMap(\.string) ?? [] { lines.append("    " + inert(file)) }
            for (task, verdict) in (approval["verdicts"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
                lines.append("  verdict on \(inert(task)), from the vault: " + inert(verdict.string))
            }
            if let sensitive = approval["sensitive"]?.array?.compactMap(\.string) {
                lines.append("  sensitive paths touched: " + (sensitive.isEmpty ? "none" : sensitive.map(inert).joined(separator: ", ")))
            }
            for problem in approval["problems"]?.array?.compactMap(\.string) ?? [] { lines.append("  note: " + inert(problem)) }
        }
        if let config = card["config"], config != .null {
            let items = config["items"]?.array ?? []
            lines.append(items.isEmpty ? "  nothing held: accepting records what workflow.md proposes and ends a fresh vault's first look"
                                       : "  held (no worker, verifier or merge until accepted):")
            for item in items {
                var line = "    " + inert(item["name"]?.string)
                if let at = item["changedAt"]?.string { line += ", changed " + inert(at) }
                if let size = item["size"]?.int { line += ", \(size) bytes" }
                line += ", hash " + inert(item["hash"]?.string)
                if let change = item["change"]?.string { line += ": " + inert(change) }
                if item["outside"]?.bool == true { line += " (changed outside a team session)" }
                if let since = item["sinceAccept"]?.string { line += "; " + inert(since) }
                lines.append(line)
                for file in item["files"]?.array?.compactMap(\.string) ?? [] { lines.append("      " + inert(file)) }
            }
            if let floor = config["floor"]?.object {
                var said = "  the review floor workflow.md proposes: merge policy \(inert(floor["mergePolicy"]?.string)), "
                    + "\(floor["auditFinders"]?.int ?? 1) finder(s), risk lines \(floor["riskLines"]?.int ?? 0)"
                let sensitive = floor["sensitivePaths"]?.array?.compactMap(\.string) ?? []
                if !sensitive.isEmpty { said += ", sensitive paths " + sensitive.map(inert).joined(separator: ", ") }
                lines.append(said)
            }
            if let base = config["baseBranch"]?.string { lines.append("  its base branch: " + inert(base)) }
            let rails = config["guarded"]?.array ?? []
            if !rails.isEmpty { lines.append("  workflow.md's guard rails (read each value: the accept records them):") }
            for rail in rails {
                lines.append("    \(inert(rail["key"]?.string)): \(inert(rail["value"]?.string))"
                             + (rail["sinceAccept"]?.string.map { "; " + inert($0) } ?? ""))
            }
            if let at = config["lastAccept"]?.string {
                lines.append("  compared with your last accept (\(inert(at))), from an unsealed snapshot a worker could rewrite: read the values")
            } else if config["items"]?.array?.isEmpty == false {
                lines.append("  no earlier accept is known here: everything held is new to this card")
            }
        }
        if let base = card["base"], base != .null {
            let from = base["from"]?.string.map { "\(inert($0)) (\(inert(base["fromIs"]?.string)))" } ?? "unknown"
            lines.append("  \(inert(base["branch"]?.string)) from \(from) to \(inert(base["to"]?.string))")
            if let reason = base["reason"]?.string { lines.append("  " + inert(reason)) }
            for commit in base["commits"]?.array ?? [] {
                lines.append("    \(inert(String((commit["sha"]?.string ?? "").prefix(12)))) \(inert(commit["subject"]?.string))")
            }
        }
        if let notice = card["notice"]?.string { lines.append("  notice: " + inert(notice)) }
        return lines
    }
}
