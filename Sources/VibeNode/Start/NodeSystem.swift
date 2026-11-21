import Foundation
import VibeCore

/// Whether the user's node is built for this system, and what each command says where it isn't (the node on the Mac's
/// design, docs/superpowers/specs/2026-11-19-v2-node-on-macos.md, step 1). The user's node is built where the service
/// manager is systemd (Linux): its unit, its detached start, its journal, its voice rule. On the Mac (launchd) none of
/// that exists yet: no LaunchAgent, no host beside the app's (its root, `~/.vibeswitcher/v2/node`, is decided), no rule
/// that tells the user's voice from a session's. So there every command that would reach, start or stop the user's node
/// refuses at once, before it reads or runs anything, with this text and exit 69, rather than failing later on a Linux path (`/proc/self/exe`,
/// `/run/user/<uid>`, `systemctl`); and a user's server started there anyway takes no peer as the user's
/// (`VoiceRule.at`'s unbuilt closed rule). A scratch node is not refused: its harness starts it, and its tests decide.
public enum NodeSystem {
    /// Why the user's node isn't built for the system whose service manager is `manager`, or nil where it is.
    public static func usersNodeRefusal(manager: Platform.Service.Manager = Platform.Service.manager) -> String? {
        switch manager {
        case .systemd: return nil
        case .launchd: return macUnbuilt
        }
    }

    /// The exit code of that refusal: the service isn't available here (EX_UNAVAILABLE, the code "the node isn't
    /// running" has too).
    public static let refusalExitCode: Int32 = 69

    /// What the Mac's refusal says.
    public static let macUnbuilt = "the user's node isn't built for the Mac yet: no launchd agent starts it, its host and server (in ~/.vibeswitcher/v2/node, beside the app's ~/.vibeswitcher) aren't built there, "
        + "and no rule tells your voice from a session's there. The Mac app is unchanged; only a scratch node (VIBESWITCHER_HOME) runs here. "
        + "See docs/superpowers/specs/2026-11-19-v2-node-on-macos.md"

    /// Whether the Mac's rule (`VoiceRule.Mode.approval`, Touch ID per state change) is measured on a real Mac: the
    /// design's step 4 (LocalAuthentication from a LaunchAgent in `gui/<uid>`, the lid closed, over ssh, no Touch ID; the
    /// `open -a Terminal` and AppleScript escapes' process facts). False until then: the user's server there stays on
    /// the closed rule. Turning it on is this one line, after that measurement and an independent review.
    public static let approvalMeasured = false

    /// Why the user's server on a system with no cgroups is on the closed rule (`VoiceRule.at`, `usersNode`): no rule
    /// that tells the user's voice is built there, so no peer is the user's.
    public static let voiceUnbuilt = "closed: no rule tells the user's voice on this system yet (no cgroups; the Mac's rule isn't built), so no request is taken as the user's voice"
}
