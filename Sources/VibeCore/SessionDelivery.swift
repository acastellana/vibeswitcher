import Foundation

/// What became of a message for a window session's agent (`LeadController.tell`).
public enum SessionDelivery: Equatable, Sendable {
    /// In its steer inbox: its hook hands it over at the agent's next step.
    case delivered
    /// Not now, but it may go later: the session host hasn't welcomed the app yet (or is gone), or the post failed.
    case notYet
    /// The session host, welcomed, says its session ended or doesn't run it: no agent there will read it.
    case ended
}
