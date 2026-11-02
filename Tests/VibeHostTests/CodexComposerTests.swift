import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// Codex's composer as `LeadDelivery` reads it, from a real Codex CLI 0.160 screen: an idle Codex worker under the
/// session host, captured by the on-demand `CodexWorkerHostRunTests` (its screen text and styled runs, as the host
/// gave them, at 120×40). Above the composer the account's "Set up security" notice sits in the transcript, with its
/// own `› 1.` row; a paste and Enter still go to the composer (checked on a scratch pty: the prompt was answered).
/// The variants change only the composer's rows, as Codex draws them: typed text plain, its placeholder faint.
struct CodexComposerTests {
    struct Captured: Decodable {
        var text: String
        var runs: [ScreenRun]?
    }

    func idle() throws -> LeadDelivery.Screen {
        let url = try #require(Bundle.module.url(forResource: "codex-0.160-idle-120x40", withExtension: "json", subdirectory: "Fixtures"))
        let captured = try JSONDecoder().decode(Captured.self, from: Data(contentsOf: url))
        return LeadDelivery.Screen(text: captured.text, runs: captured.runs)
    }

    /// The idle screen with its composer's row (the last `›` row) replaced by `rows`, none of them drawn faint.
    func composing(_ rows: [String]) throws -> LeadDelivery.Screen {
        let screen = try idle()
        var lines = screen.text.components(separatedBy: "\n")
        let composer = try #require(lines.lastIndex { $0.hasPrefix("›") })
        // Its rows go upward from the composer's row, into the blank rows above it, keeping one blank row on top.
        let first = composer - (rows.count - 1)
        try #require(lines[first - 1].trimmingCharacters(in: .whitespaces).isEmpty)
        lines.replaceSubrange(first...composer, with: rows)
        let runs = screen.runs?.filter { !(first...composer).contains($0.row) }
        return LeadDelivery.Screen(text: lines.joined(separator: "\n"), runs: runs)
    }

    @Test func theCapturedIdleComposerIsEmpty() throws {
        let screen = try idle()
        // It is what it was captured as: the notice's choice above, the faint placeholder in the composer.
        #expect(screen.text.contains("› 1. Set up security") && screen.text.contains("› Ask Codex to do anything"))
        let row = try #require(screen.text.components(separatedBy: "\n").lastIndex { $0.hasPrefix("›") })
        #expect(screen.runs?.filter { $0.row == row } == [ScreenRun(row: row, column: 2, length: 24, faint: true)])
        #expect(LeadDelivery.box(in: screen) == .empty)
        // A host that doesn't say what's faint: its plain placeholder is told by its wording.
        #expect(LeadDelivery.box(in: screen.text) == .empty)
    }

    @Test func anExamplePromptPlaceholderIsEmptyOnlyWhenItsDrawnFaint() throws {
        var screen = try composing(["› Find and fix a bug in @filename"])
        let row = try #require(screen.text.components(separatedBy: "\n").lastIndex { $0.hasPrefix("›") })
        screen.runs?.append(ScreenRun(row: row, column: 2, length: 31, faint: true))
        #expect(LeadDelivery.box(in: screen) == .empty)
        #expect(LeadDelivery.box(in: screen.text) == .draft("Find and fix a bug in @filename"))
    }

    @Test func typedTextIsADraftAndKeepsItsRows() throws {
        #expect(LeadDelivery.box(in: try composing(["› fix the flaky test"])) == .draft("fix the flaky test"))
        #expect(LeadDelivery.box(in: try composing(["› fix the flaky test", "  in LeadBoardTests"])) == .draft("fix the flaky test\nin LeadBoardTests"))
    }

    /// A numbered choice where the composer was (an approval or a question Codex asks) is a dialog: typing there would answer it.
    @Test func aNumberedChoiceInPlaceOfTheComposerIsADialog() throws {
        guard case .dialog = LeadDelivery.box(in: try composing(["› 1. Yes, proceed (y)", "  2. No, and tell Codex what to do differently (esc)"])) else {
            Issue.record("a numbered choice read as a box"); return
        }
    }

    @Test func aScreenWithoutTheComposersShapeIsADialog() throws {
        // No blank row between the composer and its footer.
        var lines = try idle().text.components(separatedBy: "\n")
        let composer = try #require(lines.lastIndex { $0.hasPrefix("›") })
        lines[composer + 1] = "  Would you like to run the following command?"
        guard case .dialog = LeadDelivery.box(in: lines.joined(separator: "\n")) else { Issue.record("read as a box"); return }
        // Nothing but transcript.
        guard case .dialog = LeadDelivery.box(in: "• Ran git status\n  └ (no output)\n") else { Issue.record("read as a box"); return }
    }
}
