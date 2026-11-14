import Foundation
import VibeCore

/// What a spawn may add to a session's environment (the stage 2 plan's Task 10a, S2-D12; the security architecture
/// document's S10).
///
/// A session starts with the host's environment filtered to `Platform.Tools.sessionEnvironmentNames`, then the
/// request's `env` on top (`HostedSession.environment`). From a caller that isn't the app, that `env` may not name a
/// loader or shell-startup variable (`LD_PRELOAD`, `BASH_ENV`, `ENV`, …) or a name the host never passes
/// (`SSH_AUTH_SOCK`, `WSL_INTEROP`, …): such a request is refused, saying which, and nothing is started. The app's
/// spawns aren't filtered. Who may spawn at all is `HostServer.authorized`'s (on Linux, in the user's host, only the app
/// and a lead: `Config.spawnNeedsLead`).
///
/// The Mac refuses nothing here (`Platform.Tools.spawnEnvironmentRefused` is empty there), as always.
///
/// *Doesn't promise:* a session's own processes set whatever they like in what they start themselves; this keeps a
/// session from having the host start a new session with them, the new session then counting as its own child.
enum SpawnEnvironment {
    /// Why `request` from `caller` is refused for the variables its `env` names, or nil: it may go on.
    static func refusal(_ request: SpawnRequest, from caller: LeadVault.Caller) -> String? {
        guard caller != .app else { return nil }
        let refused = Platform.Tools.spawnEnvironmentRefused(request.env.keys.sorted())
        guard !refused.isEmpty else { return nil }
        return "A session can't start another with \(refused.joined(separator: ", ")) in its environment."
    }
}
