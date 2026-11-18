import Foundation
import Testing
@testable import VibeCore

/// The handover at a long idle (`LeadRotation.idle`, `handover_idle_min:`, `handover_tokens:`), on an injected clock and
/// made-up transcripts: timestamps and token counts only. The controller's side is in LeadRotationTests.
struct LeadIdleHandoverTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let stamp = ISO8601DateFormatter()

    func line(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
    }

    func reply(at: Date, tokens: (input: Int, read: Int, write: Int), sidechain: Bool = false) throws -> String {
        try line(["type": "assistant", "isSidechain": sidechain, "timestamp": stamp.string(from: at),
                  "message": ["role": "assistant", "content": [["type": "text", "text": "x"]],
                              "usage": ["input_tokens": tokens.input, "cache_read_input_tokens": tokens.read,
                                        "cache_creation_input_tokens": tokens.write, "output_tokens": 9]]])
    }

    @Test func theTailIsTheMainConversationsLastResponseAndAnyCompactionAfterIt() throws {
        let early = now.addingTimeInterval(-3600), late = now.addingTimeInterval(-3000)
        var text = try reply(at: early, tokens: (3, 100_000, 2_000))
        text += try reply(at: late, tokens: (2, 230_000, 8_000))
        text += try reply(at: now, tokens: (1, 20_000, 500), sidechain: true)   // a subagent's: not the lead's context
        let tail = try #require(LeadRotation.tail(Data(text.utf8)))
        #expect(tail == LeadRotation.Tail(lastResponse: late, contextTokens: 238_002))
        text += try line(["type": "system", "subtype": "compact_boundary", "timestamp": stamp.string(from: now),
                          "compactMetadata": ["trigger": "auto", "preTokens": 238_002, "postTokens": 40_000]])
        #expect(LeadRotation.tail(Data(text.utf8))?.compacted == true)
        text += try reply(at: now, tokens: (5, 0, 41_000))
        #expect(LeadRotation.tail(Data(text.utf8)) == LeadRotation.Tail(lastResponse: now, contextTokens: 41_005))
        #expect(LeadRotation.tail(Data(try line(["type": "user", "timestamp": stamp.string(from: now)]).utf8)) == nil)
    }

    @Test func idleRuleNeedsBothThresholdsAndNoCompaction() {
        let big = LeadRotation.Tail(lastResponse: now.addingTimeInterval(-51 * 60), contextTokens: 238_000)
        let reason = LeadRotation.idle(tail: big, idleMinutes: 50, tokens: 150_000, now: now)
        #expect(reason == "the last one had been idle 51 minutes with 238k tokens of context, past handover_idle_min 50 and handover_tokens 150k")
        #expect(LeadRotation.idle(tail: big, idleMinutes: 50, tokens: 150_000, now: now.addingTimeInterval(-2 * 60)) == nil, "49 minutes")
        var small = big; small.contextTokens = 149_999
        #expect(LeadRotation.idle(tail: small, idleMinutes: 50, tokens: 150_000, now: now) == nil)
        var compacted = big; compacted.compacted = true
        #expect(LeadRotation.idle(tail: compacted, idleMinutes: 50, tokens: 150_000, now: now) == nil)
        #expect(LeadRotation.idle(tail: big, idleMinutes: 0, tokens: 150_000, now: now) == nil, "off")
        #expect(LeadRotation.idle(tail: big, idleMinutes: 50, tokens: 0, now: now) == nil, "off")
        #expect(LeadRotation.idle(tail: nil, idleMinutes: 50, tokens: 150_000, now: now) == nil)
        #expect(!LeadRotation.cold(tail: big, now: now) && !LeadRotation.cold(tail: big, now: now.addingTimeInterval(4 * 60))
                && LeadRotation.cold(tail: big, now: now.addingTimeInterval(5 * 60)), "Cold from minute 55: a note asked then could land past the hour")
    }

    /// A fresh lead starts near 80k tokens: a threshold under 100k would hand it over every idle hour all night.
    @Test func aFreshLeadIsNeverHandedOverAgainHoweverLowTheSettings() {
        let fresh = LeadRotation.Tail(lastResponse: now.addingTimeInterval(-11 * 60), contextTokens: 80_000)
        #expect(LeadRotation.idle(tail: fresh, idleMinutes: 1, tokens: 1, now: now) == nil)
        #expect(LeadRotation.idleMinutes(1) == 10 && LeadRotation.idleMinutes(0) == 0 && LeadRotation.idleMinutes(-5) == 0)
        #expect(LeadRotation.tokens(50_000) == 100_000 && LeadRotation.tokens(0) == 0 && LeadRotation.tokens(200_000) == 200_000)
        let grown = LeadRotation.Tail(lastResponse: now.addingTimeInterval(-11 * 60), contextTokens: 100_000)
        #expect(LeadRotation.idle(tail: grown, idleMinutes: 1, tokens: 1, now: now) != nil)
    }

    @Test func anOpenConversationHoldsTheHandover() {
        let t = now.timeIntervalSince1970
        #expect(LeadRotation.conversationOpen(openQuestionsAskedAt: [t - 5 * 60], asking: false, now: now))
        #expect(!LeadRotation.conversationOpen(openQuestionsAskedAt: [t - 20 * 60], asking: false, now: now))
        #expect(LeadRotation.conversationOpen(openQuestionsAskedAt: [], asking: true, now: now))
        #expect(!LeadRotation.conversationOpen(openQuestionsAskedAt: [], asking: false, now: now))
    }

    @Test func theThresholdsAreWorkflowSettingsWithTheMeasuredDefaults() {
        #expect(LeadWorkflow().handoverIdleMinutes == 50 && LeadWorkflow().handoverTokens == 150_000)
        let template = LeadWorkflow.parse(LeadWorkflow.template)
        #expect(template.handoverIdleMinutes == 50 && template.handoverTokens == 150_000)
        #expect(template.settings["handover_idle_min"] == "50" && template.settings["handover_tokens"] == "150000")
        let set = LeadWorkflow.parse("---\nhandover_idle_min: 90\nhandover_tokens: 300000\n---\n")
        #expect(set.handoverIdleMinutes == 90 && set.handoverTokens == 300_000)
        let low = LeadWorkflow.parse("---\nhandover_idle_min: 3\nhandover_tokens: 20000\n---\n")
        #expect(low.handoverIdleMinutes == 10 && low.handoverTokens == 100_000)
        let off = LeadWorkflow.parse("---\nhandover_idle_min: 0\nhandover_tokens: soon\n---\n")
        #expect(off.handoverIdleMinutes == 0 && off.handoverTokens == 150_000)
        #expect(LeadWorkflow.configurable.contains("handover_idle_min") && LeadWorkflow.configurable.contains("handover_tokens"))
    }

    @Test func configureSetsTheThresholds() throws {
        let url = temp.url("idle-lead")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        let lead = try lead(root, FakeRuntime())
        #expect(lead.call("configure", [:]).text.contains("handover_idle_min: 50, handover_tokens: 150000"))
        #expect(lead.call("configure", ["handover_idle_min": 5]).isError)
        #expect(lead.call("configure", ["handover_tokens": 50_000]).isError)
        let set = lead.call("configure", ["handover_idle_min": 40, "handover_tokens": 200_000])
        #expect(!set.isError, "\(set.text)")
        let workflow = LeadWorkflow.load(from: lead.workflowPath)
        #expect(workflow.handoverIdleMinutes == 40 && workflow.handoverTokens == 200_000)
        #expect(!lead.call("configure", ["handover_idle_min": 0]).isError)
        #expect(lead.call("configure", [:]).text.contains("(off: no handover at a long idle)"))
        #expect(!lead.call("configure", ["handover_idle_min": "", "handover_tokens": ""]).isError)
        #expect(LeadWorkflow.load(from: lead.workflowPath).handoverIdleMinutes == 50)
    }
}
