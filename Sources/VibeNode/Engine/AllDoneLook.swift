import Foundation
import VibeCore

/// The all-done mark (the app's `AllDoneWatch` and its card, for a node; the rule and the mark are `BatchSummary`'s,
/// shared): at each refresh, a lead's board that went from open work to none since the last read, with a task merged
/// since the last mark, gets its mark (under the board's lock, as the app writes it) and the written summary (the
/// fallback: the node asks no model, as the app's AI summaries setting off does). `status` then says it for a day: the
/// project, when, the summary and how many merged. The app's card in the lead's chat, its receipts and its seen mark are
/// the app's (a client's): the mark on the board is what a client shows later.
extension LeadEngine {
    /// How long `status` says a board cleared.
    static let allDoneShown: TimeInterval = 24 * 60 * 60

    /// `loaded` against `previous` (the boards as the last refresh read them): each board that cleared is marked, and
    /// each mark with no summary gets the written one, on `reads` (in order with the engine's other board reads and
    /// writes). A board read for the first time (the engine just started) is no clear. On `queue`.
    func noteAllDone(previous: [String: LeadBoard], loaded: [String: LeadBoard]) {
        let now = allDoneNow().timeIntervalSince1970
        for (root, board) in loaded {
            let before = previous[root]
            let cleared = BatchSummary.detect(previous: before, current: board, now: now) != nil
            let unsummarized = (board.allDone ?? []).filter { $0.summary == nil && !allDoneSummarizing.contains($0.id) }
            guard cleared || !unsummarized.isEmpty else { continue }
            unsummarized.forEach { allDoneSummarizing.insert($0.id) }
            let (project, note) = ((root as NSString).lastPathComponent, self.note)
            reads.async({ _ in
                (try? BoardStore(root: root).update { board -> LeadAllDone? in
                    let mark = cleared ? BatchSummary.mark(&board, previous: before, now: now) : nil
                    for unwritten in board.allDone ?? [] where unwritten.summary == nil {
                        let input = BatchSummary.input(unwritten, board: board, project: project)
                        board.setAllDoneSummary(BatchSummary.write(input, tasks: unwritten.tasks, enabled: false, generate: { _ in nil }), for: unwritten.id)
                    }
                    return mark
                }) ?? nil
            }) { mark in
                if let mark { note("all done: the lead of \(project) cleared its board, \(mark.merged) of \(mark.tasks.count) task(s) merged") }
            }
        }
    }

    /// What `status` says of each board that cleared in the last day: its newest mark.
    var allDoneNotices: [String] {
        let now = allDoneNow().timeIntervalSince1970
        return boards.sorted { $0.key < $1.key }.compactMap { root, board in
            guard let mark = board.allDone?.last, now - mark.at < Self.allDoneShown else { return nil }
            let project = ConfigSeal.inert(LeadMail.project(of: root), limit: 80)
            let summary = mark.summary.map { summary in
                ConfigSeal.inert(summary.headline, limit: 240) + (summary.bullets.isEmpty ? "" : " " + summary.bullets.map { ConfigSeal.inert($0, limit: 240) }.joined(separator: " "))
            } ?? "\(mark.tasks.count) task\(mark.tasks.count == 1 ? "" : "s") finished, \(mark.merged) merged."
            return "all done: the lead of \(project) cleared its board at \(NodeWire.dateText(Date(timeIntervalSince1970: mark.at))): \(summary)"
        }
    }
}
