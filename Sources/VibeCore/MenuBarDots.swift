import Foundation
import CoreGraphics

/// Geometry of the menu bar image: one dot per session in list order, laid out row by row.
/// Up to 4 sessions sit in one row; more wrap into two rows of small dots so the icon stays narrow
/// (a crowded menu bar hides its leftmost icons under the notch). Shared by drawing and hit-testing.
public enum MenuBarDots {
    public static let maxDots = 12
    /// Taller than the dots need, so the ring around the session you're viewing fits inside the image.
    public static let height: CGFloat = 22
    /// How far that ring sits outside its dot; smaller than half of every gap, so it never touches a neighbour.
    public static let ringOffset: CGFloat = 1.5
    /// Side margin so the ring around the first/last dot isn't clipped.
    static let sideMargin: CGFloat = 2.5

    public struct Layout: Equatable {
        public let rows: Int
        public let columns: Int
        public let diameter: CGFloat
        public let gap: CGFloat          // horizontal gap between dots
        public let rowGap: CGFloat

        /// Image width: the dots plus a margin on each side for the viewing ring.
        public var width: CGFloat { dotsWidth + 2 * MenuBarDots.sideMargin }
        var dotsWidth: CGFloat { CGFloat(columns) * diameter + CGFloat(max(columns - 1, 0)) * gap }
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
        return CGRect(x: sideMargin + CGFloat(column) * layout.pitch, y: y, width: layout.diameter, height: layout.diameter)
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
        let x = point.x - sideMargin
        guard x >= -layout.gap / 2 - sideMargin, x < layout.dotsWidth + layout.gap / 2 + sideMargin else { return nil }
        let column = min(max(Int(((x + layout.gap / 2) / layout.pitch).rounded(.down)), 0), layout.columns - 1)
        let row = layout.rows == 1 ? 0 : (point.y >= height / 2 ? 0 : 1)
        let index = row * layout.columns + column
        return index < count ? index : nil
    }
}

/// Where touching the screen edge reveals the sidebar: the right edge, but only its vertical middle, so
/// the top and bottom corners (hot corners, scroll bars, window resizing) don't trigger it.
public enum SidebarHotZone {
    /// Share of the screen height, centred, that counts: the middle half, so the top and bottom
    /// corners stay free (a narrower band made approaches slightly high or low miss).
    public static let band: CGFloat = 0.5
    /// How close to the right edge the pointer must be. A few points of slack: on a trackpad the
    /// pointer often stops just short of the edge.
    public static let edgeWidth: CGFloat = 4

    public static func contains(_ point: CGPoint, screen: CGRect) -> Bool {
        let margin = screen.height * (1 - band) / 2
        return point.x >= screen.maxX - edgeWidth
            && point.y >= screen.minY + margin
            && point.y <= screen.maxY - margin
    }

    /// Where to watch for the pointer on `screen`'s right edge: the zone, less the stretches where another of
    /// `screens` continues to the right (there the pointer just crosses over), bottom to top.
    public static func strips(on screen: CGRect, screens: [CGRect]) -> [CGRect] {
        let margin = screen.height * (1 - band) / 2
        var free = [(screen.minY + margin, screen.maxY - margin)]
        for other in screens where other != screen && abs(other.minX - screen.maxX) < 1 {
            free = free.flatMap { low, high -> [(CGFloat, CGFloat)] in
                guard other.minY < high, other.maxY > low else { return [(low, high)] }
                return [(low, min(high, other.minY)), (max(low, other.maxY), high)].filter { $0.1 > $0.0 }
            }
        }
        return free.map { CGRect(x: screen.maxX - edgeWidth, y: $0.0, width: edgeWidth, height: $0.1 - $0.0) }
    }
}

/// The sidebar's slide in/out takes ~0.16 s. One that still counts as running a second later never
/// finished (its completion was lost), and must not keep the "shown but not on screen" check waiting.
public enum SidebarAnimation {
    public static let staleAfter: TimeInterval = 1

