import Foundation

/// How a jump to a Terminal tab checks that the tab really reached the front.
/// A tab on another desktop needs time: macOS slides to that desktop over up to a second, and checking
/// right away sees the old desktop's tab. It must also never be hidden and re-shown (the fallback for
/// side-by-side windows on this desktop): doing that to a window on another desktop strands windows.
public struct FocusPlan: Equatable, Sendable {
    /// How many times to look at the front tab, `interval` seconds apart.
    public var checks: Int
    public var interval: Double
    /// Whether the hide-and-re-show fallback may run when the tab still isn't in front.
    public var mayReshow: Bool

    public var waitLimit: Double { Double(checks) * interval }

    /// `onCurrentDesktop` is false when the tab's desktop is unknown, so an unknown desktop gets the safe plan.
    public static func make(onCurrentDesktop: Bool, strict: Bool) -> FocusPlan {
        onCurrentDesktop
            ? FocusPlan(checks: 3, interval: 0.05, mayReshow: !strict)
            : FocusPlan(checks: 15, interval: 0.1, mayReshow: false)
    }
}
