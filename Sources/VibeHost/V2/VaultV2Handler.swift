import Foundation
import VibeCore

/// The host's half of `HostRequest.vaultV2` (the engine plan's EN-D11): the node's record of the user's actions and
/// `.user` seals, kept in the vault's state (`LeadVault.Book.v2`, `LeadVaultV2`). The app's alone (`authorized` lets
/// nothing else through; checked here again): on Linux the node's server through its connector; on the Mac only a node's
/// host, one that runs a server child (`nodeHost`: the node on the Mac's step 3), never the Mac app's host, which lists no
/// `HostProtocol.Capability.vaultV2` and refuses every request here, as before. The same rules on both
/// (`LeadVaultV2.answer`): the record and the replay `Requests.voiced` asks for.
enum VaultV2Handler {
    /// `viaConnector`: the connection is the server child's, through its connector. On the Mac only that is the app
    /// here, never a socket's peer that proved itself (the review of 2026-11-21).
    static func answer(_ request: LeadVaultV2.Request, from caller: LeadVault.Caller, vault: LeadVault.Book?, nodeHost: Bool = false,
                       viaConnector: Bool = false) -> LeadVaultV2.Reply {
        guard !Platform.CodeIdentity.isAvailable || nodeHost else { return .refused("This session host keeps no record of the user's actions (the Mac app's).") }
        guard !Platform.CodeIdentity.isAvailable || viaConnector else { return .refused(HostProtocol.unauthorized) }
        guard caller == .app else { return .refused(HostProtocol.unauthorized) }
        guard let vault else { return .refused("This session host keeps no lead vault.") }
        // Read before `v2` takes the vault's lock (`recordsActions` takes it too).
        let on = vault.recordsActions
        return vault.v2 { LeadVaultV2.answer(request, from: caller, book: &$0, on: on) }
    }
}
