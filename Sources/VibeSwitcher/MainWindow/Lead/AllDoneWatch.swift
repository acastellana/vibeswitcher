import Foundation
import VibeCore

/// The app's side of the all-done cards (see `BatchSummary`): at each look at a lead's board, whether it went from open
/// work to none since the last look (a mark, written under the board's lock), the summary of each mark that has none
/// (written once, off the main thread, and stored with it), and the user opening the lead (its marks seen). Everything
/// it writes goes through `BoardStore.update` on the lead controller's queue (`LeadReads`), in order with its reads.
final class AllDoneWatch {
    /// Writes a summary from its prompt (headless Claude in the app); nil: the written fallback, as in tests and benches.
    var generate: ((String) -> String?)?
    /// The Team view's AI summaries setting: off, no model is asked.
    var enabled: () -> Bool = { true }
    /// Where a summary is written: off the main thread (it blocks up to a minute).
    var run: (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .utility).async(execute: $0) }
    /// A board was written (a mark, a summary, seen), by root: the controller reads it again. On the main thread.
    var changed: (String) -> Void = { _ in }

    private let reads: LeadReads
    /// Marks whose summary was asked for in this run (by id): each once, whatever comes of it.
    private var summarizing: Set<String> = []

    init(reads: LeadReads) { self.reads = reads }

    /// `board` as just read for `root`, `previous` as read before (nil: none yet, as after a launch). On the main thread.
    func look(root: String, previous: LeadBoard?, board: LeadBoard, now: Double = Date().timeIntervalSince1970) {
        dispatchPrecondition(condition: .onQueue(.main))
        if BatchSummary.detect(previous: previous, current: board, now: now) != nil {
            // Again under the lock, on the board as it is now: another writer may have added a task, or marked it.
            reads.async({ _ in (try? BoardStore(root: root).update { BatchSummary.mark(&$0, previous: previous, now: now) }) ?? nil }) { [weak self] mark in
                if mark != nil { self?.changed(root) }
            }
        }
        for mark in board.allDone ?? [] where mark.summary == nil && summarizing.insert(mark.id).inserted {
            summarize(mark, root: root, board: board)
        }
    }

    private func summarize(_ mark: LeadAllDone, root: String, board: LeadBoard) {
        let input = BatchSummary.input(mark, board: board, project: (root as NSString).lastPathComponent)
        let generate = generate
        let enabled = enabled() && generate != nil
        let reads = reads
        run { [weak self] in
            let summary = BatchSummary.write(input, tasks: mark.tasks, enabled: enabled, generate: generate ?? { _ in nil })
            reads.async({ _ in (try? BoardStore(root: root).update { $0.setAllDoneSummary(summary, for: mark.id) }) ?? false }) { wrote in
                if wrote { self?.changed(root) }
            }
        }
    }

    /// The user opened the lead at `root` whose board is `board`: its marks are seen. Returns the board as seen, to
    /// show at once (nil: nothing was unseen); the file is written after, when it still has unseen marks.
    func see(root: String, board: LeadBoard, now: Double = Date().timeIntervalSince1970) -> LeadBoard? {
        var seen = board
        guard seen.seeAllDone(at: now) else { return nil }
        reads.async({ _ in
            let store = BoardStore(root: root)
            // A refresh read before this write may show the marks unseen once more: no second write for it.
            guard (try? store.read())?.hasUnseenAllDone == true else { return false }
            return (try? store.update { $0.seeAllDone(at: now) }) ?? false
        }) { [weak self] wrote in
            if wrote { self?.changed(root) }
        }
        return seen
    }
}
