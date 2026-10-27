import AppKit
import SwiftUI
import Testing
import VibeCore
@testable import VibeSwitcher

/// The sidebar rows' mark, status first (`AgentMark(statusFirst:)`): the agent's badge stays clear of the status's
/// shape, stays big enough to read, and VoiceOver hears what it heard before the swap.
@MainActor
struct SidebarMarkTests {
    /// At the row's size (22) and a team member's (18), the badge and its ring don't reach the status's disc: the
    /// nearest point of the badge's rounded corner is farther from the disc's centre than its radius plus the ring.
    @Test(arguments: [CGFloat(18), 22]) func badgeClearsTheStatus(size: CGFloat) {
        let layout = StatusFirstLayout(size: size)
        let disc = layout.status
        let radius = disc.width / 2
        let corner = CGPoint(x: layout.badge.minX + layout.badgeRadius, y: layout.badge.minY + layout.badgeRadius)
        let gap = hypot(corner.x - disc.midX, corner.y - disc.midY) - layout.badgeRadius - layout.ring - radius
        #expect(gap >= 0, "the badge's ring cuts \(-gap) pt into the status at \(size)")
        // The badge's corner is the part nearest the disc only if it faces it: the badge starts past the disc's centre.
        #expect(layout.badge.minX > disc.midX && layout.badge.minY > disc.midY)
    }

    /// The badge is big enough for its symbol to read, and the status stays the bigger of the two.
    @Test(arguments: [CGFloat(18), 22]) func badgeStaysLegible(size: CGFloat) {
        let layout = StatusFirstLayout(size: size)
        #expect(layout.badge.width >= 9)
        #expect(layout.status.width >= layout.badge.width * 1.5)
    }

    /// VoiceOver says the same with the status first as before ("Claude, needs you"): one label for both layouts,
    /// the agent's name and then the status, whichever is drawn big.
    @Test func spokenAsBefore() {
        for (kind, spoken) in [(MarkKind.agent(.claude), "Needs you"), (.agent(.codex), "Working"), (.shell, "Idle")] {
            let before = AgentMark(kind: kind, status: .red, mark: .alert, spoken: spoken)
            let after = AgentMark(kind: kind, status: .red, mark: .alert, spoken: spoken, statusFirst: true)
            #expect(before.spokenLabel == "\(kind.name), \(spoken.lowercased())")
            #expect(after.spokenLabel == before.spokenLabel)
        }
        #expect(AgentMark(kind: .agent(.codex), statusFirst: true).spokenLabel == "Codex")
    }
}
