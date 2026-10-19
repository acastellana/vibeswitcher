import AppKit
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// A folded task in the Team view: finished with the merged ones ("Merged (3, 1 folded)"), never red, and its line
/// "Folded into <title>" a link to the task that carries its work. `TEAM_SNAPSHOT_DIR=/some/folder` also writes the
/// render (team-folded-light.png, -dark.png).
@MainActor
struct TeamFoldTests {
    static func board() -> LeadBoard {
        var board = LeadBoard()
        var carrier = TeamRowsTests.task("app-plan-task-15", .done, title: "Plan the app, tasks 11 to 15 in one")
        carrier.worktree = nil
        carrier.merged = LeadMergeRecord(commit: "abc", tested: true)
        var other = TeamRowsTests.task("menu", .done, title: "Menu shortcuts")
        other.worktree = nil
        var folded = TeamRowsTests.task("app-plan-task-12", .folded, title: "Plan task 12")
        folded.worktree = nil
        folded.foldedInto = "app-plan-task-15"
        // An older failure stays on it; it doesn't read failed for it.
        folded.setback = LeadSetback(stage: .review, reason: "Folded into app-plan-task-15 by the user")
        board.tasks = [carrier, other, folded]
        return board
    }

    @Test func aFoldedTaskReadsFoldedIntoItsTargetUnderMerged() throws {
        let rows = TeamRows.rows(Self.board(), seen: [:])
        let folded = try #require(rows.first { $0.task.slug == "app-plan-task-12" })
        #expect(folded.group == .finished && folded.mark == .folded && folded.state == "Folded")
        #expect(!folded.mark.isRed && folded.problem == nil)
        #expect(folded.foldedInto?.slug == "app-plan-task-15")
        #expect(folded.foldedText == "Folded into Plan the app, tasks 11 to 15 in one")
        #expect(folded.line(summary: nil) == "Folded into Plan the app, tasks 11 to 15 in one")
        #expect(folded.stateText(now: TeamRowsTests.now) == "Folded")
        #expect(TeamRows.finishedTitle(rows.filter { $0.group == .finished }) == "Merged (3, 1 folded)")
        #expect(TeamRows.summary(rows) == "team: none running")
        // Its target gone from the board: its slug, no link.
        let alone = TeamRows.row(Self.board().task("app-plan-task-12")!, seen: [:])
        #expect(alone.foldedInto == nil && alone.foldedText == "Folded into app-plan-task-15")
        // With a kept and an abandoned one beside it.
        var kept = TeamRowsTests.task("proto", .kept)
        kept.keptBecause = "Prototype"
        var abandoned = TeamRowsTests.task("gone", .failed)
        abandoned.worktree = nil
        #expect(TeamRows.finishedTitle(rows.filter { $0.group == .finished } + [TeamRows.row(kept, seen: [:]), TeamRows.row(abandoned, seen: [:])])
                == "Merged (3, 1 folded) · Kept (1) · Abandoned (1)")
    }

    /// The board with two abandoned tasks: one the lead gave up, one cleaned up after failing (an older board).
    static func withAbandoned() -> LeadBoard {
        var board = board()
        var dropped = TeamRowsTests.task("dark-mode-v1", .abandoned, title: "Dark mode, first try")
        dropped.worktree = nil
        dropped.abandonedBecause = "The user dropped it: the system appearance is enough"
        var old = TeamRowsTests.task("old-menu", .failed, title: "Old menu rework")
        old.worktree = nil
        board.tasks += [dropped, old]
        return board
    }

    @Test func anAbandonedTaskReadsAbandonedUnderItsOwnFold() throws {
        let rows = TeamRows.rows(Self.withAbandoned(), seen: [:])
        let dropped = try #require(rows.first { $0.task.slug == "dark-mode-v1" })
        #expect(dropped.group == .finished && dropped.mark == .abandoned && dropped.state == "Abandoned" && !dropped.mark.isRed)
        #expect(dropped.line(summary: nil) == "The user dropped it: the system appearance is enough")
        let old = try #require(rows.first { $0.task.slug == "old-menu" })
        #expect(old.group == .finished && old.mark == .abandoned)
        #expect(TeamRows.finishedTitle(rows.filter { $0.group == .finished }) == "Merged (3, 1 folded) · Abandoned (2)")
        #expect(!rows.contains { $0.group == .needsYou })
        // The chat's strip shows them abandoned, never failed.
        #expect(dropped.task.shownStatus == .abandoned && old.task.shownStatus == .abandoned)
        #expect(LeadTask.Status.abandoned.label == "Abandoned")
    }

    func list(_ board: LeadBoard) -> some View {
        TeamTaskList(rows: TeamRows.rows(board, seen: [:]), now: TeamRowsTests.now, summary: { _ in nil }, canOpen: { _ in false },
                     open: { _ in }, showFinished: true)
            .padding(14).frame(width: 420, alignment: .topLeading)
    }

    func render(_ view: some View, dark: Bool = false) throws -> NSBitmapImageRep {
        let framed = view.background(dark ? Color(white: 0.16) : Color(white: 0.97)).environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        return NSBitmapImageRep(cgImage: image)
    }

    /// Pixels drawn in the accent color (the link's).
    func accentPixels(_ bitmap: NSBitmapImageRep) -> Int {
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)!
        var count = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let distance = abs(color.redComponent - accent.redComponent) + abs(color.greenComponent - accent.greenComponent)
                    + abs(color.blueComponent - accent.blueComponent)
                if distance < 0.15 { count += 1 }
            }
        }
        return count
    }

    @Test func theRenderedRowLinksToTheTaskThatCarriesIt() throws {
        let board = Self.board()
        let linked = try render(list(board))
        // The same row with its target gone from the board: its slug in plain text, no link.
        var unlinked = board
        unlinked.tasks.removeAll { $0.slug == "app-plan-task-15" }
        let plain = try render(list(unlinked))
        #expect(accentPixels(linked) > 100, "the link isn't drawn in the accent color")
        #expect(accentPixels(plain) < accentPixels(linked) / 10)
        if let folder = TeamSnapshots.folder {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            for dark in [false, true] {
                let data = try #require(try render(list(board), dark: dark).representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("team-folded-\(dark ? "dark" : "light").png"))
            }
        }
    }

    @Test func theRenderShowsTheAbandonedRowsWithTheirReason() throws {
        let with = try render(list(Self.withAbandoned()))
        let without = try render(list(Self.board()))
        // Two more rows, one of them with its reason under it.
        #expect(with.pixelsHigh > without.pixelsHigh + 2 * 40, "\(with.pixelsHigh) vs \(without.pixelsHigh)")
        // Nothing red: neither reads failed.
        #expect(redPixels(with) == 0)
        if let folder = TeamSnapshots.folder {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            for dark in [false, true] {
                let data = try #require(try render(list(Self.withAbandoned()), dark: dark).representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("team-abandoned-\(dark ? "dark" : "light").png"))
            }
        }
    }

    /// Pixels drawn in red (a failed mark or its text).
    func redPixels(_ bitmap: NSBitmapImageRep) -> Int {
        var count = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent > 0.75, color.greenComponent < 0.35, color.blueComponent < 0.35 { count += 1 }
            }
        }
        return count
    }
}
