import Foundation
import Testing
@testable import VibeCore

struct FocusPlanTests {
    @Test func aTabOnAnotherDesktopGetsTimeForTheSwitch() {
        // macOS slides to the other desktop over ~0.5–1 s; checking after 50 ms saw the old desktop's tab.
        let plan = FocusPlan.make(onCurrentDesktop: false, strict: false)
        #expect(plan.waitLimit >= 1.0)
    }

    @Test func aTabOnAnotherDesktopIsNeverHiddenAndReshown() {
        // Hiding and re-showing a window from another desktop strands windows between Spaces.
        #expect(!FocusPlan.make(onCurrentDesktop: false, strict: false).mayReshow)
        #expect(!FocusPlan.make(onCurrentDesktop: false, strict: true).mayReshow)
    }

    @Test func aTabOnThisDesktopKeepsTheQuickCheckAndTheTilingFallback() {
        let plan = FocusPlan.make(onCurrentDesktop: true, strict: false)
        #expect(plan.waitLimit <= 0.3)
        #expect(plan.mayReshow)
    }

    @Test func strictFocusNeverReshows() {
        #expect(!FocusPlan.make(onCurrentDesktop: true, strict: true).mayReshow)
    }

    @Test func checksCoverTheWaitLimit() {
        for current in [true, false] {
            let plan = FocusPlan.make(onCurrentDesktop: current, strict: false)
            #expect(plan.checks >= 1)
            #expect(abs(Double(plan.checks) * plan.interval - plan.waitLimit) < 0.001)
        }
    }
}
