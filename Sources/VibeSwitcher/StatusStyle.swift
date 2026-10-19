import AppKit
import SwiftUI
import VibeCore

extension StatusPalette.RGB {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension SessionStatus {
    /// Text, marks and badge fills (`StatusPalette`: at least 4.5:1 in light and dark). Resolves when drawn, so it
    /// follows the menu bar's and the window's appearance.
    var nsColor: NSColor { Self.inks[self]! }

    var color: Color { Self.colors[self]! }

    /// Made once, so a status's colour is always the same object (and compares equal).
    private static let inks: [SessionStatus: NSColor] = Dictionary(uniqueKeysWithValues: all.map { status in
        (status, NSColor(name: nil) { StatusPalette.ink(status, dark: $0.isDark).nsColor })
    })
    private static let colors = inks.mapValues { Color(nsColor: $0) }
    static let all: [SessionStatus] = [.needsInput, .working, .background, .done, .idle, .unknown]

    /// A number or glyph drawn on a status fill: white in light mode, near-black in dark.
    static let onInkNSColor = NSColor(name: nil) { StatusPalette.onInk(dark: $0.isDark).nsColor }
    static var onInk: Color { Color(nsColor: onInkNSColor) }
}

extension ReplacedLead {
    /// A replaced lead's purple, at least 5:1 on the window in light and dark (`StatusPalette.replaced`).
    static let color = Color(nsColor: NSColor(name: nil) { StatusPalette.replaced(dark: $0.isDark).nsColor })
}

extension Session {
    /// Paused sessions are drawn grey, whatever they're doing (with the paused mark: two bars).
    static let pausedNSColor = SessionStatus.idle.nsColor
    var dotNSColor: NSColor { isPaused ? Self.pausedNSColor : status.nsColor }
    var dotColor: Color { Color(nsColor: dotNSColor) }
    /// Drawn as an outline (unknown status) rather than a filled dot.
    var dotIsHollow: Bool { !isPaused && status == .unknown }
    var mark: StatusMark { StatusMark(status: status, paused: isPaused) }
}

extension StatusMark {
    /// Draws the mark into the current AppKit context (y up): the body in `color`, its glyph in the contrasting colour.
    func draw(in rect: CGRect, color: NSColor) {
        color.setFill()
        for part in body(in: rect) { NSBezierPath(cgPath: part).fill() }
        if let glyph = glyph(in: rect) {
            SessionStatus.onInkNSColor.setFill()
            NSBezierPath(cgPath: glyph).fill()
        }
    }
}

/// A status's shape (`StatusMark`) in its colour, for SwiftUI rows and headers. Hidden from VoiceOver: the row or
/// control it sits in says the status in words.
struct StatusMarkView: View {
    let mark: StatusMark
    let color: Color
    var size: CGFloat = 10

    init(_ mark: StatusMark, color: Color, size: CGFloat = 10) {
        self.mark = mark
        self.color = color
        self.size = size
    }

    init(session: Session, size: CGFloat = 10) {
        self.init(session.mark, color: session.dotColor, size: size)
    }

    var body: some View {
        ZStack {
            MarkShape(mark: mark, glyph: false).fill(color)
            MarkShape(mark: mark, glyph: true).fill(SessionStatus.onInk)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private struct MarkShape: Shape {
        let mark: StatusMark
        let glyph: Bool

        func path(in rect: CGRect) -> Path {
            var path = Path()
            if glyph {
                if let shape = mark.glyph(in: rect, yDown: true) { path.addPath(Path(shape)) }
            } else {
                for part in mark.body(in: rect, yDown: true) { path.addPath(Path(part)) }
            }
            return path
        }
    }
}

/// Draws the menu bar image: one dot per session, in list order, so a dot's position tells you which
/// terminal it is. Falls back to per-status counts when there are too many sessions to fit.
enum StatusIcon {
    static func image(for sessions: [Session]) -> NSImage {
        guard !sessions.isEmpty else {
            let image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "VibeSwitcher")!
            image.isTemplate = true
            return image
        }
        let image = sessions.count <= MenuBarDots.maxDots ? dots(sessions) : counts(sessions)
        image.accessibilityDescription = StatusSummary.spoken(sessions)
        return image
    }

    private static func dots(_ sessions: [Session]) -> NSImage {
        let size = NSSize(width: MenuBarDots.width(count: sessions.count), height: MenuBarDots.height)
        let image = NSImage(size: size, flipped: false) { _ in
            for (index, session) in sessions.enumerated() {
                let rect = MenuBarDots.rect(at: index, count: sessions.count)
                // A shape per status as well as a colour: "!" needs you, a spinner arc is working, a check is done.
                session.mark.draw(in: rect, color: session.dotNSColor)
                if session.isCurrent {
                    // labelColor resolves when the menu bar draws, so the ring is white on a dark bar, black on a light one.
                    NSColor.labelColor.setStroke()
                    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -MenuBarDots.ringOffset, dy: -MenuBarDots.ringOffset))
                    ring.lineWidth = 1.2
                    ring.stroke()
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func counts(_ sessions: [Session]) -> NSImage {
        // Unknown counts with idle; paused sessions on their own, whatever they're doing.
        let groups: [(mark: StatusMark, color: NSColor, count: Int)] =
            [SessionStatus.needsInput, .working, .background, .done].map { status in
                (StatusMark(status: status), status.nsColor, sessions.filter { !$0.isPaused && $0.status == status }.count)
            } + [(StatusMark(status: .idle), SessionStatus.idle.nsColor,
                  sessions.filter { !$0.isPaused && ($0.status == .idle || $0.status == .unknown) }.count),
                 (.paused, Session.pausedNSColor, sessions.filter(\.isPaused).count)]
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let mark: CGFloat = 9, gap: CGFloat = 3, spacing: CGFloat = 8, height: CGFloat = 18
        let shown = groups.filter { $0.count > 0 }.map { group in
            (group, NSAttributedString(string: "\(group.count)", attributes: [.foregroundColor: NSColor.labelColor, .font: font]))
        }
        let width = shown.reduce(0) { $0 + mark + gap + ceil($1.1.size().width) + spacing } - spacing
        let image = NSImage(size: NSSize(width: max(ceil(width), 1), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (group, text) in shown {
                group.mark.draw(in: CGRect(x: x, y: (height - mark) / 2, width: mark, height: mark), color: group.color)
                x += mark + gap
                let size = text.size()
                text.draw(at: NSPoint(x: x, y: (height - size.height) / 2))
                x += ceil(size.width) + spacing
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

extension TimelineSchedule where Self == PeriodicTimelineSchedule {
    /// Every `interval` seconds from a fixed start. One from `.now` is a new schedule each time its view is drawn
    /// again, and SwiftUI then updates the view over and over (the chat laid out about 20 times a second). The same
    /// start everywhere also puts every clock in the app on the same whole seconds, so they tick together.
    static func ticking(every interval: TimeInterval) -> PeriodicTimelineSchedule {
        .periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: interval)
    }
}
