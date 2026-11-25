// Measurement LA-7's helper: whether a process of the user's can answer LocalAuthentication's dialog with synthetic
// keys. Prints whether this process is trusted for Accessibility (AXIsProcessTrusted: asks nothing) and which app is
// frontmost. With `escape` it posts ONE Escape key (never any other key: never a password, never Return), and only
// while the frontmost app is the system's authentication dialog (FROM_BUNDLES, its bundle ids); otherwise it posts
// nothing and says what was in front, so no key ever reaches a real session's window. Only la-keys.sh runs it.
import AppKit
import ApplicationServices
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let front = NSWorkspace.shared.frontmostApplication
let frontID = front?.bundleIdentifier ?? "none"
print("keys: pid=\(getpid()) accessibility_trusted=\(AXIsProcessTrusted()) frontmost=\(frontID) (\(front?.localizedName ?? "?"))")
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.first == "escape" else {
    print("keys: posted nothing (give escape BUNDLE_ID…)")
    exit(0)
}
let dialogs = Set(arguments.dropFirst())
guard dialogs.contains(frontID) else {
    print("keys: posted nothing: the frontmost app \(frontID) isn't one of \(dialogs.sorted()) (the dialog's bundle id goes in the record)")
    exit(3)
}
let escape: CGKeyCode = 0x35
guard let down = CGEvent(keyboardEventSource: nil, virtualKey: escape, keyDown: true),
      let up = CGEvent(keyboardEventSource: nil, virtualKey: escape, keyDown: false) else {
    print("keys: no event could be made")
    exit(1)
}
down.post(tap: .cghidEventTap)
up.post(tap: .cghidEventTap)
print("keys: posted Escape at=\(ISO8601DateFormatter().string(from: Date()))")
