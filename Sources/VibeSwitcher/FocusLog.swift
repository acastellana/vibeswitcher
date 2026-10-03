import AppKit
import Foundation
import VibeCore

/// Diagnostics in ~/.vibeswitcher/focus-debug.json: every jump to a session's tab (from the menu bar,
/// list, sidebar or phone) with each step's outcome, and what was really in front half a second later,
/// so a "it didn't come to the front" report can be matched to its cause.
enum FocusLog {
    struct Attempt {
        var tty: String
        var name: String
        var source: String
        var started = Date()
        var steps: [String] = []
    }

    private static var recent: [[String: Any]] = []
    private static var failures = 0
    private static var total = 0
    private static let queue = DispatchQueue(label: "focus-log")

    static func begin(_ session: Session, source: String) -> Attempt {
        var attempt = Attempt(tty: session.tty, name: session.displayName, source: source)
        if let position = session.screenPosition {
            attempt.steps.append("desktop \(position.desktop.map(String.init) ?? "?")"
                + (position.fullscreen ? " (full screen)" : "")
                + (session.onCurrentDesktop ? ", current" : ", not current"))
        } else {
            attempt.steps.append("position unknown")
        }
        return attempt
    }

    /// Off the main thread. Waits a moment, checks what is actually in front, then records the attempt.
    static func finish(_ attempt: Attempt) {
        Thread.sleep(forTimeInterval: 0.5)
        let front = NSWorkspace.shared.frontmostApplication
        let frontApp = front?.localizedName ?? "?"
        let terminalInFront = front?.bundleIdentifier == TerminalBridge.bundleID
        let frontTTY = terminalInFront ? TerminalBridge.frontTTY() : nil
        let landed = terminalInFront && frontTTY == attempt.tty
        let after = landed ? "in front" : "in front instead: \(frontApp)\(frontTTY.map { " \($0)" } ?? "")"
        append([
            "time": ISO8601DateFormatter().string(from: attempt.started),
            "session": "\(attempt.name) (\(attempt.tty))",
            "source": attempt.source,
            "steps": attempt.steps,
            "after": after,
            "ok": landed,
        ], ok: landed)
    }

    /// A failed attempt that was already checked by its caller (the phone verifies the front tab itself).
    static func record(tty: String, source: String, steps: [String]) {
        append(["time": ISO8601DateFormatter().string(from: Date()), "session": tty, "source": source,
                "steps": steps, "ok": false], ok: false)
    }

    private static func append(_ entry: [String: Any], ok: Bool) {
        queue.async {
            total += 1
            if !ok { failures += 1 }
            recent = Array(([entry] + recent).prefix(40))
            let object: [String: Any] = [
                "updatedAt": ISO8601DateFormatter().string(from: Date()),
                "attempts": total, "failures": failures, "recent": recent,
            ]
            if JSONSerialization.isValidJSONObject(object),
               let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: VibePaths.root.appendingPathComponent("focus-debug.json"))
            }
        }
    }
}