    public static func isStale(startedAt: Date?, now: Date) -> Bool {
        guard let startedAt else { return true }
        return now.timeIntervalSince(startedAt) > staleAfter
    }
}

/// The shape a status is drawn with, so it reads without colour (WCAG 1.4.1): the menu bar, the list rows, the pill
/// and the window's agent marks all use these. Paths are in `rect`'s coordinates, y up (AppKit) unless `yDown`.
public enum StatusMark: Equatable, Sendable {
    /// Needs you: a disc with "!".
    case alert
    /// Working: an open ¾ arc, like a spinner caught mid-turn.
    case spinner
    /// Background jobs: a ring, half filled.
    case halfFilled
    /// Done: a disc with a check.
    case check
    /// Idle: a smaller dot.
    case smallDot
    /// Unknown: an empty ring.
    case outline
    /// Paused: a disc with two bars.
    case paused

    public init(status: SessionStatus, paused: Bool = false) {
        if paused { self = .paused; return }
        switch status {
        case .needsInput: self = .alert
        case .working: self = .spinner
        case .background: self = .halfFilled
        case .done: self = .check
        case .idle: self = .smallDot
        case .unknown: self = .outline
        }
    }

    /// The parts drawn in the status colour, each filled (non-zero winding).
    public func body(in rect: CGRect, yDown: Bool = false) -> [CGPath] {
        let d = min(rect.width, rect.height)
        let disc = CGPath(ellipseIn: rect, transform: nil)
        func ring(_ width: CGFloat) -> CGPath {
            CGPath(ellipseIn: rect.insetBy(dx: width / 2, dy: width / 2), transform: nil)
                .copy(strokingWithWidth: width, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
        }
        switch self {
        case .alert, .check, .paused: return [disc]
        case .smallDot: return [CGPath(ellipseIn: rect.insetBy(dx: d * 0.2, dy: d * 0.2), transform: nil)]
        case .outline: return [ring(max(d * 0.14, 1.1))]
        case .halfFilled:
            let half = CGMutablePath()
            half.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: d / 2, startAngle: .pi / 2, endAngle: 3 * .pi / 2,
                        clockwise: false)
            half.closeSubpath()
            return [ring(max(d * 0.14, 1.1)), half]
        case .spinner:
            let width = d * 0.28
            let arc = CGMutablePath()
            // From the top, three quarters round; the open quarter is the top right.
            let top: CGFloat = yDown ? -.pi / 2 : .pi / 2
            arc.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: (d - width) / 2, startAngle: top,
                       endAngle: top + (yDown ? -1 : 1) * 1.5 * .pi, clockwise: yDown)
            return [arc.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)]
        }
    }

    /// The glyph drawn over the body in the contrasting colour (white on a light-mode fill, near-black on a dark-mode
    /// one), or nil.
    public func glyph(in rect: CGRect, yDown: Bool = false) -> CGPath? {
        let d = min(rect.width, rect.height)
        // Points given from the top left as fractions of the mark.
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * d, y: yDown ? rect.minY + y * d : rect.maxY - y * d)
        }
        func box(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
            let a = point(x0, y0), b = point(x1, y1)
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        }
        switch self {
        case .alert:
            let path = CGMutablePath()
            let bar = box(0.41, 0.18, 0.59, 0.60)
            path.addRoundedRect(in: bar, cornerWidth: bar.width / 2, cornerHeight: bar.width / 2)
            let dot = point(0.5, 0.77)
            path.addEllipse(in: CGRect(x: dot.x - d * 0.095, y: dot.y - d * 0.095, width: d * 0.19, height: d * 0.19))
            return path
        case .check:
            let path = CGMutablePath()
            path.addLines(between: [point(0.27, 0.52), point(0.44, 0.69), point(0.74, 0.35)])
            return path.copy(strokingWithWidth: d * 0.17, lineCap: .round, lineJoin: .round, miterLimit: 10)
        case .paused:
            let path = CGMutablePath()
            path.addRect(box(0.32, 0.28, 0.44, 0.72))
            path.addRect(box(0.56, 0.28, 0.68, 0.72))
            return path
        case .spinner, .halfFilled, .smallDot, .outline:
            return nil
        }
    }
}

