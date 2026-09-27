import CoreGraphics

/// Whether you're at the Mac: screen unlocked and some keyboard/mouse input in the last few minutes.
/// Waiting time only counts as "blocked on you", and reminders only go out, while you are.
enum UserPresence {
    static func isPresent(idleLimit: Double = 300) -> Bool {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           session["CGSSessionScreenIsLocked"] as? Bool == true {
            return false
        }
        // ~0 is kCGAnyInputEventType.
        guard let anyInput = CGEventType(rawValue: ~0) else { return true }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) < idleLimit
    }
}
