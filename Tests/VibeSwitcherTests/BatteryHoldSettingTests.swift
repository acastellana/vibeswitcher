import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// Settings' "On battery, pause lead work below N %" (Project lead section): 50 at first, kept in the defaults, 10–90
/// or 0 (never); the stepper goes 5 at a time and from 10 down to off.
struct BatteryHoldSettingTests {
    func preferences(_ body: (UserDefaults, URL) throws -> Void) throws {
        let suite = "BatteryHoldSettingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let presets = scratchRoot.appendingPathComponent("\(suite).json")
        defer { try? FileManager.default.removeItem(at: presets) }
        try body(defaults, presets)
    }

    @Test func itIs50AtFirstAndKept() throws {
        try preferences { defaults, presets in
            let preferences = Preferences(defaults: defaults, presetsFile: presets)
            #expect(preferences.batteryHoldBelow == 50)
            preferences.batteryHoldBelow = 30
            #expect(Preferences(defaults: defaults, presetsFile: presets).batteryHoldBelow == 30)
            // 0: never pause, kept as 0 (not the default).
            preferences.batteryHoldBelow = 0
            #expect(Preferences(defaults: defaults, presetsFile: presets).batteryHoldBelow == 0)
        }
    }

    @Test func aValueOutOfRangeIsKeptInIt() throws {
        try preferences { defaults, presets in
            let preferences = Preferences(defaults: defaults, presetsFile: presets)
            preferences.batteryHoldBelow = 95
            #expect(preferences.batteryHoldBelow == 90)
            #expect(Preferences(defaults: defaults, presetsFile: presets).batteryHoldBelow == 90)
            preferences.batteryHoldBelow = 5
            #expect(preferences.batteryHoldBelow == 10)
            preferences.batteryHoldBelow = -3
            #expect(preferences.batteryHoldBelow == 0)
            // A value written some other way (defaults write) is kept in range when read.
            defaults.set(200, forKey: "batteryHoldBelow")
            #expect(Preferences(defaults: defaults, presetsFile: presets).batteryHoldBelow == 90)
        }
    }

    @Test func theStepperGoesFiveAtATimeAndOffBelowTen() {
        #expect(Preferences.batteryHoldStep(50, up: true) == 55)
        #expect(Preferences.batteryHoldStep(50, up: false) == 45)
        #expect(Preferences.batteryHoldStep(90, up: true) == 90)
        #expect(Preferences.batteryHoldStep(15, up: false) == 10)
        #expect(Preferences.batteryHoldStep(10, up: false) == 0)
        #expect(Preferences.batteryHoldStep(0, up: false) == 0)
        #expect(Preferences.batteryHoldStep(0, up: true) == 10)
        // A typed 12: down to 10, not under it.
        #expect(Preferences.batteryHoldStep(12, up: false) == 10)
    }
}
