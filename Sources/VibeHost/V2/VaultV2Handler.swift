import Foundation
import VibeCore

/// The host's half of `HostRequest.vaultV2` (the engine plan's EN-D11): the node's record of the user's actions and
/// `.user` seals, kept in the vault's state (`LeadVault.Book.v2`, `LeadVaultV2`). The app's alone (`authorized` lets
/// nothing else through; checked here again), and only on Linux: the Mac's host doesn't list
/// `HostProtocol.Capability.vaultV2` and refuses every request here.
enum VaultV2Handler {
    static func answer(_ request: LeadVaultV2.Request, from caller: LeadVault.Caller, vault: LeadVault.Book?) -> LeadVaultV2.Reply {
        guard !Platform.CodeIdentity.isAvailable else { return .refused("This session host keeps no record of the user's actions (the Mac's).") }
        guard caller == .app else { return .refused(HostProtocol.unauthorized) }
        guard let vault else { return .refused("This session host keeps no lead vault.") }
        return vault.v2 { LeadVaultV2.answer(request, from: caller, book: &$0) }
    }
}
