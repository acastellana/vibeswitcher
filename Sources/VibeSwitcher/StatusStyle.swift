import AppKit
import SwiftUI
import VibeCore

extension SessionStatus {
    var nsColor: NSColor {
        switch self {
        case .needsInput: return .systemRed
        case .working: return .systemOrange
        case .background: return .systemBlue
        case .done: return .systemGreen
        case .idle: return NSColor.systemGray.withAlphaComponent(0.55)
        case .unknown: return NSColor.systemGray.withAlphaComponent(0.35)
        }
    }

    var color: Color { Color(nsColor: nsColor) }
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
        return sessions.count <= MenuBarDots.maxDots ? dots(sessions) : counts(sessions)
    }

    private static func dots(_ sessions: [Session]) -> NSImage {
        let size = NSSize(width: MenuBarDots.width(count: sessions.count), height: MenuBarDots.height)
        let image = NSImage(size: size, flipped: false) { _ in
            for (index, session) in sessions.enumerated() {
                let rect = MenuBarDots.rect(at: index, count: sessions.count)
                let path = NSBezierPath(ovalIn: rect)
                if session.status == .unknown {
                    session.status.nsColor.setStroke()
                    path.lineWidth = 1.2
                    NSBezierPath(ovalIn: rect.insetBy(dx: 0.6, dy: 0.6)).stroke()
                } else {
                    session.status.nsColor.setFill()
                    path.fill()
                }
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
        let order: [SessionStatus] = [.needsInput, .working, .background, .done, .idle]
        let text = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        for status in order {
            let count = sessions.filter { $0.status == status || (status == .idle && $0.status == .unknown) }.count
            guard count > 0 else { continue }
            text.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: status.nsColor, .font: font]))
            text.append(NSAttributedString(string: "\(count)  ", attributes: [.foregroundColor: NSColor.labelColor, .font: font]))
        }
        let size = text.size()
        let image = NSImage(size: NSSize(width: ceil(size.width), height: 18), flipped: false) { _ in
            text.draw(at: NSPoint(x: 0, y: (18 - size.height) / 2))
            return true
        }
        image.isTemplate = false
        return image
    }
}
