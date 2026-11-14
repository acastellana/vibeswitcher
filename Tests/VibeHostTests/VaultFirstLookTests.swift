import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// Which host's vault holds its first look (the stage 2 plan's Task 10e, S2-D3; `VaultFirstLook`): on Linux the node's
/// host with no vault restored from a handover, and a scratch host only with `--hold-first-look`; never the Mac's.
struct VaultFirstLookTests {
    @Test func onlyAFreshNodeVaultOrAScratchHostAskedHoldsItsFirstLook() {
        let linux = !Platform.CodeIdentity.isAvailable
        let node = ["vibeswitcher-host", HostImages.nodeFlag]
        #expect(VaultFirstLook.holds(arguments: node, ownsLaunchers: true, restored: false) == linux)
        // A vault a handover carried keeps its own (in its state): set or not, it isn't set again here.
        #expect(!VaultFirstLook.holds(arguments: node, ownsLaunchers: true, restored: true))
        // A scratch host seals as before unless a test asks; the user's host never takes the test flag.
        #expect(!VaultFirstLook.holds(arguments: ["vibeswitcher-host", "--lock", "/x/h.lock"], ownsLaunchers: false, restored: false))
        #expect(VaultFirstLook.holds(arguments: ["vibeswitcher-host", VaultFirstLook.testFlag], ownsLaunchers: false, restored: false) == linux)
        #expect(!VaultFirstLook.holds(arguments: ["vibeswitcher-host", VaultFirstLook.testFlag], ownsLaunchers: true, restored: false))
        #expect(HostHardening.testFlags[VaultFirstLook.testFlag] == false)
        // A book is made not holding it.
        #expect(!LeadVault.Book().holdsFirstLook)
    }
}
