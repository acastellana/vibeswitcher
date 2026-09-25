import CoreGraphics

/// Geometry of the menu bar image: one dot per session, left to right in list order.
/// Shared by the drawing code and the click/tooltip hit-testing so they can't drift apart.
public enum MenuBarDots {
    public static let maxDots = 10
    public static let diameter: CGFloat = 9
    public static let gap: CGFloat = 5
    public static let height: CGFloat = 18

    public static func width(count: Int) -> CGFloat {
        count <= 0 ? 0 : CGFloat(count) * diameter + CGFloat(count - 1) * gap
    }

    public static func rect(at index: Int) -> CGRect {
        CGRect(x: CGFloat(index) * (diameter + gap), y: (height - diameter) / 2, width: diameter, height: diameter)
    }

    /// Hit area of a dot: the dot plus half the gap on each side, full height. Adjacent areas touch,
    /// so every click on the dot strip belongs to exactly one session.
    public static func hitRect(at index: Int) -> CGRect {
        CGRect(x: CGFloat(index) * (diameter + gap) - gap / 2, y: 0, width: diameter + gap, height: height)
    }

    /// The dot under `x` (points from the image's left edge), or nil when outside the strip.
    public static func index(atX x: CGFloat, count: Int) -> Int? {
        guard (1...maxDots).contains(count), x >= -gap / 2, x < width(count: count) + gap / 2 else { return nil }
        let index = Int(((x + gap / 2) / (diameter + gap)).rounded(.down))
        return min(max(index, 0), count - 1)
    }
}
