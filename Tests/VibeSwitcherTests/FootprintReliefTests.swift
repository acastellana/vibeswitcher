import Foundation
import Testing
import VibeCore
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

    private func look(_ relief: FootprintRelief) async {
        let done = DispatchSemaphore(value: 0)
        relief.look { done.signal() }
        #expect(await offPool { done.wait(timeout: .now() + 10) } == .success)
    }

    @Test func givesThePagesBackOnceTheFootprintGrewTheSlack() async {
        let slack = FootprintRelief.slack
        // First look 100; then under the slack; then over it (the relief brings it back to 105); then under the slack
        // over 105 (not 100); then down, and over the slack from there.
        let fake = Fake([100, 100 + slack - 1, 100 + slack, 105, 105 + slack - 1, 90, 90 + slack, 92])
        let relief = FootprintRelief(footprint: fake.read, relieve: { fake.reliefs += 1 })
        await look(relief)
        #expect(fake.reliefs == 0)
        await look(relief)
        #expect(fake.reliefs == 0, "under the slack")
        await look(relief)
        #expect(fake.reliefs == 1, "the slack over the first look")
        await look(relief)
        #expect(fake.reliefs == 1, "under the slack over the footprint after the relief")
        await look(relief)
        await look(relief)
        #expect(fake.reliefs == 2, "the floor followed the footprint down")
        #expect(fake.readings.isEmpty)
    }

    /// A relief holds malloc's locks, and the main thread's allocations wait: never while you're using the app.
    @Test func waitsWhileTheAppIsInUse() async {
        let slack = FootprintRelief.slack
        let fake = Fake([100, 100 + slack, 100 + slack + 5, 101])
        var active = true
        let relief = FootprintRelief(footprint: fake.read, relieve: { fake.reliefs += 1 }, inUse: { active })
        await look(relief)
        await look(relief)
        #expect(fake.reliefs == 0, "frontmost: over the slack, but no relief")
        active = false
        await look(relief)
        #expect(fake.reliefs == 1, "in the background, the next look gives the pages back")
        #expect(fake.readings.isEmpty)
    }

    /// The last relief's footprint before and after, for the health digest (which tells one that freed nothing).
    @Test func keepsTheLastReliefsBeforeAndAfter() async {
        let slack = FootprintRelief.slack
        let fake = Fake([100, 100 + slack, 100 + slack])
        let relief = FootprintRelief(footprint: fake.read, relieve: { fake.reliefs += 1 }, inUse: { false }, split: { nil })
        await look(relief)
        #expect(relief.last == nil)
        await look(relief)
        #expect(relief.last == AppHealth.Memory.Relief(before: 100 + slack, after: 100 + slack))
    }

    /// 2026-11-18: the night's relief lines named only the footprint. What it's made of is read at each relief (not at
    /// every look), off the main thread, and goes in its app.log line and in the last relief kept for the daily line.
    @Test func eachReliefReadsWhatTheFootprintIsMadeOf() async {
        let slack = FootprintRelief.slack
        let fake = Fake([100, 100 + slack - 1, 100 + slack, 100 + slack])
        let split = AppHealth.Memory.Split(mallocInUse: 42, mallocAllocated: 60, graphics: 3, compressed: 7, tags: [.init(name: "malloc small", mb: 30)])
        final class Reads: @unchecked Sendable { var count = 0, onMain = 0 }
        let reads = Reads()
        let relief = FootprintRelief(footprint: fake.read, relieve: { fake.reliefs += 1 }, inUse: { false }, split: {
            reads.count += 1
            if Thread.isMainThread { reads.onMain += 1 }
            return split
        })
        await look(relief)
        await look(relief)
        #expect(reads.count == 0, "no relief yet, nothing read")
        await look(relief)
        #expect(fake.reliefs == 1)
        #expect(reads.count == 1 && reads.onMain == 0, "read once, at the relief, off the main thread")
        #expect(relief.last == AppHealth.Memory.Relief(before: 100 + slack, after: 100 + slack, split: split))
        let line = Breadcrumbs.shared.lines.last { $0.contains("footprint relief: \(Int(100 + slack)) → \(Int(100 + slack)) MB") } ?? ""
        #expect(line.contains("; malloc 42 in use / 60 allocated (18 free), graphics 3, compressed 7, top tags: malloc small 30 (read in "), "\(line)")
    }

    /// The app's own reading: numbers that add up, VM tags by name, and what one costs (printed: the relief's line
    /// says it too). It runs once a relief at most, on the relief's queue.
    @Test func theAppsOwnSplitIsReadCheaply() throws {
        _ = FootprintRelief.split()
        var times: [Double] = []
        var last: AppHealth.Memory.Split?
        for _ in 0..<20 {
            let started = DispatchTime.now()
            last = FootprintRelief.split()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6)
        }
        let split = try #require(last)
        print(String(format: "FootprintRelief.split(): median %.2f ms, most %.2f ms over 20 readings: %@", times.sorted()[10], times.max() ?? 0, split.text))
        #expect(split.mallocInUse > 0 && split.mallocAllocated >= split.mallocInUse)
        #expect(!split.tags.isEmpty && split.tags.count <= AppHealth.Memory.Split.shownTags)
        #expect(split.tags.map(\.mb) == split.tags.map(\.mb).sorted(by: >))
    }
}
