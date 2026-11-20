import Foundation

extension Platform {
    /// A person at this machine agreeing to one thing, asked by the system itself: on the Mac LocalAuthentication's
    /// dialog, Touch ID or else the login password (`deviceOwnerAuthentication`), drawn by the system, which a process
    /// of the user's can make appear but can't answer (synthetic clicks need Accessibility consent). The user's voice on
    /// the Mac (the node on the Mac's design, "The user's voice"; the user's decision of 2026-11-20): each state change
    /// asked so, its reason the card's text (`ApprovalVoice` in VibeNode). Linux has none (Approval+Linux.swift): there
    /// the voice rule is the cgroup's.
    ///
    /// Asking puts a dialog on the screen of the person at the Mac: no test asks (`ApprovalLintTests`), and the voice's
    /// tests give a fake (`ApprovalVoice.Authenticator`). `availability()` shows nothing.
    public enum Approval {
        /// How an ask ended.
        public enum Outcome: Equatable, Sendable {
            /// The person agreed (Touch ID matched, or the login password was typed).
            case approved
            /// The person said no, cancelled, didn't match, or didn't answer in time; or the system cancelled it.
            case declined(String)
            /// Nothing can be asked here: no Touch ID and no password set, no session to draw the dialog in (over ssh, a
            /// job outside the user's GUI session), or a system without it (Linux).
            case unavailable(String)
        }

        /// Why nothing could be asked now, or nil when it could: the Mac's `canEvaluatePolicy`, which shows nothing.
        /// Linux: why not, always.
        public static func availability() -> String? { System.availability() }

        /// Asks the person at this machine to agree to `reason` (the dialog says "<this program> is trying to
        /// <reason>": a phrase with a verb, non-empty), waiting at most `timeout` seconds for the answer (then the
        /// dialog is taken down and it is `.declined`). Blocks the calling thread: never on a queue that must stay
        /// free. Linux: `.unavailable`, nothing shown.
        public static func ask(_ reason: String, timeout: TimeInterval) -> Outcome {
            guard !reason.isEmpty else { return .declined("nothing to agree to: the reason is empty") }
            return System.ask(reason, timeout: timeout)
        }
    }
}
