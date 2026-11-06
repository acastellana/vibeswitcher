import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// The card's lead line (`WalletCardModel.line`): what the transaction does, from the request's fields and calldata
/// alone, never its reason or label; the local-fork badge beside it; and the browser wallet's page leading with the same.
struct WalletCardLineTests {
    static let safe = "0x16F7fFed6fc5113b34188d79c632760d7A20915b"
    static let approveHash = "0xd4d9bdcd2ff4171f9c0e4a6b5d3f2817e6a9b0c1d2e3f405162738495a6b7c8d9e0f1a2b"

    static func request(action: WalletRequest.Action = .transfer, to: String = "0x123456789012345678901234567890123456abcd",
                        asset: String = "native", amount: String = "12500000000000000000", data: String? = nil,
                        reason: String = "Pay the invoice.", label: String = "") -> WalletRequest {
        WalletRequest(createdAt: Date(timeIntervalSince1970: 1_793_448_000), expiresAt: Date(timeIntervalSince1970: 1_793_534_400),
                      requestedBy: .init(project: "p", session: "s", label: label), workspace: "wgmi",
                      from: "0x00000000000000000000000000000000000000aa", chainId: 4221, action: action,
                      to: to, asset: asset, amount: amount, data: data, reason: reason)
    }

    static func card(_ request: WalletRequest) -> WalletCardModel {
        WalletCardModel(request: request, requestedBy: "Local test", label: request.requestedBy.label, state: .waiting)
    }

    @Test func aNativeTransferSaysTheAmountAndTheShortRecipient() {
        let card = Self.card(Self.request())
        #expect(card.line == "Send 12.5 GEN to 0x1234…abcd")
        // The row keeps the whole address.
        #expect(card.text.contains("To: 0x123456789012345678901234567890123456abcd"))
    }

    @Test func aTokenTransferNamesTheToken() {
        let card = Self.card(Self.request(asset: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", amount: "2500000"))
        #expect(card.line == "Send 2500000 base units of token 0xA0b8…eB48 to 0x1234…abcd")
    }

    @Test func callsLeadWithTheirDecodedLine() {
        let card = Self.card(Self.request(action: .call, to: Self.safe, amount: "0", data: Self.approveHash))
        #expect(card.line == "Approve Safe transaction 0x2ff4171f… on Safe 0x16F7…915b")
        let lines = card.text.components(separatedBy: "\n")
        #expect(lines[1] == card.line)
        // A call that also sends value says so.
        let paying = Self.card(Self.request(action: .call, to: Self.safe, amount: "1000000000000000000", data: Self.approveHash))
        #expect(paying.line == "Approve Safe transaction 0x2ff4171f… on Safe 0x16F7…915b, sending 1 GEN")
    }

    /// An unknown call: the line says it isn't decoded, and the red row stays.
    @Test func anUnknownCallSaysNotDecodedAndKeepsItsWarning() {
        let card = Self.card(Self.request(action: .call, to: Self.safe, amount: "0", data: "0x12345678"))
        #expect(card.line == "Call 0x12345678 on 0x16F7…915b (not decoded)")
        #expect(card.call?.alarming == true && card.text.contains("Call: \(WalletCall.unknownHeadline)"))
    }

    /// The reason and the label claim one thing; the line says what the calldata does.
    @Test func theLineNeverTakesTheReasonOrLabel() {
        let lying = Self.request(action: .call, to: Self.safe, amount: "0", data: "0x12345678",
                                 reason: "Send 0 GEN, harmless", label: "Send 0 GEN, harmless")
        let card = Self.card(lying)
        #expect(card.line == "Call 0x12345678 on 0x16F7…915b (not decoded)")
        #expect(!card.line.contains("harmless"))
        let approve = Self.card(Self.request(action: .call, to: Self.safe, amount: "0", data: Self.approveHash, reason: "Send 0 GEN, harmless"))
        #expect(approve.line == "Approve Safe transaction 0x2ff4171f… on Safe 0x16F7…915b")
    }

    @Test func theSameRequestGivesTheSameLine() {
        let request = Self.request(action: .call, to: Self.safe, amount: "0", data: Self.approveHash)
        #expect(Self.card(request).line == Self.card(request).line)
        #expect(Self.card(Self.request()).line == Self.card(Self.request()).line)
    }

    @Test func aLocalForkRequestHasTheBadge() {
        let fork = Self.card(Self.request(action: .call, to: Self.safe, amount: "0", data: Self.approveHash,
                                          reason: "LOCAL FORK ONLY\nApprove the hash on the forked Safe."))
        #expect(fork.localForkOnly)
        #expect(WalletCardModel.localForkBadge == "Local fork only")
        #expect(fork.text.components(separatedBy: "\n")[1] == fork.line + " [Local fork only]")
        let plain = Self.card(Self.request(action: .call, to: Self.safe, amount: "0", data: Self.approveHash))
        #expect(!plain.localForkOnly && !plain.text.contains("Local fork only"))
    }

    @Test func theBrowserPageLeadsWithTheSameLine() throws {
        let transfer = Self.request()
        let page = try #require(WalletSignPage.data(for: transfer))
        #expect(page["line"] as? String == "Send 12.5 GEN to 0x1234…abcd")
        let html = try #require(WalletSignPage.html(for: transfer))
        #expect(html.contains(#"<p id="line" class="line"></p>"#))
        let unknown = try #require(WalletSignPage.data(for: Self.request(action: .call, to: Self.safe, amount: "0", data: "0x12345678")))
        #expect(unknown["line"] as? String == "Call 0x12345678 on 0x16F7…915b (not decoded)" && unknown["lineBad"] as? Bool == true)
    }
}
