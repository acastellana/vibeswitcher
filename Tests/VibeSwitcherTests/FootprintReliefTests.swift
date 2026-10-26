import Foundation
import Testing
@testable import VibeSwitcher

/// The app gives malloc's free pages back once its footprint has grown `slack` over the last relief's (10-26).
@Suite struct FootprintReliefTests {
    /// A footprint read from `readings` in turn, and the reliefs counted.
    final class Fake: @unchecked Sendable {
        var readings: [Double]
        var reliefs = 0
        init(_ readings: [Double]) { self.readings = readings }
        func read() -> Double? { readings.isEmpty ? nil : readings.removeFirst() }
    }

    private func look(_ relief: FootprintRelief) {
        let done = DispatchSemaphore(value: 0)
        relief.look { done.signal() }
        #expect(done.wait(timeout: .now() + 10) == .success)
    }

    @Test func givesThePagesBackOnceTheFootprintGrewTheSlack() {
        let slack = FootprintRelief.slack
        // First look 100; then under the slack; then over it (the relief brings it back to 105); then under the slack
        // over 105 (not 100); then down, and over the slack from there.
        let fake = Fake([100, 100 + slack - 1, 100 + slack, 105, 105 + slack - 1, 90, 90 + slack, 92])
        let relief = FootprintRelief(footprint: fake.read, relieve: { fake.reliefs += 1 })
        look(relief)
        #expect(fake.reliefs == 0)
        look(relief)
        #expect(fake.reliefs == 0, "under the slack")
        look(relief)
        #expect(fake.reliefs == 1, "the slack over the first look")
        look(relief)
        #expect(fake.reliefs == 1, "under the slack over the footprint after the relief")
        look(relief)
        look(relief)
        #expect(fake.reliefs == 2, "the floor followed the footprint down")
        #expect(fake.readings.isEmpty)
    }
}
