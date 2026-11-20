#if os(Linux)
import Foundation

// Linux: no system dialog that only a person can answer. The user's voice there is the cgroup rule (VibeNode's Voice).
extension Platform.Approval {
    enum System {
        static let why = "this system has no LocalAuthentication (Touch ID or the login password): the voice rule here is the cgroup's"

        static func availability() -> String? { why }

        static func ask(_ reason: String, timeout: TimeInterval) -> Outcome { .unavailable(why) }
    }
}
#endif
