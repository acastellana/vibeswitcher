#if canImport(Darwin)
import Foundation
import LocalAuthentication

// The Mac: LocalAuthentication's device owner policy, Touch ID (or a paired Watch) and else the login password. Written
// on Linux and never run on a Mac: what it does from a LaunchAgent in gui/<uid>, with the lid closed, over ssh and with
// no Touch ID is the design's step 4 measurement (docs/process/v2-mac-tasks.md). No test calls `ask`.
extension Platform.Approval {
    enum System {
        static func availability() -> String? {
            var error: NSError?
            guard LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                return why(error).text
            }
            return nil
        }

        static func ask(_ reason: String, timeout: TimeInterval) -> Outcome {
            let context = LAContext()
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                return .unavailable(why(error).text)
            }
            let answered = DispatchSemaphore(value: 0)
            let answer = Answer()
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { approved, error in
                if approved {
                    answer.set(.approved)
                } else {
                    let (text, unavailable) = why(error)
                    answer.set(unavailable ? .unavailable(text) : .declined(text))
                }
                answered.signal()
            }
            if answered.wait(timeout: .now() + timeout) == .timedOut {
                context.invalidate()
                _ = answered.wait(timeout: .now() + 5)
                return .declined("not answered within \(Int(timeout)) s")
            }
            return answer.value ?? .declined("no answer came")
        }

        /// What an error from LocalAuthentication says, and whether it means nothing can be asked here (rather than a
        /// person's no).
        static func why(_ error: Error?) -> (text: String, unavailable: Bool) {
            guard let error else { return ("declined", false) }
            guard let code = (error as? LAError)?.code else { return (error.localizedDescription, false) }
            switch code {
            case .userCancel: return ("cancelled at the Mac", false)
            case .authenticationFailed: return ("Touch ID or the password didn't match", false)
            case .systemCancel, .appCancel: return ("the system took the dialog down", false)
            case .passcodeNotSet: return ("this Mac's account has no password to ask for", true)
            case .notInteractive: return ("no session to show the dialog in (over ssh, or outside the user's login)", true)
            default: return (error.localizedDescription, true)
            }
        }
    }

    /// The answer, set once on LocalAuthentication's queue and read after the wait.
    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: Outcome?

        func set(_ value: Outcome) { lock.withLock { outcome = value } }
        var value: Outcome? { lock.withLock { outcome } }
    }
}
#endif
