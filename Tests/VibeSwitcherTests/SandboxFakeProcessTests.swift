import Foundation
import Testing
@testable import VibeSwitcher

/// The sandbox's fake sessions keep their identity from one scan to the next: a phone's session id holds the process's
/// start time, so a start time taken afresh at each scan made every input "session changed".
struct SandboxFakeProcessTests {
    @Test func aFakeProcessKeepsItsStartTimeAcrossScans() throws {
        let first = Sandbox.fakeProcessTable(claude: ["ttys001": 10_001], codex: ["ttys002": 10_002])
        let second = Sandbox.fakeProcessTable(claude: ["ttys001": 10_001], codex: ["ttys002": 10_002])
        for pid: Int32 in [10_001, 10_002, 60_000] {
            let a = try #require(first[pid]), b = try #require(second[pid])
            #expect(a.startTime == b.startTime, "pid \(pid) started at a different time in the next scan")
        }
    }
}
