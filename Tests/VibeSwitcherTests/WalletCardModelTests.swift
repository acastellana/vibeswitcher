import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// The wallet request card's display model: which buttons each state shows (Send to Wallet Manager only while waiting), the
/// chain names, and Settings › Wallet's saved values and its line about refused requests.
struct WalletCardModelTests {
    static let hash = "0x" + String(repeating: "0", count: 63) + "1"

    /// Every state, with made-up values.
    static let states: [WalletCardModel.State] = [
        .waiting, .sent, .unreachable(message: nil), .unreachable(message: "offline"), .received,
        .proposed(safeTxHash: nil), .proposed(safeTxHash: hash), .signed(txHash: hash, explorerURL: nil),
        .signed(txHash: hash, explorerURL: URL(string: "https://explorer.example/tx/1")),
        .rejected(reason: "over the limit"), .failed(message: "disconnected"), .expired,
        .unsure(message: nil), .unsure(message: "the connection dropped"), .notSent(reason: "refused as a secret"), .signedNotSubmitted,
    ]

    @Test func waitingShowsSendAndDiscard() {
        #expect(WalletCardModel.actions(for: .waiting) == [.send, .discard])
        #expect(WalletCardModel.Action.send.title == "Send to Wallet Manager")
    }

    @Test func unreachableShowsRetryAndDiscard() {
        #expect(WalletCardModel.actions(for: .unreachable(message: nil)) == [.retry, .discard])
        #expect(WalletCardModel.actions(for: .unreachable(message: "offline")) == [.retry, .discard])
    }

    @Test func onceSentOrAnsweredNoButtons() {
        for state in Self.states where state != .waiting {
            if case .unreachable = state { continue }
            if case .unsure = state { continue }
            if case .notSent = state { continue }
            // A finished card shown for what went wrong offers only Dismiss (WalletStripTests).
            let expected: [WalletCardModel.Action] = state.isFinished && state.showsOnStrip ? [.dismiss] : []
            #expect(WalletCardModel.actions(for: state) == expected, "\(state)")
        }
    }

    @Test func sendOnlyWhileWaiting() {
        for state in Self.states {
            #expect(WalletCardModel.actions(for: state).contains(.send) == (state == .waiting), "\(state)")
        }
    }

    /// A send that may have reached the Wallet Manager says so, and offers Retry (the same request again) and Discard; one
    /// that didn't leave and won't by sending again offers only Discard.
    @Test func anUnsureSendSaysItMayHaveReachedTheWalletManager() {
        #expect(WalletCardModel.actions(for: .unsure(message: nil)) == [.retry, .discard])
        #expect(WalletCardModel.detail(.unsure(message: "the connection dropped"), wallet: nil).contains("may have reached the Wallet Manager"))
        #expect(WalletCardModel.actions(for: .notSent(reason: "refused as a secret")) == [.discard])
        #expect(WalletCardModel.detail(.notSent(reason: "refused as a secret"), wallet: nil).contains("Nothing left this Mac"))
    }

    /// A check that failed in an answer that isn't a rejection is a warning; in a rejection, a failure.
    @Test func aFailedCheckOutsideARejectionIsAWarning() {
        let unknown = WalletCardModel.Check(name: "calldata", ok: false, detail: "unknown: shown raw")
        var card = WalletCardModel(id: "r", workspace: "example", from: "0x01", wallet: nil, to: "0x02", chainID: 1, asset: "ETH",
                                  amount: "1", reason: "a test", requestedBy: "example-agent", state: .proposed(safeTxHash: nil), checks: [unknown])
        #expect(card.isWarning(unknown))
        #expect(card.text.contains("⚠ calldata: unknown: shown raw"))
        card.state = .rejected(reason: "declined")
        #expect(!card.isWarning(unknown))
        #expect(card.text.contains("✗ calldata"))
        #expect(!card.isWarning(.init(name: "balance", ok: true)))
    }

