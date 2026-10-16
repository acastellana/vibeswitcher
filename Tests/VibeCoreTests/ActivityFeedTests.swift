import Foundation
import Testing
@testable import VibeCore

struct ActivityFeedTests {
    func entry(_ kind: TranscriptEntry.Kind, _ id: String) -> TranscriptEntry {
        TranscriptEntry(kind: kind, id: id, text: id)
    }

    @Test func dropsResultsWhoseCallWasBeforeTheTail() {
        let rows = ActivityFeed.rows([entry(.toolResult, "old"), entry(.prompt, "p"), entry(.tool, "t"), entry(.reply, "r")], limit: 10)
        #expect(rows.map(\.id) == ["p", "t", "r"])
    }

    @Test func keepsTheNewest() {
        let rows = ActivityFeed.rows((1...5).map { entry(.reply, "\($0)") }, limit: 2)
        #expect(rows.map(\.id) == ["4", "5"])
    }
}
