import Foundation
import VibeCore

/// What the Mac's Team tab shows under a lead's tasks (the parity table's board row, 2026-11-21), carried in the board's
/// value beside its tasks: the lead's decisions, the scorecard and the batch's receipts, the answered and withdrawn
/// questions, and where the lead's files are. Read-only, as the board.
///
/// - **Decisions** come from the lead's `decisions.md`: in its records folder (`records_dir` in the project's
///   workflow.md, a folder of the repository: no `..`, nothing absolute, never `.git` or `.vibeswitcher`), and the one
///   not moved yet in `.vibeswitcher`, merged by their ids. Each file is opened below the root with no link followed
///   (`Platform.Files.readRegular`), at most `recordBytes`: a link, a FIFO or a larger file gives no decisions, and a
///   repository's link can't make a page read a file outside it. The newest `decisionsKept`.
/// - **Scorecard** and **receipts**: the board's own numbers (`LeadScorecard`, `LeadReceiptTotals.current`), as the
///   Mac's `ScorecardView` words them.
/// - **Answered and withdrawn**: the board's closed questions, newest first (as `ClosedQuestionList`), the newest
///   `answeredKept`, each the wording that was answered, its answer, or why it was withdrawn.
/// - **Files**: the four the Mac's buttons open, by name, where each is kept and whether it is there. A page can't open
///   a file on the node: it shows where they are.
///
/// Every string is the sessions' writing: inert and capped, as the tasks' (`BoardValue.text`).
public enum BoardRecords {
    static let decisionsKept = 50
    static let answeredKept = 30
    /// The largest record file read.
    static let recordBytes = 4 << 20
    /// The four files the Mac's Team tab opens.
    static let files = ["workflow.md", "decisions.md", "progress.md", "incidents.md"]

    /// What the reads found under one root.
    public struct Read: Equatable, Sendable {
        public var decisions: [LeadDecision] = []
        public var recordsDir: String?
        /// Each of `files`, whether it is there.
        public var present: [String: Bool] = [:]

        public init(decisions: [LeadDecision] = [], recordsDir: String? = nil, present: [String: Bool] = [:]) {
            self.decisions = decisions
            self.recordsDir = recordsDir
            self.present = present
        }
    }

    /// The records under `root`, read off the engine's queue.
    static func read(root: String) -> Read {
        var read = Read()
        if case .data(let data) = Platform.Files.readRegular(in: root, path: [".vibeswitcher", "workflow.md"], limit: recordBytes),
           let text = String(data: data, encoding: .utf8) {
            read.recordsDir = LeadWorkflow.parse(text).recordsDir.flatMap(LeadWorkflow.recordsFolder)
        } else {
            read.recordsDir = LeadWorkflow.recordsFolder(LeadWorkflow.defaultRecordsDir)
        }
        var decisions: [String: LeadDecision] = [:]
        for components in decisionPaths(recordsDir: read.recordsDir) {
            guard case .data(let data) = Platform.Files.readRegular(in: root, path: components, limit: recordBytes),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for decision in LeadDecision.parse(text) { decisions[decision.id] = decision }
        }
        read.decisions = decisions.values.sorted { ($0.at, $0.text) < ($1.at, $1.text) }
        for name in files {
            read.present[name] = FileManager.default.fileExists(atPath: ([root] + path(of: name, recordsDir: read.recordsDir)).joined(separator: "/"))
        }
        return read
    }

    /// Where `decisions.md` may be: the records folder's, then the one in `.vibeswitcher` not moved yet.
    static func decisionPaths(recordsDir: String?) -> [[String]] {
        let local = [".vibeswitcher", "decisions.md"]
        guard let dir = recordsDir else { return [local] }
        return [dir.split(separator: "/").map(String.init) + ["decisions.md"], local]
    }

    /// A file's place under the root, as the Mac's buttons find it: workflow.md in `.vibeswitcher`, the rest in the
    /// records folder (in `.vibeswitcher` when there is none).
    static func path(of name: String, recordsDir: String?) -> [String] {
        guard name != "workflow.md", let dir = recordsDir else { return [".vibeswitcher", name] }
        return dir.split(separator: "/").map(String.init) + [name]
    }

    /// `value` inert and capped, as the tasks' strings (`BoardValue.text`).
    static func text(_ value: String, _ limit: Int, _ lines: Int) -> String { BoardValue.text(value, limit: limit, lines: lines) }

    /// The fields the board's value gains.
    /// `summaries`: the engine's decisions with their AI lines (`LeadEngine.boardDecisions`): a line is taken for a
    /// decision read here (by its id), never a decision of the engine's own read.
    static func fields(board: LeadBoard?, read: Read, now: Date, summaries: [BoardDecision] = []) -> [String: NodeWire.Value] {
        var fields: [String: NodeWire.Value] = [:]
        let lines = Dictionary(summaries.compactMap { decision in decision.summary.map { (decision.id, $0) } }, uniquingKeysWith: { first, _ in first })
        fields["decisions"] = BoardValue.decisions(read.decisions.suffix(decisionsKept).reversed().map { decision in
            BoardDecision(id: decision.id, at: decision.at, text: decision.text, why: decision.why, summary: lines[decision.id])
        }, limit: decisionsKept)
        fields["scorecard"] = board.map { scorecard($0, now: now) } ?? .null
        fields["answered"] = .array(Array(closed(board?.questions ?? []).prefix(answeredKept)).map(question))
        fields["files"] = .array(files.map { name in
            .object(["name": .string(name), "path": .string(path(of: name, recordsDir: read.recordsDir).joined(separator: "/")),
                     "present": .bool(read.present[name] ?? false)])
        })
        fields["recordsDir"] = read.recordsDir.map { .string(text($0, 200, 1)) } ?? .null
        return fields
    }