    /// A contract call: the card says what it does (an approve's spender, an unlimited amount), never just "0 GEN", and
    /// no longer claims the Wallet Manager decodes it; who asked is the session's name with the agent's label beside
    /// it; the reason is quoted as the agent's words.
    @Test func aCallSaysWhatItDoesAndTheReasonIsTheAgents() {
        let approve = "0x095ea7b3" + String(repeating: "0", count: 24) + "00000000000000000000000000000000000000bb" + String(repeating: "f", count: 64)
        let request = WalletRequest(createdAt: Date(timeIntervalSince1970: 1_793_448_000), expiresAt: Date(timeIntervalSince1970: 1_793_534_400),
                                    requestedBy: .init(project: "p", session: "s", label: "Payroll bot"), workspace: "example",
                                    from: "0x00000000000000000000000000000000000000aa", chainId: 42_424_242, action: .call,
                                    to: "0x00000000000000000000000000000000000000cc", asset: "native", amount: "0", data: approve,
                                    reason: "Routine.\nAmount: 1 GEN")
        let card = WalletCardModel(request: request, requestedBy: "Fix login", label: "Payroll bot", state: .waiting)
        #expect(card.call?.headline == "Approve a spender" && card.call?.alarming == true)
        let text = card.text
        #expect(text.contains("Call: Approve a spender (approve(address,uint256))"))
        #expect(text.contains("  Spender: 0x00000000000000000000000000000000000000bb"))
        #expect(text.contains("  Amount: Unlimited ("))
        #expect(text.contains("Value sent: 0 GEN") && !text.contains("\nAmount: 0 GEN"))
        #expect(!text.contains("decoded and shown on the Wallet Manager's Mac"))
        #expect(text.contains("Requested by: Fix login (the agent's label: Payroll bot)"))
        #expect(text.contains("Reason, in the agent's words: “Routine.\nAmount: 1 GEN”"))
        // Any other calldata: plainly unknown.
        var other = request
        other.data = "0x12345678"
        let unknown = WalletCardModel(request: other, requestedBy: "Fix login", state: .waiting)
        #expect(unknown.text.contains("Call: Unknown contract call: it may move tokens"))
        // A transfer: its amount, no call; the same label as the name isn't repeated.
        var transfer = request
        (transfer.action, transfer.data, transfer.amount) = (.transfer, nil, "1000000000000000000")
        let plain = WalletCardModel(request: transfer, requestedBy: "Payroll bot", label: "Payroll bot", state: .waiting)
        #expect(plain.call == nil && plain.text.contains("Amount: 1 GEN") && plain.requestedByText == "Payroll bot")
    }

    @Test func chainNames() {
        #expect(WalletCardModel.chainName(42424242) == "GenLayer")
        #expect(WalletCardModel.chainName(1) == "Ethereum")
        #expect(WalletCardModel.chainName(11155111) == "Sepolia")
        #expect(WalletCardModel.chainName(8453) == "Base")
        #expect(WalletCardModel.chainName(84532) == "Base Sepolia")
        #expect(WalletCardModel.chainName(4221) == "GenLayer Testnet")
        #expect(WalletCardModel.chainName(5) == "chain 5")
        var card = WalletCardModel(id: "r", workspace: "example", from: "0x01", wallet: .hardware, to: "0x02", chainID: 42424242, asset: "GEN",
                                  amount: "1", reason: "a test", requestedBy: "example-agent", state: .waiting)
        #expect(card.chainText == "GenLayer (42424242)")
        card.chainID = 7
        #expect(card.chainText == "chain 7")
    }

