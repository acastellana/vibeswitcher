import AppKit

/// System Settings › Accessibility › Display › Reduce motion, for AppKit animations (SwiftUI views read
/// `\.accessibilityReduceMotion`). With it on, things appear and go instead of sliding.
enum Motion {
    static var isReduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
