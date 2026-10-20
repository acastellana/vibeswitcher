import Foundation
import Testing
@testable import VibeCore

/// The lead learns of power changes from the witness, as it does of low disk space: once when the Mac goes on battery
/// (with the charge and the time left), once when AC power returns, nothing while it stays the same; status says
/// "on battery" while it lasts, so a lead after a handover knows without being told. A fake power source stands in
/// for IOKit.
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

    @Test func aSwitchToBatteryAndBackIsToldOnceEach() throws {
        let fake = FakePower()
        var witness = LeadWitness.Power(read: fake.read, file: temp.url("power.json"))
        // On AC power from the start: nothing to tell.
        fake.state = PowerState(onBattery: false, percent: 80, charging: true)
        #expect(witness.look() == nil)
        // Unplugged: told once, with the charge and the time left.
        fake.state = PowerState(onBattery: true, percent: 74, minutesLeft: 192)
        let told = witness.look()
        let battery = try #require(told)
        #expect(battery.hasPrefix("On battery: 74 %, about 3:12 left."))
        #expect(battery.contains("Start no workers or audits and merge nothing until AC power returns; work in flight finishes."))
        // Still on battery, the charge falling: no repeat.
        fake.state = PowerState(onBattery: true, percent: 70, minutesLeft: 170)
        #expect(witness.look() == nil)
        fake.state = PowerState(onBattery: true, percent: 65)
        #expect(witness.look() == nil)
        // Plugged in: told once.
        fake.state = PowerState(onBattery: false, percent: 66, charging: true)
        let back = witness.look()
        let power = try #require(back)
        #expect(power.hasPrefix("On AC power: 66 %, charging."))
        #expect(power.contains("Resume starts and merges."))
        fake.state = PowerState(onBattery: false, percent: 90, charging: true)
        #expect(witness.look() == nil)
    }

    @Test func theEstimateIsLeftOutWhileUnknownAndNotChargingIsSaid() {
        #expect(PowerState(onBattery: true, percent: 98).text == "On battery: 98 %")
        #expect(PowerState(onBattery: true, percent: 50, minutesLeft: 5).text == "On battery: 50 %, about 0:05 left")
        #expect(PowerState(onBattery: false, percent: 100, charging: false).text == "On AC power: 100 %, not charging")
    }

    @Test func aFailedReadingChangesNothing() throws {
        let fake = FakePower()
        var witness = LeadWitness.Power(read: fake.read, file: temp.url("power.json"))
        fake.state = PowerState(onBattery: false, percent: 80, charging: true)
        #expect(witness.look() == nil)
        // A Mac without a battery, or a reading that failed: no switch.
        fake.state = nil
        #expect(witness.look() == nil)
        fake.state = PowerState(onBattery: false, percent: 81, charging: true)
        #expect(witness.look() == nil)
        // On battery at the first reading (the app started unplugged): told, since the lead can't know otherwise.
        var fresh = LeadWitness.Power(read: { PowerState(onBattery: true, percent: 40) }, file: temp.url("power.json"))
        #expect(fresh.look()?.hasPrefix("On battery: 40 %.") == true)
        #expect(fresh.look() == nil)
    }

    @Test func eachReadingIsKeptForStatusUntilItsStale() {
        let file = temp.url("power.json")
        var witness = LeadWitness.Power(read: { PowerState(onBattery: true, percent: 74, at: 1_000) }, file: file)
        _ = witness.look()
        #expect(PowerState.load(from: file, now: Date(timeIntervalSince1970: 1_060))?.statusText == "on battery, 74 %")
        // The app's from before it quit or the Mac slept isn't told as now.
        #expect(PowerState.load(from: file, now: Date(timeIntervalSince1970: 1_000 + PowerState.stale)) == nil)
        #expect(PowerState(onBattery: false, percent: 74).statusText == nil)
    }

    @Test func statusSaysOnBatteryInItsHeader() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        lead.power = { PowerState(onBattery: true, percent: 74, minutesLeft: 192) }
        let header = try #require(lead.call("status", [:]).text.split(separator: "\n").first)
        #expect(header.contains("workers at once; on battery, 74 % (no new starts or merges until AC power returns)."))
        lead.power = { PowerState(onBattery: false, percent: 80, charging: true) }
        #expect(!lead.call("status", [:]).text.contains("battery"))
        lead.power = { nil }
        #expect(!lead.call("status", [:]).text.contains("battery"))
    }

    @Test func theLeadsPromptSaysWhatToDoOnBatteryInOneSentence() {
        let prompt = LeadPrompts.lead(project: "p", root: "/p", workflow: LeadWorkflow())
        #expect(prompt.contains(LeadPrompts.onBattery))
        #expect(LeadPrompts.onBattery.contains("start no new workers or audits and merge nothing, let work in flight finish, and resume when it tells you AC power is back."))
        // One sentence.
        #expect(LeadPrompts.onBattery.filter { $0 == "." }.count == 1)
    }
}