    @Test func everyStateHasATitleAndALine() {
        for state in Self.states {
            #expect(!WalletCardModel.title(state).isEmpty)
            for wallet in WalletCardModel.Wallet.allCases.map(Optional.some) + [nil] { #expect(!WalletCardModel.detail(state, wallet: wallet).isEmpty) }
        }
        #expect(WalletCardModel.detail(.rejected(reason: "over the limit"), wallet: .hot).contains("over the limit"))
    }

    /// From a Safe, proposed reads as waiting for the other owners; its buttons are the same as any wallet's.
    @Test func aSafesProposalWaitsForTheOtherOwners() {
        let proposed = WalletCardModel.State.proposed(safeTxHash: Self.hash)
        #expect(WalletCardModel.detail(proposed, wallet: .safe).contains("other owners' signatures"))
        #expect(!WalletCardModel.detail(proposed, wallet: .hardware).contains("Safe"))
        let card = WalletCardModel(id: "r", workspace: "example", from: "0x01", wallet: .safe, to: "0x02", chainID: 1, asset: "ETH",
                                  amount: "1", reason: "a test", requestedBy: "example-agent", state: proposed)
        #expect(card.actions.isEmpty)
        #expect(card.text.contains("Safe transaction: \(Self.hash)"))
        #expect(card.text.contains("Workspace: example"))
    }

    /// Only a Safe waits for other owners: a hot or hardware wallet's proposal (or one from a wallet not known to be a
    /// Safe, as a card is until a Safe transaction hash says so) waits for the person at the Wallet Manager's Mac.
    @Test func onlyASafesProposalWaitsForOtherSignatures() {
        let proposed = WalletCardModel.State.proposed(safeTxHash: nil)
        for wallet in [WalletCardModel.Wallet.hot, .hardware, nil] {
            let detail = WalletCardModel.detail(proposed, wallet: wallet)
            #expect(detail == "Proposed: waiting for the person at the Wallet Manager's Mac to sign it.", "\(String(describing: wallet))")
            #expect(!detail.contains("other") && !detail.contains("Safe"), "\(String(describing: wallet))")
        }
        #expect(WalletCardModel.detail(proposed, wallet: .safe) == "Proposed to the Safe: waiting for the other owners' signatures.")
    }

    @Test func settingsKeepThePeerAndPathAndSayWhatRequestsDoWithoutOne() throws {
        let temp = Scratch()
        let defaults = temp.defaults("wallet-settings")
        let presets = temp.url("wallet-settings-presets")
        let preferences = Preferences(defaults: defaults, presetsFile: presets)
        let peers = [WalletPeerChoice(peerID: "peer-1", name: "Example Wallet Manager Mac")]
        #expect(preferences.walletPeerID == "")
        #expect(WalletSettingsTab.status(peers, saved: preferences.walletPeerID) == WalletSettingsTab.noPeerNote)
        preferences.walletPeerID = "peer-1"
        preferences.walletPassagePath = "/opt/example/passage"
        let again = Preferences(defaults: defaults, presetsFile: presets)
        #expect(again.walletPeerID == "peer-1")
        #expect(again.walletPassagePath == "/opt/example/passage")
        #expect(WalletSettingsTab.status(peers, saved: again.walletPeerID).contains("Example Wallet Manager Mac"))
        // A saved peer that isn't listed now stays a choice, so the picker doesn't drop it.
        #expect(WalletSettingsTab.choices([], saved: "peer-1").map(\.peerID) == ["peer-1"])
        #expect(WalletSettingsTab.choices(peers, saved: "peer-1") == peers)
        #expect(WalletSettingsTab.choices(peers, saved: "") == peers)
    }

    @Test func theVaultEraKeysAreCarriedOverOnceThenRemoved() throws {
        let temp = Scratch()
        let defaults = temp.defaults("wallet-carry")
        let presets = temp.url("wallet-carry-presets")
        defaults.set("0a1b2c3d", forKey: "vaultPeerID")
        defaults.set("/opt/example/passage", forKey: "vaultPassagePath")
        let preferences = Preferences(defaults: defaults, presetsFile: presets)
        #expect(preferences.walletPeerID == "0a1b2c3d")
        #expect(preferences.walletPassagePath == "/opt/example/passage")
        #expect(defaults.object(forKey: "vaultPeerID") == nil)
        #expect(defaults.object(forKey: "vaultPassagePath") == nil)
        // Once: a later change stays, and an old key that shows up again doesn't overwrite a value already set.
        preferences.walletPeerID = "0d0d0d0d"
        defaults.set("0e0e0e0e", forKey: "vaultPeerID")
        let again = Preferences(defaults: defaults, presetsFile: presets)
        #expect(again.walletPeerID == "0d0d0d0d")
        #expect(again.walletPassagePath == "/opt/example/passage")
        #expect(defaults.object(forKey: "vaultPeerID") == nil)
    }
}
