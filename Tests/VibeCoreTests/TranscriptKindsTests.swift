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

/// What VibeSwitcher hands an agent mid-chat (a wake-up it typed, a hook's added context, a prompt it typed taken
/// mid-turn) reaches the phone's Conversation tab as VibeSwitcher's, under its sender, never as the user's prompt.
struct PhoneNoticeTests {
    func chunk(_ lines: [[String: Any]]) throws -> [TranscriptEntry] {
        var data = Data()
        for line in lines {
            data.append(try JSONSerialization.data(withJSONObject: line))
            data.append(0x0A)
        }
        let plan = TranscriptWindow.Plan(start: 0, fresh: true)
        return TranscriptWindow.chunk(data, plan: plan, fileSize: data.count, format: .claude).entries
    }

    @Test func wakeUpsHookContextAndRelayedWordsAreVibeSwitchersOnThePhone() throws {
        let report = SteerMessage(text: "The worker on sidebardifftests-leave says it's done: cleaned up", from: .system("worker sidebardifftests-leave"), agentPid: 1)
        let answer = SteerMessage(text: "use SQLite", from: .user, agentPid: 1)
        let context = SteerReply.context([report, answer])
        let wake = LeadDelivery.typed(LeadWake.prompt([report]), from: .system("reports"))
        let entries = try chunk([
            ["type": "user", "uuid": "u1", "timestamp": "2026-10-28T10:18:51.000Z", "message": ["role": "user", "content": "close the PR"]],
            ["type": "attachment", "uuid": "a1", "timestamp": "2026-10-28T10:19:04.023Z",
             "attachment": ["type": "hook_additional_context", "hookEvent": "Stop", "content": [context]]],
            ["type": "user", "uuid": "u2", "timestamp": "2026-10-28T10:19:07.415Z", "message": ["role": "user", "content": wake]],
            ["type": "attachment", "uuid": "a2", "timestamp": "2026-10-28T10:20:00.000Z",
             "attachment": ["type": "queued_command", "prompt": LeadDelivery.typed("Merge project-lead in now", from: .lead("lead of vibeswitcher"))]],
        ])
        #expect(entries.map(\.kind) == [.prompt, .notice, .notice, .notice, .notice])
        #expect(entries[0].text == "close the PR" && entries[0].from == nil)
        #expect(entries[1].from == "Report from the worker on sidebardifftests-leave" && entries[1].text.hasPrefix("The worker on sidebardifftests-leave says it's done"))
        #expect(entries[2].from == "You, relayed by VibeSwitcher" && entries[2].text == "use SQLite")
        #expect(entries[3].from == "VibeSwitcher: reports are waiting" && entries[3].text == "1 new report (worker sidebardifftests-leave done). Call status.")
        #expect(entries[4].from == "Message from lead of vibeswitcher" && entries[4].text == "Merge project-lead in now")
        #expect(entries[3].json["from"] as? String == "VibeSwitcher: reports are waiting" && entries[3].json["kind"] as? String == "notice")
        // Nowhere else: the summaries and digests read what the agent was told by the user only.
        var data = Data()
        data.append(try JSONSerialization.data(withJSONObject: ["type": "user", "uuid": "u2", "message": ["role": "user", "content": wake]]))
        data.append(0x0A)
        #expect(TranscriptReader.read(data, format: .claude).entries.isEmpty)
    }
}