    /// The scorecard as the Mac's `ScorecardView` shows it: its four tiles, the footnote under them, and the batch's
    /// receipts in a line. `merged` 0: nothing merged yet, and no tiles.
    static func scorecard(_ board: LeadBoard, now: Date) -> NodeWire.Value {
        let card = LeadScorecard(board, now: now.timeIntervalSince1970)
        let receipts = LeadReceiptTotals.current(board)
        return .object([
            "merged": .int(card.merged), "reverts": .int(card.reverts), "mergedWithoutTests": .int(card.mergedWithoutTests),
            "tiles": .array(card.merged == 0 ? [] : card.tiles.map { tile in
                .object(["value": .string(tile.value), "label": .string(tile.label), "note": tile.note.map(NodeWire.Value.string) ?? .null,
                         "help": .string(tile.help)])
            }),
            "footnote": card.merged == 0 ? .null : .string(footnote(card)),
            "receipts": receipts.map { .string(text(($0.last == nil ? "This batch: " : "Last batch: ") + $0.totals.text + ".", 600, 2)) } ?? .null,
        ])
    }

    /// "Over 5 merged tasks (audit rounds known for 2); 2 with no audit (review none); 1 merged without tests." (the
    /// Mac's `ScorecardView.footnote`, copied: the port map's "Copied from the app").
    static func footnote(_ card: LeadScorecard) -> String {
        var text = "Over \(card.merged) merged task\(card.merged == 1 ? "" : "s")"
        if card.counted < card.merged - card.mergedUnaudited { text += " (audit rounds known for \(card.counted))" }
        if card.mergedUnaudited > 0 { text += "; \(card.mergedUnaudited) with no audit (review none)" }
        if card.mergedWithoutTests > 0 { text += "; \(card.mergedWithoutTests) merged without tests" }
        return text + "."
    }

    /// The closed questions, newest first by when each closed (`ClosedQuestionList.newestFirst`).
    static func closed(_ questions: [LeadQuestion]) -> [LeadQuestion] {
        func closedAt(_ question: LeadQuestion) -> Double {
            [question.answeredAt, question.withdrawnAt, question.autoDecidedAt].compactMap { $0 }.min() ?? question.askedAt
        }
        return questions.filter { !$0.isOpen }.sorted { closedAt($0) > closedAt($1) }
    }

    /// One closed question: the wording that was answered, how it closed (`answered`, `withdrawn`, `autoDecided`), what
    /// with (the answer; for one its timer decided, the lead's proposal, and an answer that came later), why it was
    /// withdrawn, and when.
    static func question(_ question: LeadQuestion) -> NodeWire.Value {
        let saw = question.answeredVersion ?? question.version
        let wording = question.wording(saw)
        let closedAt = [question.answeredAt, question.withdrawnAt, question.autoDecidedAt].compactMap { $0 }.min() ?? question.askedAt
        return .object([
            "id": .string(text(question.id, 80, 1)), "state": .string(question.state.rawValue),
            "text": .string(text(wording.text, 2_000, 30)),
            "answer": question.answer.map { .string(text($0, 1_000, 10)) } ?? .null,
            "proposal": question.state == .autoDecided ? question.proposal.map { .string(text($0, 1_000, 10)) } ?? .null : .null,
            "why": question.state == .withdrawn ? question.withdrawReason.map { .string(text($0, 1_000, 10)) } ?? .null : .null,
            "reworded": .bool(saw != question.version),
            "task": question.task.map { .string(text($0, 120, 1)) } ?? .null,
            "at": .date(Date(timeIntervalSince1970: closedAt)),
        ])
    }
}

/// One root's records as last read: read again only when one of their files' stamps changed (the board is read at
/// each of its changes, many a minute while a team works; its decisions seldom change). On its feed's reads queue only.
final class BoardRecordsFile: @unchecked Sendable {
    let root: String
    private var stamps: [BoardFiles.Stamp?]?
    private var kept = BoardRecords.Read()

    init(root: String) { self.root = root }

    func load() -> BoardRecords.Read {
        let now = stampsNow(recordsDir: kept.recordsDir)
        if let stamps, stamps == now { return kept }
        kept = BoardRecords.read(root: root)
        stamps = stampsNow(recordsDir: kept.recordsDir)
        return kept
    }

    private func stampsNow(recordsDir: String?) -> [BoardFiles.Stamp?] {
        let paths = [[".vibeswitcher", "workflow.md"]] + BoardRecords.decisionPaths(recordsDir: recordsDir)
            + BoardRecords.files.map { BoardRecords.path(of: $0, recordsDir: recordsDir) }
        return paths.map { BoardFiles.Stamp(([root] + $0).joined(separator: "/")) }
    }
}
