import Foundation
import VibeCore

/// The all-done mark (the app's `AllDoneWatch` and its card, for a node; the rule and the mark are `BatchSummary`'s,
/// shared): at each refresh, a lead's board that went from open work to none since the last read, with a task merged
/// since the last mark, gets its mark (under the board's lock, as the app writes it) and its summary: by the model on
/// the user's node while the AI summaries may run (`Options.summarizeBatch`, the app's `ClaudeHeadless.allDone`), else
/// the written fallback. `status` then says it for a day: the project, when, the summary, how many merged and its
/// receipts summed; the board carries the mark (`BoardValue.allDone`: `vibeswitcher board` and the page's card), and a
/// page that shows the board marks it seen (`see`). Its state is its own, on the engine's queue.
final class AllDoneWatch {
    /// How long `status` says a board cleared.
    static let shown: TimeInterval = 24 * 60 * 60

    private let queue: DispatchQueue
    private let reads: BoardReads
    /// The summaries' prompts, one at a time with the engine's others.
    private let runs: DispatchQueue
    private let note: (String) -> Void
    /// The marks whose summary is being written.
    private var summarizing: Set<String> = []
    /// The clock a mark is dated and shown by (a test's).
    var now: () -> Date = Date.init

    init(queue: DispatchQueue, reads: BoardReads, runs: DispatchQueue, note: @escaping (String) -> Void) {
        self.queue = queue
        self.reads = reads
        self.runs = runs
        self.note = note
    }

    /// `loaded` against `previous` (the boards as the last refresh read them): each board that cleared is marked, and
    /// each mark with no summary gets the written one, on `reads` (in order with the engine's other board reads and
    /// writes). A board read for the first time (the engine just started) is no clear. On the engine's queue.
    func mark(previous: [String: LeadBoard], loaded: [String: LeadBoard], model: Summarizer.Generate?) {
        EngineWatch.assertOn(queue)
        let now = now().timeIntervalSince1970
        for (root, board) in loaded {
            let before = previous[root]
            let cleared = BatchSummary.detect(previous: before, current: board, now: now) != nil
            let unsummarized = (board.allDone ?? []).filter { $0.summary == nil && !summarizing.contains($0.id) }
            guard cleared || !unsummarized.isEmpty else { continue }
            unsummarized.forEach { summarizing.insert($0.id) }
            let (project, note, runs, reads) = ((root as NSString).lastPathComponent, self.note, self.runs, self.reads)
            // The model writes the summary when one is given (the engine gives it while the AI summaries may run: the
            // app's, with its setting on); else the written fallback, as before.
            reads.async({ _ in
                (try? BoardStore(root: root).update { board -> (mark: LeadAllDone?, asks: [(id: String, tasks: [LeadAllDone.Task], input: BatchSummary.Input)]) in
                    let mark = cleared ? BatchSummary.mark(&board, previous: before, now: now) : nil
                    var asks: [(id: String, tasks: [LeadAllDone.Task], input: BatchSummary.Input)] = []
                    for unwritten in board.allDone ?? [] where unwritten.summary == nil {
                        let input = BatchSummary.input(unwritten, board: board, project: project)
                        if model != nil {
                            asks.append((unwritten.id, unwritten.tasks, input))
                        } else {
                            board.setAllDoneSummary(BatchSummary.write(input, tasks: unwritten.tasks, enabled: false, generate: { _ in nil }), for: unwritten.id)
                        }
                    }
                    return (mark, asks)
                }) ?? (nil, [])
            }) { read in
                if let mark = read.mark { note("all done: the lead of \(project) cleared its board, \(mark.merged) of \(mark.tasks.count) task(s) merged") }
                guard let model else { return }
                for ask in read.asks {
                    // One prompt at a time with the other summaries; its answer, or the written fallback, kept under the lock.
                    runs.async {
                        let summary = BatchSummary.write(ask.input, tasks: ask.tasks, enabled: true, generate: model)
                        reads.async({ _ in (try? BoardStore(root: root).update { $0.setAllDoneSummary(summary, for: ask.id) }) ?? false })
                    }
                }
            }
        }
    }

    /// Acknowledge the displayed mark on the board writer's queue and deliver the outcome on the engine's queue.
    func see(root: String, id: String, done: @escaping (Result<Bool, Error>) -> Void) {
        EngineWatch.assertOn(queue)
        let now = now().timeIntervalSince1970
        reads.async({ _ in Result { try BoardStore(root: root).seeAllDone(id: id, at: now) } }, then: done)
    }

    /// What `status` says of each board that cleared in the last day: its newest mark.
    func notices(boards: [String: LeadBoard]) -> [String] {
        EngineWatch.assertOn(queue)
        let now = now().timeIntervalSince1970
        return boards.sorted { $0.key < $1.key }.compactMap { root, board in
            guard let mark = board.allDone?.last, now - mark.at < Self.shown else { return nil }
            let project = ConfigSeal.inert(LeadMail.project(of: root), limit: 80)
            let summary = mark.summary.map { summary in
                ConfigSeal.inert(summary.headline, limit: 240) + (summary.bullets.isEmpty ? "" : " " + summary.bullets.map { ConfigSeal.inert($0, limit: 240) }.joined(separator: " "))
            } ?? "\(mark.tasks.count) task\(mark.tasks.count == 1 ? "" : "s") finished, \(mark.merged) merged."
            // Its receipts summed, as the app's card says them.
            let cost = mark.receipts.map { " Cost: " + ConfigSeal.inert($0.text, limit: 300) + " (estimates at the API prices of \($0.pricesAsOf))." } ?? ""
            return "all done: the lead of \(project) cleared its board at \(NodeWire.dateText(Date(timeIntervalSince1970: mark.at))): \(summary)\(cost)"
        }
    }
}

extension LeadEngine {
    /// How long `status` says a board cleared.
    static var allDoneShown: TimeInterval { AllDoneWatch.shown }

    /// The boards as the refresh read them against the last read: each that cleared is marked (`AllDoneWatch.mark`),
    /// its summary by the model while the AI summaries may run. On `queue`.
    func noteAllDone(previous: [String: LeadBoard], loaded: [String: LeadBoard]) {
        allDone.mark(previous: previous, loaded: loaded, model: summariesAllowed ? batchModel : nil)
    }

    /// What `status` says of each board that cleared in the last day.
    var allDoneNotices: [String] { allDone.notices(boards: boards) }

    /// The most all-done cards a lead's chat shows (the newest).
    static let chatCardsShown = 20

    /// Each running lead's all-done cards, for its chat (`chatExtras`, by the lead's chat session id): the newest
    /// `chatCardsShown` of its board's marks, oldest first; a lead no longer running, or with none, has none. From the
    /// boards as the refresh read them. On `queue`.
    func publishChatCards() {
        var cards: [String: [NodeWire.Value]] = [:]
        for lead in leads.leads.values {
            guard let session = lead.session, let marks = boards[lead.root]?.allDone, !marks.isEmpty else { continue }
            cards[NodeIds.session(host: session)] = marks.suffix(Self.chatCardsShown).compactMap { ChatValue.value(.allDone($0)) }
        }
        for id in chatExtras.values.keys where cards[id] == nil { chatExtras.send(id, nil) }
        for (id, values) in cards { chatExtras.send(id, values) }
    }

}
