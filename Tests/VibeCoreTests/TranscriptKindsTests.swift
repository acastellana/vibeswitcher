import Foundation
import Testing
@testable import VibeCore

/// Claude Code 2.1.300+ records every API request in the transcript (in the lead's 130 MB Opus 5.5 session, 742
/// `api-request` lines held 72 MB). Readers skip such lines by their first bytes.
struct TranscriptKindsTests {
    /// The shape of a real `api-request` line (2.1.301), its parameters cut down.
    static func apiRequest(padding: Int = 100_000) -> String {
        let params = #"{"model":"claude-opus-5-5","max_tokens":64000,"thinking":{"type":"adaptive"},"output_config":{"effort":"xhigh"},"pad":""#
            + String(repeating: "x", count: padding) + #""}"#
        return #"{"type":"api-request","sessionId":"00000000-0000-4000-8000-000000000001","id":"ab0b7606-0208-4546-a6a5-c58bed13f058","timestamp":"2026-10-16T09:00:31.873Z","version":"2.1.301","querySource":"repl_main_thread","shapeHash":"d332","params":"#
            + params + #","base":"b","keep":3,"tail":[],"cacheControl":[],"requestDigest":"e5"}"#
    }

    static let others = [
        #"{"type":"api-request-blob","sessionId":"00000000-0000-4000-8000-000000000001","hash":"81da","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}"#,
        #"{"type":"api-request-shape","sessionId":"00000000-0000-4000-8000-000000000001","shapeHash":"d332","shape":{"tools":[]}}"#,
        #"{"type":"permission-mode","permissionMode":"bypassPermissions","sessionId":"00000000-0000-4000-8000-000000000001"}"#,
        #"{"type":"ai-title","aiTitle":"VibeSwitcher startup failure","sessionId":"00000000-0000-4000-8000-000000000001"}"#,
        #"{"type":"file-history-delta","messageId":"715d","snapshotMessageId":"1340","backup":{}}"#,
    ]

    func line(_ text: String) -> Data.SubSequence { Data(text.utf8)[...] }

    @Test func unusedKindsAreToldByTheirFirstBytes() {
        #expect(TranscriptReader.skippable(line(Self.apiRequest())))
        for other in Self.others { #expect(TranscriptReader.skippable(line(other)), "\(other.prefix(40))") }
        // Kept: conversation lines (whatever their first key), Codex's, and anything that isn't `{"type":"…` first.
        for kept in [#"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"hi"}}"#,
                     #"{"type":"user","uuid":"u1","message":{"role":"user","content":"hi"}}"#,
                     #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[]}}"#,
                     #"{"type":"attachment","attachment":{"type":"queued_command"}}"#,
                     #"{"type":"system","subtype":"turn_duration"}"#,
                     #"{"timestamp":"2026-10-16T10:00:00Z","type":"response_item","payload":{}}"#,
                     #"{"type":"event_msg","payload":{"type":"token_count"}}"#,
                     #"{"type":"turn_context","payload":{"model":"gpt-5.5-codex"}}"#,
                     #"{"type":"#, #"{"type":"api-request"#, "", "not json"] {
            #expect(!TranscriptReader.skippable(line(kept)), "\(kept.prefix(40))")
        }
    }

    /// Mixed into a real Opus 5.5 turn, the request records change nothing the chat, the phone or the tail read.
    @Test func readersSeeTheSameConversationWithRequestRecordsBetween() {
        let turn = ClaudeFixtures.thinkingBetweenTools.split(separator: "\n").map(String.init)
        var mixed: [String] = []
        for (index, line) in turn.enumerated() {
            mixed.append(line)
            if index % 2 == 0 { mixed += [Self.apiRequest(padding: 2_000)] + Self.others }
        }
        let plain = Data((turn.joined(separator: "\n") + "\n").utf8), withRequests = Data((mixed.joined(separator: "\n") + "\n").utf8)
        var a = ChatLog(), b = ChatLog()
        a.append(ChatReader.read(plain, format: .claude).events)
        b.append(ChatReader.read(withRequests, format: .claude).events)
        #expect(a == b && !a.entries.isEmpty)
        #expect(TranscriptReader.read(plain, format: .claude).entries == TranscriptReader.read(withRequests, format: .claude).entries)
        #expect(TranscriptTail.read(plain) == TranscriptTail.read(withRequests))
        #expect(ChatReader.read(withRequests, format: .claude).consumed == withRequests.count)
    }
}
