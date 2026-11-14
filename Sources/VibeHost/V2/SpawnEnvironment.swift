import Foundation
import VibeCore

/// What a spawn may add to a session's environment (the stage 2 plan's Task 10a, S2-D12; the security architecture
/// document's S10).
///
/// A session starts with the host's environment filtered to `Platform.Tools.sessionEnvironmentNames`, then the
/// request's `env` on top (`HostedSession.environment`). From a caller that isn't the app, that `env` may not name a
/// loader or shell-startup variable (`LD_PRELOAD`, `BASH_ENV`, `ENV`, `PS1`, …), a name the host never passes
/// (`SSH_AUTH_SOCK`, `WSL_INTEROP`, …) or one the host fixes (`SWIFT_BACKTRACE`): such a request is refused, saying
/// which, and nothing is started. The app's spawns aren't filtered. Who may spawn at all is `HostServer.authorized`'s
/// (on Linux, in the user's host, only the app and a lead: `Config.spawnNeedsLead`).
///
/// The Mac refuses nothing here (`Platform.Tools.spawnEnvironmentRefused` is empty there), as always.
///
/// *Doesn't promise:* a limit on what a caller can have the host start. This guards against a slip in `env` only: the
/// same caller's `command` is a bash line (`Platform.Tools.sessionShellArguments`), which sets any of these names
/// itself (`LD_PRELOAD=/x.so claude`, `export BASH_ENV=…; exec bash …`), and a check of the text wouldn't hold, since
/// bash can build a name as it runs. What holds a session's children is the sandbox (the security architecture
/// document's S12), not this.
enum SpawnEnvironment {
    /// Why `request` from `caller` is refused for the variables its `env` names, or nil: it may go on.
    static func refusal(_ request: SpawnRequest, from caller: LeadVault.Caller) -> String? {
        guard caller != .app else { return nil }
        let refused = Platform.Tools.spawnEnvironmentRefused(request.env.keys.sorted())
        guard !refused.isEmpty else { return nil }
        return "A session can't start another with \(refused.joined(separator: ", ")) in its environment."
    }
}
