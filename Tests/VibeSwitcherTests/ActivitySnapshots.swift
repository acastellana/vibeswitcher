import AppKit
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The inspector's Activity tab (`ActivityRow`, from `ActivityFeed`): files changed, commands run, turn totals, in plain
/// words with VoiceOver labels. Pictures of a feed with the three kinds, light and dark, only with
/// `ACTIVITY_SNAPSHOT_DIR=/some/folder scripts/test.sh --filter ActivitySnapshots`.
@MainActor
struct ActivitySnapshots {
    static let folder = ProcessInfo.processInfo.environment["ACTIVITY_SNAPSHOT_DIR"]
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/activity-claude.jsonl")

    static func feed() throws -> ActivityFeed {
        ActivityFeed.read(try Data(contentsOf: fixture), format: .claude, startsMidFile: false)
    }

    /// Markdown a row could show raw: emphasis, code spans, links, headings.
    static func hasMarkdown(_ text: String) -> Bool {
        text.contains("**") || text.contains("`") || text.contains("](") || text.hasPrefix("#") || text.contains(" _")
    }

    /// A command whose description has markdown shows (and speaks) it as plain words.
    @Test func aRowShowsNoMarkdown() throws {
        let feed = try Self.feed()
        let row = try #require(feed.rows.first { $0.id == "command|toolu_bash1" })
        guard case .command(let command) = row else { Issue.record("not a command"); return }
        #expect(command.tool.title.contains("**"))   // what the transcript says: "Run **the** `Parser` tests"
        let lines = ActivityRow.lines(row)
        let shown = [lines.title, lines.detail ?? ""] + lines.trailing + [lines.spoken]
        #expect(!shown.contains(where: Self.hasMarkdown), "\(shown)")
        #expect(lines.title == "Run the Parser tests")
        #expect(lines.detail == "swift test --filter Parser …")
        #expect(lines.trailing == ["exit 0", "12s"])
        // Drawn, it lays out (a row with nothing to show would be zero-sized).
        let hosting = NSHostingView(rootView: ActivityRow(row: row).frame(width: 320))
        #expect(hosting.fittingSize.height > 10)
    }

    /// Every row has a VoiceOver label that says what it is, with the numbers in words.
    @Test func everyRowIsLabelled() throws {
        let spoken = try Self.feed().rows.map { ActivityRow.lines($0).spoken }
        #expect(spoken.allSatisfy { !$0.isEmpty && !Self.hasMarkdown($0) })
        #expect(spoken.contains("Edited Sources/Parser.swift, 2 times, 5 lines added, 3 removed"))
        #expect(spoken.contains("Ran make lint, exit code 2, under a second"))
        #expect(spoken.contains("Run the Parser tests, ran swift test --filter Parser …, exit code 0, took 12s"))
        #expect(spoken.contains("Ran npm run dev, running in the background"))
        #expect(spoken.contains { $0.hasPrefix("Turn total, started ") && $0.hasSuffix("2 files, 2 commands, 8.2k in (8.0k cached), 175 out, $0.50") })
        #expect(spoken.last?.hasSuffix("1.7k in (1.7k cached), 15 out, cost not reported") == true)
    }

    /// The tab's read: off the main thread, from a transcript in the agents' own folder, and again with more once it grows.
    @Test func theReadIsOffMainAndFollowsTheTranscript() async throws {
        let folder = URL(fileURLWithPath: VibePaths.home).appendingPathComponent(".claude/projects/activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("s.jsonl")
        let lines = try String(contentsOf: Self.fixture, encoding: .utf8).split(separator: "\n")
        try (lines.prefix(3).joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
        let first = try #require(await Task.detached { ActivityView.read(path.path) }.value)
        #expect(first.rows.map(\.id) == ["command|toolu_bash1", "turn|u1"])
        try (lines.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
        let grown = try #require(await Task.detached { ActivityView.read(path.path) }.value)
        #expect(grown == (try Self.feed()))
        // Outside the agents' folders it isn't read.
        #expect(ActivityView.read(Self.fixture.path) == nil)
        // The view hands the read to a detached task, as `d6a82e1` made it.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/VibeSwitcher/MainWindow/InspectorView.swift"), encoding: .utf8)
        #expect(source.contains("await Task.detached(priority: .userInitiated) { Self.read(path) }.value"))
    }

    @Test(.enabled(if: folder != nil)) func drawActivity() throws {
        let folder = try #require(Self.folder)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        var rows = try Self.feed().rows
        // A long path keeps its start and its file name.
        if case .file(var file) = rows[2] {
            file.id = "long"
            file.path = "Sources/VibeSwitcher/MainWindow/Inspector/Activity/Rows/ActivityRowLayout.swift"
            rows.insert(.file(file), at: 4)
        }
        let view = VStack(alignment: .leading, spacing: 8) { ForEach(rows) { ActivityRow(row: $0) } }.padding(12)
        // As wide as the inspector.
        try LeadQuestionSnapshots().write(view, width: 320, name: "activity", folder: folder)
        let empty = Text(ActivityFeed.emptyExplanation).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
        try LeadQuestionSnapshots().write(empty, width: 320, name: "activity-empty", folder: folder)
    }
}
