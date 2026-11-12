#if canImport(Darwin)
import Foundation
import CoreGraphics

// A status mark's shapes as paths (CGPath, which only the Mac has): what the app draws of `StatusMark`
// (MenuBarDots.swift), as it was there.
extension StatusMark {
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
#endif
