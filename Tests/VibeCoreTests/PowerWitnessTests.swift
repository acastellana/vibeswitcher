import Foundation
import Testing
@testable import VibeCore

/// The lead learns of power from the witness, as it does of low disk space, but only when it matters: on battery
/// under the user's limit (Settings, "On battery, pause lead work below N %", 50 at first, 0 never) it's told once to
/// hold, and once to resume when AC power returns, only after a hold; an unplug above the limit tells nothing (on
/// 2026-10-20 the Mac was unplugged six times, mostly at 85–100 %). Status says "on battery" while it lasts, and the
/// hold with it, so a lead after a handover knows without being told. A fake power source stands in for IOKit.
struct PowerWitnessTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    /// A power source whose readings the test sets.
    final class FakePower: @unchecked Sendable {
        var state: PowerState?
        func read() -> PowerState? { state }
    }

    func repo() throws -> String {
        let url = temp.url("power-lead")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    /// The limit in Settings, as a test sets it (50 at first).
    final class Limit: @unchecked Sendable { var value = PowerWatch.defaultLimit }

    /// The witness with `fake`'s readings, holding under `limit`.
    func watching(_ fake: FakePower, _ limit: Limit = Limit()) -> LeadWitness.Power {
        LeadWitness.Power(read: fake.read, limit: { limit.value }, file: temp.url("power.json"))
    }

    static let hold = "under your 50 % limit: start no workers or audits and merge nothing until AC power returns; work in flight finishes."

    @Test func anUnplugAboveTheLimitTellsNothing() {
        let fake = FakePower()
        var witness = watching(fake)
        fake.state = PowerState(onBattery: false, percent: 90, charging: true)
        #expect(witness.look() == nil)
        // Unplugged at 85 %, 50 %: at or above the limit, nothing to tell.
        fake.state = PowerState(onBattery: true, percent: 85, minutesLeft: 300)
        #expect(witness.look() == nil)
        fake.state = PowerState(onBattery: true, percent: 50, minutesLeft: 170)
        #expect(witness.look() == nil)
        // Plugged back in after no hold: nothing either.
        fake.state = PowerState(onBattery: false, percent: 51, charging: true)
        #expect(witness.look() == nil)
        // Unplugged and plugged in again, six times: still nothing.
        for percent in 60...65 {
            fake.state = PowerState(onBattery: true, percent: percent)
            #expect(witness.look() == nil)
            fake.state = PowerState(onBattery: false, percent: percent, charging: true)
            #expect(witness.look() == nil)
        }
    }

    @Test func droppingUnderTheLimitHoldsOnceAndACPowerResumes() throws {
        let fake = FakePower()
        var witness = watching(fake)
        fake.state = PowerState(onBattery: true, percent: 52, minutesLeft: 180)
        #expect(witness.look() == nil)
        // Under the limit while on battery: told once, with the charge, the limit and the time left.
        fake.state = PowerState(onBattery: true, percent: 49, minutesLeft: 170)
        let look = witness.look()
        let told = try #require(look)
        #expect(told == "On battery: 49 %, " + Self.hold + " About 2:50 left.")
        // The charge falling further: no repeat.
        fake.state = PowerState(onBattery: true, percent: 40)
        #expect(witness.look() == nil)
        // A point back up (the reading's noise): no resume, no repeat.
        fake.state = PowerState(onBattery: true, percent: 51)
        #expect(witness.look() == nil)
        fake.state = PowerState(onBattery: true, percent: 30)
        #expect(witness.look() == nil)
        // Plugged in after the hold: told once to resume.
        fake.state = PowerState(onBattery: false, percent: 31, charging: true)
        let resumed = witness.look()
        let back = try #require(resumed)
        #expect(back == "On AC power: resume starts and merges (31 %, charging).")
        fake.state = PowerState(onBattery: false, percent: 60, charging: true)
        #expect(witness.look() == nil)
        // Unplugged again under the limit (no estimate yet): a new hold, told once.
        fake.state = PowerState(onBattery: true, percent: 45)
        #expect(witness.look() == "On battery: 45 %, " + Self.hold)
        #expect(witness.look() == nil)
    }

    @Test func atZeroTheWitnessNeverHolds() {
        let fake = FakePower()
        let limit = Limit()
        limit.value = 0
        var witness = watching(fake, limit)
        for percent in [90, 40, 10, 3, 1] {
            fake.state = PowerState(onBattery: true, percent: percent)
            #expect(witness.look() == nil)
        }
        fake.state = PowerState(onBattery: false, percent: 2, charging: true)
        #expect(witness.look() == nil)
        // Kept as 0 whatever it's set to below 0; between 1 and 9 it's 10, above 90 it's 90.
        #expect([-5, 0, 1, 9, 10, 50, 90, 95].map(PowerWatch.clamp) == [0, 0, 10, 10, 10, 50, 90, 90])
        limit.value = -1
        fake.state = PowerState(onBattery: true, percent: 1)
        #expect(witness.look() == nil)
    }

    @Test func aLimitChangedOnBatteryIsTold() throws {
        let fake = FakePower()
        let limit = Limit()
        var witness = watching(fake, limit)
        fake.state = PowerState(onBattery: true, percent: 60)
        #expect(witness.look() == nil)
        // Raised over the charge: a hold, under the new limit.
        limit.value = 70
        #expect(witness.look() == "On battery: 60 %, under your 70 % limit: start no workers or audits and merge nothing until AC power returns; work in flight finishes.")
        // Raised further while held: nothing new.
        limit.value = 80
        #expect(witness.look() == nil)
        // Lowered, still over the charge: still held, nothing new.
        limit.value = 65
        #expect(witness.look() == nil)
        // Lowered under the charge: resume (the lead would wait on AC power for nothing).
        limit.value = 55
        #expect(witness.look() == "On battery: 60 %, no longer under your limit (now 55 %): resume starts and merges.")
        #expect(witness.look() == nil)
        // The charge crossing it then: a hold again; turned off under a hold: resume, and AC power after says nothing.
        fake.state = PowerState(onBattery: true, percent: 54)
        #expect(witness.look() == "On battery: 54 %, under your 55 % limit: start no workers or audits and merge nothing until AC power returns; work in flight finishes.")
        limit.value = 0
        #expect(witness.look() == "On battery: 54 %, no longer under your limit (now off): resume starts and merges.")
        fake.state = PowerState(onBattery: false, percent: 54, charging: true)
        #expect(witness.look() == nil)
    }

    @Test func theEstimateIsLeftOutWhileUnknownAndNotChargingIsSaid() {
        #expect(PowerState(onBattery: true, percent: 98).text == "On battery: 98 %")
        #expect(PowerState(onBattery: true, percent: 50, minutesLeft: 5).text == "On battery: 50 %, about 0:05 left")
        #expect(PowerState(onBattery: false, percent: 100, charging: false).text == "On AC power: 100 %, not charging")
    }

    @Test func aFailedReadingChangesNothing() throws {
        let fake = FakePower()
        var witness = watching(fake)
        fake.state = PowerState(onBattery: true, percent: 45)
        #expect(witness.look() == "On battery: 45 %, " + Self.hold)
        // A Mac without a battery, or a reading that failed: no switch, the hold kept.
        fake.state = nil
        #expect(witness.look() == nil)
        fake.state = PowerState(onBattery: true, percent: 44)
        #expect(witness.look() == nil)
        fake.state = PowerState(onBattery: false, percent: 44, charging: false)
        #expect(witness.look() == "On AC power: resume starts and merges (44 %, not charging).")
        // On battery under the limit at the first reading (the app started unplugged): told, since the lead can't
        // know otherwise; above it, not.
        var fresh = LeadWitness.Power(read: { PowerState(onBattery: true, percent: 40) }, file: temp.url("power.json"))
        #expect(fresh.look() == "On battery: 40 %, " + Self.hold)
        #expect(fresh.look() == nil)
        var above = LeadWitness.Power(read: { PowerState(onBattery: true, percent: 80) }, file: temp.url("power.json"))
        #expect(above.look() == nil)
    }

    @Test func eachReadingIsKeptForStatusUntilItsStale() {
        let file = temp.url("power.json")
        var witness = LeadWitness.Power(read: { PowerState(onBattery: true, percent: 74, at: 1_000) }, file: file)
        #expect(witness.look() == nil)
        #expect(PowerState.load(from: file, now: Date(timeIntervalSince1970: 1_060))?.statusText == "on battery, 74 %")
        // The app's from before it quit or the Mac slept isn't told as now.
        #expect(PowerState.load(from: file, now: Date(timeIntervalSince1970: 1_000 + PowerState.stale)) == nil)
        #expect(PowerState(onBattery: false, percent: 74).statusText == nil)
        // Under the limit, the hold is kept with the reading; on AC power it's gone.
        let fake = FakePower()
        var held = LeadWitness.Power(read: fake.read, file: file)
        fake.state = PowerState(onBattery: true, percent: 45, at: 2_000)
        _ = held.look()
        #expect(PowerState.load(from: file, now: Date(timeIntervalSince1970: 2_060))?.statusText
            == "on battery, 45 %, under your 50 % limit (no new starts or merges until AC power returns)")
        fake.state = PowerState(onBattery: false, percent: 45, charging: true, at: 2_060)
        _ = held.look()
        #expect(PowerState.load(from: file, now: Date(timeIntervalSince1970: 2_100))?.heldUnder == nil)
        // A file from before the hold was kept decodes, with none.
        try? Data(#"{"onBattery":true,"percent":30,"charging":false,"at":3000}"#.utf8).write(to: file)
        #expect(PowerState.load(from: file, now: Date(timeIntervalSince1970: 3_010))?.statusText == "on battery, 30 %")
    }

    @Test func statusSaysOnBatteryInItsHeaderAndTheHoldWhileItLasts() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        // Above the limit: on battery, nothing held.
        lead.power = { PowerState(onBattery: true, percent: 74, minutesLeft: 192) }
        let header = try #require(lead.call("status", [:]).text.split(separator: "\n").first)
        #expect(header.hasSuffix("workers at once; on battery, 74 %."))
        var held = PowerState(onBattery: true, percent: 45)
        held.heldUnder = 50
        lead.power = { held }
        let holding = try #require(lead.call("status", [:]).text.split(separator: "\n").first)
        #expect(holding.hasSuffix("workers at once; on battery, 45 %, under your 50 % limit (no new starts or merges until AC power returns)."))
        lead.power = { PowerState(onBattery: false, percent: 80, charging: true) }
        #expect(!lead.call("status", [:]).text.contains("battery"))
        lead.power = { nil }
        #expect(!lead.call("status", [:]).text.contains("battery"))
    }

    @Test func theLeadsPromptSaysWhatToDoOnBatteryInOneSentence() {
        let prompt = LeadPrompts.lead(project: "p", root: "/p", workflow: LeadWorkflow())
        #expect(prompt.contains(LeadPrompts.onBattery))
        #expect(LeadPrompts.onBattery.contains("start_worker, audit and merge refuse until the witness tells you to resume"))
        #expect(LeadPrompts.onBattery.contains("On battery, pause lead work below N %"))
        // Not at every unplug.
        #expect(!LeadPrompts.onBattery.contains("start no new workers or audits and merge nothing"))
        // One sentence.
        #expect(LeadPrompts.onBattery.filter { $0 == "." }.count == 1)
    }
}
