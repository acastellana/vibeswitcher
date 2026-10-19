import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// A team message's TL;DR in the chat: from the Team view's summaries (same helper, model and cache), once per
/// message, nothing with summaries off.
struct TeamMessageSummaryTests {
    final class Fake: @unchecked Sendable {
        var prompts: [String] = []
        var answer: String? = "The chat layout is fixed and its tests pass"
        var now: Double = 0
    }

    func model(_ fake: Fake) -> TeamSummaryModel {
        TeamSummaryModel(generate: { fake.prompts.append($0); return fake.answer }, now: { fake.now },
                         run: { $0() }, deliver: { $0() }, perform: { $0() })
    }

    static let long = TeamMessage(sender: .vibeSwitcher("worker fix-the-chat-layout"),
                                  body: "The worker on fix-the-chat-layout says it's done: " + String(repeating: "Checked the list scrolls. ", count: 20)
                                      + "\nRun audit(fix-the-chat-layout); only the verifier's report counts.")

    @Test func aLongReportGetsOneSummaryFromTheHelperOnce() {
        let fake = Fake()
        let model = model(fake)
        #expect(model.line(Self.long, id: "a1.0") == nil)
        model.request(Self.long, id: "a1.0")
        #expect(fake.prompts.count == 1)
        #expect(fake.prompts[0].contains("Report from the worker on fix-the-chat-layout") && fake.prompts[0].contains("Checked the list scrolls."))
        #expect(model.line(Self.long, id: "a1.0") == "The chat layout is fixed and its tests pass")
        // Shown again, long after, even after a failure: never a second run for the same message.
        fake.now = 10_000
        model.request(Self.long, id: "a1.0")
        #expect(fake.prompts.count == 1)
        // Another message is another run.
        model.request(Self.long, id: "b2.0")
        #expect(fake.prompts.count == 2)
    }

    @Test func aFailedSummaryIsntTriedAgain() {
        let fake = Fake()
        fake.answer = nil
        let model = model(fake)
        model.request(Self.long, id: "a1.0")
        fake.now = 10_000
        fake.answer = "too late"
        model.request(Self.long, id: "a1.0")
        #expect(fake.prompts.count == 1)
        #expect(model.line(Self.long, id: "a1.0") == nil)
    }

    @Test func nothingWithSummariesOff() {
        let fake = Fake()
        let model = model(fake)
        model.enabled = false
        model.request(Self.long, id: "a1.0")
        #expect(fake.prompts.isEmpty)
        #expect(model.line(Self.long, id: "a1.0") == nil)
        // Turned on later: asked for then; turned off again: not shown.
        model.enabled = true
        model.request(Self.long, id: "a1.0")
        #expect(fake.prompts.count == 1)
        model.enabled = false
        #expect(model.line(Self.long, id: "a1.0") == nil)
    }

    @Test func shortMessagesAndTheUsersOwnWordsGetNone() {
        let fake = Fake()
        let model = model(fake)
        model.request(TeamMessage(sender: .vibeSwitcher("verifier x"), body: "The audit of x passed (complete, clean): fine"), id: "s")
        model.request(TeamMessage(sender: .user, body: String(repeating: "my long answer ", count: 40)), id: "u")
        #expect(fake.prompts.isEmpty)
    }
}
