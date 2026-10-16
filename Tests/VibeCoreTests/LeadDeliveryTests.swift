import Foundation
import Testing
@testable import VibeCore

struct LeadDeliveryTests {
    func state(_ event: String) -> HookState { HookState(agent: .claude, tty: "ttys1", lastEvent: event, lastEventAt: 0) }

    @Test func idleAgentsGetATypedPromptWorkingOnesASteer() {
        #expect(LeadDelivery.way(for: state("Stop")) == .type)
        #expect(LeadDelivery.way(for: state("SessionStart")) == .type)
        #expect(LeadDelivery.way(for: state("PreToolUse")) == .steer)
        #expect(LeadDelivery.way(for: state("PostToolUse")) == .steer)
        #expect(LeadDelivery.way(for: state("UserPromptSubmit")) == .steer)
        #expect(LeadDelivery.way(for: nil) == .type)
    }

    @Test func typedSystemMessagesAreMarkedAndNotTheUsers() {
        let text = LeadDelivery.typed("Worker add-b finished.", from: .system("worker add-b"))
        #expect(text.hasPrefix("[VibeSwitcher"))
        #expect(TypedText.agentMessage(text)?.body == "Worker add-b finished.")
        #expect(ChatReader.humanText(text) == nil)
        // An answer from the user is the user's words.
        #expect(LeadDelivery.typed("SQLite", from: .user) == "SQLite")
    }
}
