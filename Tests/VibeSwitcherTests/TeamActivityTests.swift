import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

struct TeamActivityTests {
    @Test func holdsUntilThreeMinutesAfterLastWorkAndCancelsIdleRelease() {
        var time: TimeInterval = 0
        var begins = 0
        var ends = 0
        let activity = TeamActivity(now: { time }, begin: { begins += 1; return NSObject() }, end: { _ in ends += 1 })
        activity.update(working: false)
        time = 1000
        activity.update(working: false)
        #expect(begins == 0)
        activity.update(working: true)
        #expect(begins == 1)
        time += 600
        activity.update(working: true)
        #expect(ends == 0)
        activity.update(working: false)
        time += 179
        activity.update(working: false)
        #expect(ends == 0)
        activity.update(working: true)
        #expect(begins == 1)
        time += 600
        activity.update(working: false)
        time += 180
        activity.update(working: false)
        #expect(ends == 1)
        activity.update(working: false)
        #expect(ends == 1)
        activity.update(working: true)
        #expect(begins == 2)
    }

    @Test func teamSessionStartsLeadTurnsAndHeavyRuns() {
        var team = KeepAwakeTests.Team()
        var hosted = team.hosted.values.map { $0 }
        var time: TimeInterval = 0
        var begins = 0
        var ends = 0
        let activity = TeamActivity(now: { time }, begin: { begins += 1; return NSObject() }, end: { _ in ends += 1 })
        func look() { activity.update(working: TeamActivity.working(hosted: hosted, sessions: Array(team.sessions.values), heavy: false)) }
        look()
        #expect(begins == 0)
        // Live team sessions count even before the scan has observed an agent or its first hook.
        let workerID = UUID(uuidString: team.worker)!
        let index = hosted.firstIndex { $0.id == workerID }!
        hosted[index].label = "Worker: Fix"
        look()
        #expect(begins == 1)
        time += 600
        look()
        #expect(ends == 0)
        #expect(TeamActivity.working(hosted: hosted, sessions: [], heavy: false))
        hosted[index].exit = HostSession.Exit(status: 0, at: Date())
        look()
        time += 180
        look()
        #expect(ends == 1)
        #expect(!TeamActivity.working(hosted: hosted, sessions: [], heavy: false))
        let leadID = UUID(uuidString: team.lead)!
        hosted[hosted.firstIndex { $0.id == leadID }!].label = "Lead · project"
        team.sessions[team.lead]?.status = .working
        #expect(TeamActivity.working(hosted: hosted, sessions: Array(team.sessions.values), heavy: false))
        team.sessions[team.lead]?.status = .needsInput
        #expect(!TeamActivity.working(hosted: hosted, sessions: Array(team.sessions.values), heavy: false))
        #expect(TeamActivity.working(hosted: [], sessions: [], heavy: true))
        #expect(!TeamActivity.working(hosted: [], sessions: [], heavy: false))
        #expect(!TeamActivity.options.contains(.idleSystemSleepDisabled))
        #expect(!TeamActivity.options.contains(.latencyCritical))
    }

    @Test func liveIdleMembersAllowDelayedRelease() {
        for role in ["Worker: Fix", "Verifier: Fix"] {
            var team = KeepAwakeTests.Team()
            var member = team.hosted[team.worker]!
            member.label = role
            var time: TimeInterval = 0
            var ends = 0
            let activity = TeamActivity(now: { time }, begin: { NSObject() }, end: { _ in ends += 1 })
            team.sessions[team.worker]?.status = .working
            activity.update(working: TeamActivity.working(hosted: [member], sessions: Array(team.sessions.values), heavy: false))
            for status in [SessionStatus.needsInput, .idle, .done, .unknown] {
                team.sessions[team.worker]?.status = status
                let working = TeamActivity.working(hosted: [member], sessions: Array(team.sessions.values), heavy: false)
                #expect(!working)
                activity.update(working: working)
            }
            time += 180
            activity.update(working: TeamActivity.working(hosted: [member], sessions: Array(team.sessions.values), heavy: false))
            #expect(ends == 1)
        }
    }

    @Test func releasesWhenOwnerGoesAway() {
        var ends = 0
        var activity: TeamActivity? = TeamActivity(begin: { NSObject() }, end: { _ in ends += 1 })
        activity?.update(working: true)
        activity = nil
        #expect(ends == 1)
    }
}
