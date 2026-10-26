import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// A menu bar dot's tooltip says the state its row says (`LeadTeams.label`): "needs you" is only ever you.
struct MenuBarDotToolTipTests {
    private func session(_ status: SessionStatus, role: LeadLaunch.Role?) -> Session {
        var session = Session(tty: "ttys974", agent: .claude, pid: 1, startedAt: Date(), cwd: "/r/acme", project: "acme",
                              task: nil, status: status, statusSince: Date(), detail: nil, hasHooks: true, inTerminalApp: false)
        session.teamRole = role
        return session
    }

    @Test func aLeadWithAQuestionForYouSaysItNeedsYou() {
        var lead = session(.idle, role: .lead)
        lead.leadAsks = true
        #expect(AppDelegate.dotToolTip(lead, number: 1).contains("acme · \(SessionStatus.needsInput.label)\n"))
    }

    @Test func aWorkerWaitingOnItsLeadDoesntSayItNeedsYou() {
        let tip = AppDelegate.dotToolTip(session(.needsInput, role: .worker), number: 2)
        #expect(tip.hasPrefix("2. acme · \(LeadTeams.waitsOnLeadLabel)\n"))
        #expect(!tip.contains(SessionStatus.needsInput.label))
    }
}
