import Foundation
import Testing
@testable import VibeCore

struct TranscriptPathCaptureTests {
    func reduce(_ payload: [String: Any], onto state: HookState? = nil) -> HookState? {
        let update = HookState.reduce(current: state, payload: payload, agent: .claude, tty: "ttys001", agentPid: 42, now: 1000)
        if case .write(let next) = update { return next }
        return state
    }

    @Test func hooksRecordWhereTheTranscriptIs() throws {
        let path = "/Users/me/.claude/projects/-Users-me-app/s1.jsonl"
        let started = try #require(reduce(["hook_event_name": "SessionStart", "session_id": "s1", "transcript_path": path]))
        #expect(started.transcriptPath == path)
        // Events without the field keep it; absurd values are ignored.
        let prompted = try #require(reduce(["hook_event_name": "UserPromptSubmit", "session_id": "s1", "prompt": "hi"], onto: started))
        #expect(prompted.transcriptPath == path)
        let junk = try #require(reduce(["hook_event_name": "Stop", "session_id": "s1",
                                        "transcript_path": String(repeating: "x", count: 5000)], onto: prompted))
        #expect(junk.transcriptPath == path)
    }
}

struct ScrollbackTests {
    @Test func dropsTheVisibleScreenFromTheEnd() {
        #expect(Scrollback.lines(history: "a\nb\nc\nd\n", screen: "c\nd\n") == ["a", "b"])
        #expect(Scrollback.lines(history: "a\nb\nc  \nd   \n\n", screen: "c\nd") == ["a", "b"])
        // No overlap (e.g. the screen just redrew): keep everything rather than guess.
        #expect(Scrollback.lines(history: "a\nb", screen: "zzz") == ["a", "b"])
        #expect(Scrollback.lines(history: "", screen: "x") == [])
    }

    @Test func pagesBackwardsByAbsoluteLineNumber() {
        let lines = (0..<1200).map(String.init)
        let last = Scrollback.page(lines, before: nil, limit: 500)
        #expect(last == Scrollback.Page(lines: Array(lines[700..<1200]), start: 700, total: 1200, first: 0))
        let earlier = Scrollback.page(lines, before: 700, limit: 500)
        #expect(earlier.start == 200)
        #expect(earlier.lines.first == "200")
        let oldest = Scrollback.page(lines, before: 200, limit: 500)
        #expect(oldest.start == 0)
        #expect(oldest.lines.count == 200)
        #expect(Scrollback.page(lines, before: 1200, limit: 9999).lines.count == Scrollback.pageLimit)
    }

    @Test func pagesNeverGoPastWhatExists() {
        let lines = (0..<6000).map(String.init)
        let capped = Scrollback.page(lines, before: 1500, limit: 500)
        #expect(capped.first == 1000)                // only the last 5,000 lines are reachable
        #expect(capped.start == 1000)
        #expect(capped.lines.count == 500)
        #expect(Scrollback.page(lines, before: 900, limit: 500).lines.isEmpty)
        // After `clear`, the phone may ask past the (now shorter) end.
        let shrunk = Scrollback.page(["x", "y"], before: 700, limit: 500)
        #expect(shrunk == Scrollback.Page(lines: ["x", "y"], start: 0, total: 2, first: 0))
        #expect(Scrollback.page(["x"], before: -5, limit: 500).lines.isEmpty)
    }
}
