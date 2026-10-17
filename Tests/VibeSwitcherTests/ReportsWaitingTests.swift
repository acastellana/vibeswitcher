import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// The lead strip's fallback: reports VibeSwitcher couldn't wake the lead for, counted by the lead's terminal.
struct ReportsWaitingTests {
    @Test func theStripSaysHowManyReportsWait() {
        #expect(reportsWaiting(0) == nil)
        #expect(reportsWaiting(1) == "1 report waiting")
        #expect(reportsWaiting(3) == "3 reports waiting")
    }

    @Test func countedPerLeadUntilItHasThem() {
        let waiting = ReportsWaiting()
        let t = Date().timeIntervalSince1970
        let reports = [SteerMessage(text: "The worker on x says it's done: ok", from: .system("worker x"), agentPid: 7, at: t),
                       SteerMessage(text: "The worker on y is blocked: stuck", from: .system("worker y"), agentPid: 7, at: t + 10)]
        waiting.set(LeadWake.waiting(reports, now: t + 60), tty: "ttys001")
        #expect(waiting.count.isEmpty)
        waiting.set(LeadWake.waiting(reports, now: t + 125), tty: "ttys001")
        waiting.set(1, tty: "ttys002")
        #expect(waiting.count == ["ttys001": 2, "ttys002": 1])
        // Delivered: gone from the strip; a lead that ended: gone too.
        waiting.set(LeadWake.waiting([], now: t + 130), tty: "ttys001")
        waiting.keep(["ttys001"])
        #expect(waiting.count.isEmpty)
    }
}
