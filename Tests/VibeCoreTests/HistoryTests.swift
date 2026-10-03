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
