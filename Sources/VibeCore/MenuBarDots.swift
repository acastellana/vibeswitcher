import CoreGraphics

/// Geometry of the menu bar image: one dot per session in list order, laid out row by row.
/// Up to 4 sessions sit in one row; more wrap into two rows of small dots so the icon stays narrow
/// (a crowded menu bar hides its leftmost icons under the notch). Shared by drawing and hit-testing.
public enum MenuBarDots {
    public static let maxDots = 12
    public static let height: CGFloat = 18

    public struct Layout: Equatable {
        public let rows: Int
        public let columns: Int
        public let diameter: CGFloat
        public let gap: CGFloat          // horizontal gap between dots
        public let rowGap: CGFloat

        public var width: CGFloat { CGFloat(columns) * diameter + CGFloat(max(columns - 1, 0)) * gap }
        var pitch: CGFloat { diameter + gap }
        var gridHeight: CGFloat { CGFloat(rows) * diameter + CGFloat(rows - 1) * rowGap }
    }

    public static func layout(count: Int) -> Layout {
        if count <= 4 {
            return Layout(rows: 1, columns: max(count, 0), diameter: 9, gap: 5, rowGap: 0)
        }
        return Layout(rows: 2, columns: (count + 1) / 2, diameter: 7, gap: 4, rowGap: 3)
    }

    public static func width(count: Int) -> CGFloat { layout(count: count).width }

    /// Dot rect in image coordinates (origin bottom-left, so row 0 is the top row).
    public static func rect(at index: Int, count: Int) -> CGRect {
        let layout = layout(count: count)
        let row = index / max(layout.columns, 1), column = index % max(layout.columns, 1)
        let top = (height + layout.gridHeight) / 2
        let y = top - CGFloat(row + 1) * layout.diameter - CGFloat(row) * layout.rowGap
        return CGRect(x: CGFloat(column) * layout.pitch, y: y, width: layout.diameter, height: layout.diameter)
    }

    /// Hit area of a dot: its grid cell, widened by half the gap on each side. Cells tile the icon.
    public static func hitRect(at index: Int, count: Int) -> CGRect {
        let layout = layout(count: count)
        let dot = rect(at: index, count: count)
        let rowHeight = height / CGFloat(layout.rows)
        let row = index / max(layout.columns, 1)
        return CGRect(x: dot.minX - layout.gap / 2, y: height - CGFloat(row + 1) * rowHeight,
                      width: layout.pitch, height: rowHeight)
    }

    /// The dot under `point` (image coordinates, origin bottom-left), or nil outside the dots.
    public static func index(at point: CGPoint, count: Int) -> Int? {
        guard (1...maxDots).contains(count) else { return nil }
        let layout = layout(count: count)
        guard point.x >= -layout.gap / 2, point.x < layout.width + layout.gap / 2 else { return nil }
        let column = min(max(Int(((point.x + layout.gap / 2) / layout.pitch).rounded(.down)), 0), layout.columns - 1)
        let row = layout.rows == 1 ? 0 : (point.y >= height / 2 ? 0 : 1)
        let index = row * layout.columns + column
        return index < count ? index : nil
    }
}