/// Status colours that meet WCAG AA: text in them is at least 4.5:1 on the app's backgrounds, and the number or glyph
/// inside a filled badge at least 4.5:1 on the fill, in light and in dark. Light mode needs darker inks than the
/// system colours (systemOrange text on a light popover is 1.9:1); dark mode keeps them bright, with near-black inside.
public enum StatusPalette {
    public struct RGB: Equatable, Sendable {
        public let red: Double, green: Double, blue: Double
        public init(hex: UInt32) {
            red = Double((hex >> 16) & 0xFF) / 255
            green = Double((hex >> 8) & 0xFF) / 255
            blue = Double(hex & 0xFF) / 255
        }

        /// WCAG 2 relative luminance.
        public var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
    }

    /// WCAG 2 contrast ratio, 1...21.
    public static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (light, dark) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
        return (light + 0.05) / (dark + 0.05)
    }

    /// The colour of a status's text, mark and badge fill.
    public static func ink(_ status: SessionStatus, dark: Bool) -> RGB {
        switch (status, dark) {
        case (.needsInput, false): return RGB(hex: 0xC4001A)
        case (.needsInput, true): return RGB(hex: 0xFF7A72)
        case (.working, false): return RGB(hex: 0x9C4400)
        case (.working, true): return RGB(hex: 0xFF9F0A)
        case (.background, false): return RGB(hex: 0x0058B8)
        case (.background, true): return RGB(hex: 0x5EB0FF)
        case (.done, false): return RGB(hex: 0x1A7330)
        case (.done, true): return RGB(hex: 0x30D158)
        case (.idle, false), (.unknown, false): return RGB(hex: 0x636366)
        case (.idle, true), (.unknown, true): return RGB(hex: 0xAEAEB2)
        }
    }

    /// A lead another session replaced (`ReplacedLead`): purple, text-safe like the inks.
    public static func replaced(dark: Bool) -> RGB { RGB(hex: dark ? 0xC98BFF : 0x8E3BBF) }

    /// The colour of a number or glyph drawn on an `ink` fill.
    public static func onInk(dark: Bool) -> RGB { RGB(hex: dark ? 0x1F1F1F : 0xFFFFFF) }

    /// Backgrounds status text is drawn on: popover, sidebar and window (light ≈ #ECECEC, dark ≈ #323232), and white
    /// or near-black cards.
    public static let lightBackgrounds = [RGB(hex: 0xECECEC), RGB(hex: 0xFFFFFF), RGB(hex: 0xF4F4F6)]
    public static let darkBackgrounds = [RGB(hex: 0x323232), RGB(hex: 0x1E1E1E), RGB(hex: 0x1C1E22), RGB(hex: 0x111214)]
}

/// What VoiceOver says for the sessions: "VibeSwitcher: 2 need you, 3 working".
public enum StatusSummary {
    public static func spoken(_ sessions: [Session]) -> String {
        guard !sessions.isEmpty else { return "VibeSwitcher: no sessions" }
        var parts: [String] = []
        for status in [SessionStatus.needsInput, .working, .background, .done, .idle, .unknown] {
            let count = sessions.filter { $0.status == status && !$0.isPaused }.count
            guard count > 0 else { continue }
            parts.append(status.word.counted(count))
        }
        let paused = sessions.filter(\.isPaused).count
        if paused > 0 { parts.append(StateWord.paused.counted(paused)) }
        return "VibeSwitcher: " + parts.joined(separator: ", ")
    }

    /// One session: "3, docs-site, done".
    public static func spoken(number: Int, name: String, status: SessionStatus, paused: Bool) -> String {
        "\(number), \(name), \((paused ? StateWord.paused : status.word).text)"
    }
}
