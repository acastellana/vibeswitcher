import Foundation
import Testing
import VibeCore

struct AwakeWaitTests {
    @Test func aWaitTheMacSleepsThroughGoesOnAtTheWake() async {
        var wall = Date(timeIntervalSinceReferenceDate: 0), awake: TimeInterval = 0, looks = 0
        let time = MacTime(wall: { wall }, awake: { awake })
        let met = await SandboxIsolationTests().eventually(time: time) {
            looks += 1
            awake += 0.05
            if looks == 1 { wall += hangGuard + 1 }
            return looks == 3
        }
        #expect(met, "the sandbox wait gave up after \(looks) looks")
    }

}
