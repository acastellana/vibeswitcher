import Foundation
import VibeCore

/// Whether a host's vault holds its first look (the stage 2 plan's Task 10e, S2-D3; the security architecture
/// document's S7, threat T35): on Linux the vault lives in the host's memory only, and a worker can cause a restart at
/// will, so a fresh vault takes nothing as its baseline that a worker could have written
/// (`LeadVault.Book.holdsFirstLook`). It holds for the node's host (`--node`) when it restored no vault from a
/// handover (a restored one keeps its own, in its state), and for a scratch host only with `--hold-first-look`, so
/// every other scratch host seals its first look as before. Never on the Mac, whose vault is sealed on disk under a
/// Keychain key and survives a restart.
public enum VaultFirstLook {
    public static let testFlag = "--hold-first-look"

    /// `arguments`: the host's; `ownsLaunchers`: it holds the user's lock; `restored`: its vault came from a handover.
    public static func holds(arguments: [String], ownsLaunchers: Bool, restored: Bool) -> Bool {
        guard !Platform.CodeIdentity.isAvailable, !restored else { return false }
        return arguments.contains(HostImages.nodeFlag) || (!ownsLaunchers && arguments.contains(testFlag))
    }
}
