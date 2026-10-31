import Foundation
import Testing
@testable import VibeSwitcher

/// The vault request card's display model: which buttons each state shows (Send to vault only while waiting), the
/// chain names, and Settings › Vault's saved values and its line about refused requests.
struct VaultCardModelTests {
    static let hash = "0x" + String(repeating: "0", count: 63) + "1"

    /// Every state, with made-up values.
    static let states: [VaultCardModel.State] = [
        .waiting, .sent, .unreachable(message: nil), .unreachable(message: "offline"), .received,
        .proposed(safeTxHash: nil), .proposed(safeTxHash: hash), .signed(txHash: hash, explorerURL: nil),
        .signed(txHash: hash, explorerURL: URL(string: "https://explorer.example/tx/1")),
        .rejected(reason: "over the limit"), .failed(message: "disconnected"), .expired,
        .unsure(message: nil), .unsure(message: "the connection dropped"), .notSent(reason: "refused as a secret"), .signedNotSubmitted,
    ]

    @Test func waitingShowsSendAndDiscard() {
        #expect(VaultCardModel.actions(for: .waiting) == [.send, .discard])
        #expect(VaultCardModel.Action.send.title == "Send to vault")
    }

    @Test func unreachableShowsRetryAndDiscard() {
        #expect(VaultCardModel.actions(for: .unreachable(message: nil)) == [.retry, .discard])
        #expect(VaultCardModel.actions(for: .unreachable(message: "offline")) == [.retry, .discard])
    }

    @Test func onceSentOrAnsweredNoButtons() {
        for state in Self.states where state != .waiting {
            if case .unreachable = state { continue }
            if case .unsure = state { continue }
            if case .notSent = state { continue }
            #expect(VaultCardModel.actions(for: state).isEmpty, "\(state)")
        }
    }

    @Test func sendOnlyWhileWaiting() {
        for state in Self.states {
            #expect(VaultCardModel.actions(for: state).contains(.send) == (state == .waiting), "\(state)")
        }
    }

    /// A send that may have reached the vault says so, and offers Retry (the same request again) and Discard; one
    /// that didn't leave and won't by sending again offers only Discard.
    @Test func anUnsureSendSaysItMayHaveReachedTheVault() {
        #expect(VaultCardModel.actions(for: .unsure(message: nil)) == [.retry, .discard])
        #expect(VaultCardModel.detail(.unsure(message: "the connection dropped"), wallet: nil).contains("may have reached the vault"))
        #expect(VaultCardModel.actions(for: .notSent(reason: "refused as a secret")) == [.discard])
        #expect(VaultCardModel.detail(.notSent(reason: "refused as a secret"), wallet: nil).contains("Nothing left this Mac"))
    }

    /// A check that failed in an answer that isn't a rejection is a warning; in a rejection, a failure.
    @Test func aFailedCheckOutsideARejectionIsAWarning() {
        let unknown = VaultCardModel.Check(name: "calldata", ok: false, detail: "unknown: shown raw")
        var card = VaultCardModel(id: "r", workspace: "example", from: "0x01", wallet: nil, to: "0x02", chainID: 1, asset: "ETH",
                                  amount: "1", reason: "a test", requestedBy: "example-agent", state: .proposed(safeTxHash: nil), checks: [unknown])
        #expect(card.isWarning(unknown))
        #expect(card.text.contains("⚠ calldata: unknown: shown raw"))
        card.state = .rejected(reason: "declined")
        #expect(!card.isWarning(unknown))
        #expect(card.text.contains("✗ calldata"))
        #expect(!card.isWarning(.init(name: "balance", ok: true)))
    }

    @Test func chainNames() {
        #expect(VaultCardModel.chainName(42424242) == "GenLayer")
        #expect(VaultCardModel.chainName(1) == "Ethereum")
        #expect(VaultCardModel.chainName(5) == "chain 5")
        var card = VaultCardModel(id: "r", workspace: "example", from: "0x01", wallet: .hardware, to: "0x02", chainID: 42424242, asset: "GEN",
                                  amount: "1", reason: "a test", requestedBy: "example-agent", state: .waiting)
        #expect(card.chainText == "GenLayer (42424242)")
        card.chainID = 7
        #expect(card.chainText == "chain 7")
    }

    @Test func everyStateHasATitleAndALine() {
        for state in Self.states {
            #expect(!VaultCardModel.title(state).isEmpty)
            for wallet in VaultCardModel.Wallet.allCases.map(Optional.some) + [nil] { #expect(!VaultCardModel.detail(state, wallet: wallet).isEmpty) }
        }
        #expect(VaultCardModel.detail(.rejected(reason: "over the limit"), wallet: .hot).contains("over the limit"))
    }

    /// From a Safe, proposed reads as waiting for the other owners; its buttons are the same as any wallet's.
    @Test func aSafesProposalWaitsForTheOtherOwners() {
        let proposed = VaultCardModel.State.proposed(safeTxHash: Self.hash)
        #expect(VaultCardModel.detail(proposed, wallet: .safe).contains("other owners' signatures"))
        #expect(!VaultCardModel.detail(proposed, wallet: .hardware).contains("Safe"))
        let card = VaultCardModel(id: "r", workspace: "example", from: "0x01", wallet: .safe, to: "0x02", chainID: 1, asset: "ETH",
                                  amount: "1", reason: "a test", requestedBy: "example-agent", state: proposed)
        #expect(card.actions.isEmpty)
        #expect(card.text.contains("Safe transaction: \(Self.hash)"))
        #expect(card.text.contains("Workspace: example"))
    }

    @Test func settingsKeepThePeerAndPathAndSayWhenRequestsAreRefused() throws {
        let temp = Scratch()
        let defaults = temp.defaults("vault-settings")
        let presets = temp.url("vault-settings-presets")
        let preferences = Preferences(defaults: defaults, presetsFile: presets)
        let peers = [VaultPeerChoice(peerID: "peer-1", name: "Example vault Mac")]
        #expect(preferences.vaultPeerID == "")
        #expect(VaultSettingsTab.status(peers, saved: preferences.vaultPeerID) == VaultSettingsTab.refusedNote)
        preferences.vaultPeerID = "peer-1"
        preferences.vaultPassagePath = "/opt/example/passage"
        let again = Preferences(defaults: defaults, presetsFile: presets)
        #expect(again.vaultPeerID == "peer-1")
        #expect(again.vaultPassagePath == "/opt/example/passage")
        #expect(VaultSettingsTab.status(peers, saved: again.vaultPeerID).contains("Example vault Mac"))
        // A saved peer that isn't listed now stays a choice, so the picker doesn't drop it.
        #expect(VaultSettingsTab.choices([], saved: "peer-1").map(\.peerID) == ["peer-1"])
        #expect(VaultSettingsTab.choices(peers, saved: "peer-1") == peers)
        #expect(VaultSettingsTab.choices(peers, saved: "") == peers)
    }
}
