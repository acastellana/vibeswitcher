import Foundation

/// What a start does with the lead that may be running already.
public enum LeadStartPlan: Equatable, Sendable {
    /// The host hasn't said yet which sessions run (the app just relaunched): decided once it has.
    case wait
    /// No lead runs for the project.
    case start
    /// The lead runs (and holds its role, or nothing here may replace it): shown, never replaced.
    case show(UUID)
    /// The lead runs without its role (the vault binds it to no session, or another): you're asked first.
    case askToReplace(UUID)

    /// What the session host has said so far, as far as a start's plan goes.
    public enum HostState: Equatable, Sendable {
        /// Not welcomed yet (the app just relaunched, a reconnect): its list doesn't say yet which sessions run.
        case connecting
        /// Anything else (welcomed, outdated, not running, failed).
        case other
    }

    /// `running`: the project's live lead session, if any; `holdsRole`: whether the vault binds the lead's role to it
    /// (nil: the vault couldn't be asked); `fromUser`: you asked in the app (not `vibeswitcher --lead`, which anything
    /// can post).
    public static func plan(hostState: HostState, running: UUID?, holdsRole: Bool?, fromUser: Bool) -> LeadStartPlan {
        if hostState == .connecting { return .wait }
        guard let running else { return .start }
        return holdsRole == false && fromUser ? .askToReplace(running) : .show(running)
    }
}
