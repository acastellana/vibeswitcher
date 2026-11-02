import Foundation
import Testing
import VibeCore

/// A contract call's calldata in words: the common token functions decoded (who may spend or receive what, unlimited
/// flagged), anything else plainly an unknown call that may move tokens.
struct WalletCallTests {
    static let token = "0x00000000000000000000000000000000000000aa"
    static let spender = "0x00000000000000000000000000000000000000bb"
    static let owner = "0x00000000000000000000000000000000000000cc"
    static let max = String(repeating: "f", count: 64)

    static func address(_ address: String) -> String { String(repeating: "0", count: 24) + address.dropFirst(2) }
    static func number(_ value: UInt64) -> String { String(repeating: "0", count: 48) + String(format: "%016llx", value) }
    static func call(_ selector: String, _ words: String...) -> String { "0x" + selector + words.joined() }

    @Test func approveNamesTheSpenderAndFlagsUnlimited() {
        let unlimited = WalletCall.decode(Self.call("095ea7b3", Self.address(Self.spender), Self.max), contract: Self.token)
        #expect(unlimited.function == "approve(address,uint256)")
        #expect(unlimited.headline == "Approve a spender" && unlimited.alarming)
        #expect(unlimited.fields == [.init("Spender", Self.spender),
                                     .init("Amount", "Unlimited (2^256−1, the largest there is)", alarming: true),
                                     .init("Token", Self.token)])
        #expect(unlimited.confirmation == "I understand this lets \(Self.spender) spend an unlimited amount of the token \(Self.token) from this wallet.")

        let some = WalletCall.decode(Self.call("095ea7b3", Self.address(Self.spender), Self.number(1_000_000)), contract: Self.token.uppercased().replacingOccurrences(of: "0X", with: "0x"))
        #expect(!some.alarming)
        #expect(some.fields[1] == .init("Amount", "1000000 base units"))
        #expect(some.fields[2] == .init("Token", Self.token))
        #expect(some.confirmation?.contains("1000000 base units") == true)
        // 2^96−1 and up is unlimited in effect, with its digits; just under isn't.
        #expect(WalletCall.decode(Self.call("095ea7b3", Self.address(Self.spender), String(repeating: "0", count: 40) + String(repeating: "f", count: 24)),
                                  contract: Self.token).fields[1].value == "Unlimited (79228162514264337593543950335 base units)")
        #expect(WalletCall.decode(Self.call("095ea7b3", Self.address(Self.spender), String(repeating: "0", count: 40) + String(repeating: "f", count: 24)),
                                  contract: Self.token).alarming)
        #expect(!WalletCall.decode(Self.call("095ea7b3", Self.address(Self.spender), String(repeating: "0", count: 40) + "fe" + String(repeating: "f", count: 22)),
                                   contract: Self.token).alarming)
    }

    @Test func increaseAllowanceAndPermitAskForConfirmation() {
        let raise = WalletCall.decode(Self.call("39509351", Self.address(Self.spender), Self.number(5)), contract: Self.token)
        #expect(raise.function == "increaseAllowance(address,uint256)" && raise.confirmation != nil)
        let permit = WalletCall.decode(Self.call("d505accf", Self.address(Self.owner), Self.address(Self.spender), Self.max,
                                                 Self.number(1_793_448_000), Self.number(27), Self.max, Self.max), contract: Self.token)
        #expect(permit.function == "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)")
        #expect(permit.alarming)
        #expect(permit.fields.map(\.name) == ["Owner", "Spender", "Amount", "Deadline", "Token"])
        #expect(permit.fields[3].value == "2026-10-31T12:00:00Z")
        #expect(permit.confirmation == "I understand this lets \(Self.spender) spend an unlimited amount of the token \(Self.token) from \(Self.owner).")
        // A v that isn't a uint8 doesn't decode as permit.
        #expect(WalletCall.decode(Self.call("d505accf", Self.address(Self.owner), Self.address(Self.spender), Self.max,
                                            Self.number(1), Self.number(256), Self.max, Self.max), contract: Self.token).function == nil)
    }

    @Test func setApprovalForAllGrantsEveryToken() {
        let grant = WalletCall.decode(Self.call("a22cb465", Self.address(Self.spender), Self.number(1)), contract: Self.token)
        #expect(grant.headline == "Approve an operator for every token" && grant.alarming)
        #expect(grant.fields[1].alarming)
        #expect(grant.confirmation == "I understand this lets \(Self.spender) move every token I hold in the collection \(Self.token).")
        let revoke = WalletCall.decode(Self.call("a22cb465", Self.address(Self.spender), Self.number(0)), contract: Self.token)
        #expect(revoke.headline == "Revoke an operator's approval" && !revoke.alarming && revoke.confirmation == nil)
        // A bool that's neither 0 nor 1 isn't one.
        #expect(WalletCall.decode(Self.call("a22cb465", Self.address(Self.spender), Self.number(2)), contract: Self.token).function == nil)
    }

    @Test func transfersNameTheRecipient() {
        let transfer = WalletCall.decode(Self.call("a9059cbb", Self.address(Self.spender), Self.number(42)), contract: Self.token)
        #expect(transfer.function == "transfer(address,uint256)" && !transfer.alarming && transfer.confirmation == nil)
        #expect(transfer.fields == [.init("Recipient", Self.spender), .init("Amount", "42 base units"), .init("Token", Self.token)])
        let from = WalletCall.decode(Self.call("23b872dd", Self.address(Self.owner), Self.address(Self.spender), Self.max), contract: Self.token)
        #expect(from.fields.map(\.name) == ["From", "Recipient", "Amount", "Token"] && from.fields[2].alarming)
        let nft = WalletCall.decode(Self.call("42842e0e", Self.address(Self.owner), Self.address(Self.spender), Self.number(7)), contract: Self.token)
        #expect(nft.headline == "Transfer an NFT" && nft.fields[2] == .init("Token id", "7"))
        // With bytes: an offset past the head, a length, the bytes padded.
        let withData = WalletCall.decode(Self.call("b88d4fde", Self.address(Self.owner), Self.address(Self.spender), Self.number(7), Self.number(128),
                                                   Self.number(3), "abcdef" + String(repeating: "0", count: 58)), contract: Self.token)
        #expect(withData.function == "safeTransferFrom(address,address,uint256,bytes)")
        #expect(withData.fields.last == .init("Data", "3 bytes passed on to the recipient"))
        let multi = WalletCall.decode(Self.call("f242432a", Self.address(Self.owner), Self.address(Self.spender), Self.number(7), Self.number(10),
                                                Self.number(160), Self.number(0)), contract: Self.token)
        #expect(multi.function == "safeTransferFrom(address,address,uint256,uint256,bytes)")
        #expect(multi.fields.map(\.name) == ["From", "Recipient", "Token id", "Amount", "Contract"])
        // An offset or a length near Int.max (an agent's calldata) doesn't decode, and doesn't overflow.
        let huge = String(repeating: "0", count: 48) + "7fffffffffffffe0"
        for selector in ["b88d4fde", "f242432a"] {
            let words = [Self.address(Self.owner), Self.address(Self.spender), Self.number(7)] + (selector == "f242432a" ? [Self.number(1)] : [])
            #expect(WalletCall.decode("0x" + selector + words.joined() + huge, contract: Self.token).function == nil)
        }
        #expect(WalletCall.decode(Self.call("b88d4fde", Self.address(Self.owner), Self.address(Self.spender), Self.number(7), Self.number(128), huge),
                                  contract: Self.token).function == nil)
        // An offset pointing outside the calldata doesn't decode.
        #expect(WalletCall.decode(Self.call("b88d4fde", Self.address(Self.owner), Self.address(Self.spender), Self.number(7), Self.number(4096)),
                                  contract: Self.token).function == nil)
    }

    @Test func anythingElseIsAnUnknownCallThatMayMoveTokens() {
        let other = WalletCall.decode("0x12345678" + Self.number(1), contract: Self.token)
        #expect(other.function == nil && other.alarming)
        #expect(other.confirmation == "I understand this call to the contract \(Self.token) wasn't decoded here, and it may move tokens from this wallet.")
        #expect(other.headline == "Unknown contract call: it may move tokens")
        #expect(other.fields == [.init("Function", "0x12345678"), .init("Calldata", "36 bytes, not decoded here")])
        // A known selector whose arguments don't decode: an address word with high bytes set, too few words.
        let dirty = WalletCall.decode(Self.call("095ea7b3", "01" + Self.address(Self.spender).dropFirst(2), Self.max), contract: Self.token)
        #expect(dirty.function == nil && dirty.headline == WalletCall.unknownHeadline)
        #expect(dirty.fields[0].value.contains("don't decode") && dirty.confirmation != nil)
        #expect(WalletCall.decode(Self.call("095ea7b3", Self.address(Self.spender)), contract: Self.token).function == nil)
        // Bytes after an approve's arguments: still decoded, and named.
        let extra = WalletCall.decode(Self.call("095ea7b3", Self.address(Self.spender), Self.number(1), "deadbeef"), contract: Self.token)
        #expect(extra.function == "approve(address,uint256)" && extra.fields.last == .init("Extra data", "4 bytes after the arguments", alarming: true))
        #expect(WalletCall.decode("0xabcd", contract: Self.token).headline == WalletCall.unknownHeadline)
    }
}
