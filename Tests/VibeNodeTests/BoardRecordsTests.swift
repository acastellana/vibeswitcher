import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The Team tab's records in a board's value (`BoardRecords`, 2026-11-21): the lead's decisions from its records folder
/// and the one not moved yet, merged; read below the root with no link followed, so a repository's link can't make a page
/// read a file outside it; the scorecard and receipts in the Mac's words; the closed questions newest first; where the
/// four files are. Each test has a scratch root.
struct BoardRecordsTests {
    private let scratch = Scratch()

    private func root(_ name: String = "repo") throws -> URL {
        let root = scratch.url(name)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".vibeswitcher"), withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, _ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private static func decisions(_ items: [(String, String, String)]) -> String {
        "# Decisions\n\n" + items.map { "## \($0.0) \($0.1)\n\n\($0.2)\n\n" }.joined()
    }

    @Test func decisionsComeFromTheRecordsFolderAndTheOneNotMovedYet() throws {
        let root = try root()
        try write("---\nrecords_dir: notes/lead\n---\n", ".vibeswitcher/workflow.md", in: root)
        try write(Self.decisions([("2026-11-20 10:00:00", "Use the new parser", "The old one drops comments."),
                                  ("2026-11-20 11:00:00", "Ship on Friday", "The demo is Monday.")]), "notes/lead/decisions.md", in: root)
        try write(Self.decisions([("2026-11-19 09:00:00", "Keep the hero image", "Marketing asked.")]), ".vibeswitcher/decisions.md", in: root)
        try write("# Progress\n", "notes/lead/progress.md", in: root)
        let read = BoardRecords.read(root: root.path)
        #expect(read.recordsDir == "notes/lead")
        #expect(read.decisions.map(\.text) == ["Keep the hero image", "Use the new parser", "Ship on Friday"])
        #expect(read.present == ["workflow.md": true, "decisions.md": true, "progress.md": true, "incidents.md": false])

        let fields = BoardRecords.fields(board: LeadBoard(), read: read, now: Date())
        #expect(fields["decisions"]?.array?.map { $0["text"]?.string ?? "" } == ["Ship on Friday", "Use the new parser", "Keep the hero image"],
                "newest first")
        #expect(fields["decisions"]?.array?.first?["why"] == .string("The demo is Monday."))
        #expect(fields["files"]?.array?.map { $0["path"]?.string ?? "" }
                == [".vibeswitcher/workflow.md", "notes/lead/decisions.md", "notes/lead/progress.md", "notes/lead/incidents.md"])
        #expect(fields["recordsDir"] == .string("notes/lead"))
    }

    /// A records folder, or a decisions.md, that is a link leads nowhere: its decisions aren't read, wherever it points.
    /// A records_dir out of the repository is no records folder.
    @Test func aLinkOrAFolderOutsideTheRepositoryIsNeverRead() throws {
        let outside = try root("outside")
        try write(Self.decisions([("2026-11-20 10:00:00", "A secret heading", "secret body")]), "decisions.md", in: outside)
        try write(Self.decisions([("2026-11-20 10:00:00", "A secret heading", "secret body")]), "lead/decisions.md", in: outside)

        let linkedFolder = try root("linked-folder")
        try write("---\nrecords_dir: docs/lead\n---\n", ".vibeswitcher/workflow.md", in: linkedFolder)
        try FileManager.default.createDirectory(at: linkedFolder.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedFolder.appendingPathComponent("docs/lead"), withDestinationURL: outside.appendingPathComponent("lead"))

        let linkedFile = try root("linked-file")
        try write("---\nrecords_dir: docs/lead\n---\n", ".vibeswitcher/workflow.md", in: linkedFile)
        try FileManager.default.createDirectory(at: linkedFile.appendingPathComponent("docs/lead"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedFile.appendingPathComponent("docs/lead/decisions.md"),
                                                   withDestinationURL: outside.appendingPathComponent("decisions.md"))
        try FileManager.default.createSymbolicLink(at: linkedFile.appendingPathComponent(".vibeswitcher/decisions.md"),
                                                   withDestinationURL: outside.appendingPathComponent("decisions.md"))

        let climbing = try root("climbing")
        try write("---\nrecords_dir: ../outside\n---\n", ".vibeswitcher/workflow.md", in: climbing)

        let linkedWorkflow = try root("linked-workflow")
        try FileManager.default.createSymbolicLink(at: linkedWorkflow.appendingPathComponent(".vibeswitcher/workflow.md"),
                                                   withDestinationURL: outside.appendingPathComponent("decisions.md"))

        for root in [linkedFolder, linkedFile, climbing, linkedWorkflow] {
            let read = BoardRecords.read(root: root.path)
            #expect(read.decisions.isEmpty, "\(root.lastPathComponent): \(read.decisions)")
            let wire = String(decoding: NodeWire.message(NodeWire.Value.object(BoardRecords.fields(board: LeadBoard(), read: read, now: Date()))), as: UTF8.self)
            #expect(!wire.contains("secret"), "\(root.lastPathComponent)")
        }
        #expect(BoardRecords.read(root: climbing.path).recordsDir == nil)
        // A workflow that is a link isn't read: the default records folder stands.
        #expect(BoardRecords.read(root: linkedWorkflow.path).recordsDir == "docs/lead")
    }

    @Test func theScorecardAndTheClosedQuestionsReadAsTheMacsTeamTab() throws {
        var board = LeadBoard()
        var merged = LeadTask(slug: "a", title: "A", contract: LeadContract(goal: "", acceptance: [], boundaries: [], context: ""), status: .done)
        merged.merged = LeadMergeRecord(commit: "8a3f1e2c", tested: false, at: 1_000)
        board.tasks = [merged]
        var answered = LeadQuestion(id: "q1", text: "Which colour?", options: ["red", "blue"])
        answered.askedAt = 100
        answered.answer = "blue"
        answered.answeredAt = 200
        var withdrawn = LeadQuestion(id: "q2", text: "Rename it?\nIt reads oddly.", options: ["yes", "no"])
        withdrawn.askedAt = 150
        withdrawn.withdrawnAt = 300
        withdrawn.withdrawReason = "Settled by the spec."
        var open = LeadQuestion(id: "q3", text: "Still open?", options: ["yes"])
        open.askedAt = 400
        board.questions = [answered, withdrawn, open]

        let fields = BoardRecords.fields(board: board, read: BoardRecords.Read(), now: Date(timeIntervalSince1970: 2_000))
        let card = try #require(fields["scorecard"])
        #expect(card["merged"] == .int(1) && card["mergedWithoutTests"] == .int(1))
        #expect(card["tiles"]?.array?.count == LeadScorecard(board, now: 2_000).tiles.count)
        let footnote = try #require(card["footnote"]?.string)
        #expect(footnote.hasPrefix("Over 1 merged task") && footnote.hasSuffix("1 merged without tests."), "\(footnote)")
        let questions = try #require(fields["answered"]?.array)
        #expect(questions.map { $0["id"]?.string ?? "" } == ["q2", "q1"], "closed only, newest first")
        #expect(questions[0]["state"] == .string("withdrawn") && questions[0]["why"] == .string("Settled by the spec."))
        #expect(questions[1]["answer"] == .string("blue") && questions[1]["why"] == .null)

        // The whole value is what the schema says.
        let value = BoardValue.value(project: "local:project:x", root: "/r", board: board, now: Date(timeIntervalSince1970: 2_000))
        #expect(WireSchema.check(value, as: "board", strict: true) == nil, "\(WireSchema.check(value, as: "board", strict: true) ?? "")")
        #expect(WireSchema.check(WireVectors.boardValue, as: "board", strict: true) == nil)
        // Nothing merged yet: no tiles, no footnote.
        let empty = BoardRecords.scorecard(LeadBoard(), now: Date())
        #expect(empty["tiles"] == .array([]) && empty["footnote"] == .null)
    }

    /// The records are read again only when one of their files changed.
    @Test func theRecordsAreReadAgainOnlyWhenAFileChanged() throws {
        let root = try root()
        try write("---\nrecords_dir:\n---\n", ".vibeswitcher/workflow.md", in: root)
        try write(Self.decisions([("2026-11-20 10:00:00", "First", "Why.")]), ".vibeswitcher/decisions.md", in: root)
        let file = BoardRecordsFile(root: root.path)
        #expect(file.load().decisions.map(\.text) == ["First"])
        #expect(file.load().recordsDir == nil)
        try write(Self.decisions([("2026-11-20 10:00:00", "First", "Why."), ("2026-11-20 12:00:00", "Second", "Why.")]),
                  ".vibeswitcher/decisions.md", in: root)
        #expect(file.load().decisions.map(\.text) == ["First", "Second"])
    }
}
