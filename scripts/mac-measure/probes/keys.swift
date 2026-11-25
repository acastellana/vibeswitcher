// Measurement LA-6's helper: whether a process of the user's can answer LocalAuthentication's dialog with synthetic
// keys. Prints whether this process is trusted for Accessibility (AXIsProcessTrusted: asks nothing), then posts one
// Escape key (never any other key: never a password, never Return). Only scripts/mac-measure/la-keys.sh runs it.
import ApplicationServices
import Foundation

print("keys: pid=\(getpid()) accessibility_trusted=\(AXIsProcessTrusted())")
guard CommandLine.arguments.dropFirst().first == "escape" else {
    print("keys: posted nothing (give escape)")
    exit(0)
}
let escape: CGKeyCode = 0x35
guard let down = CGEvent(keyboardEventSource: nil, virtualKey: escape, keyDown: true),
      let up = CGEvent(keyboardEventSource: nil, virtualKey: escape, keyDown: false) else {
    print("keys: no event could be made")
    exit(1)
}
down.post(tap: .cghidEventTap)
up.post(tap: .cghidEventTap)
print("keys: posted Escape at \(ISO8601DateFormatter().string(from: Date()))")
