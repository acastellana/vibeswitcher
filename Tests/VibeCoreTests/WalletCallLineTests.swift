import Foundation
import Testing
import VibeCore

/// Safe's approveHash and execTransaction decoded by selector and exact layout, and every call's one line
/// (`WalletCall.line`): VibeSwitcher's own words from the calldata, addresses shortened.
struct WalletCallLineTests {
    typealias T = WalletCallTests
    /// The Safe from the user's local-fork card (2026-11-06), as the request wrote it.
    static let safe = "0x16F7fFed6fc5113b34188d79c632760d7A20915b"
    /// That card's approveHash: 0xd4d9bdcd and one bytes32, 36 bytes. Only the hash's start was on the card.
    static let hash = "2ff4171f" + "9c0e4a6b5d3f2817e6a9b0c1d2e3f405162738495a6b7c8d9e0f1a2b"
    static let approveHash = "0xd4d9bdcd" + hash

    static func padded(_ hex: String) -> String {
        hex + String(repeating: "0", count: (64 - hex.count % 64) % 64)
    }

    /// execTransaction's calldata as an ABI encoder writes it.
    static func exec(to: String, value: UInt64 = 0, data: String = "", operation: UInt64 = 0, gasPrice: UInt64 = 0,
                     signatures: String = String(repeating: "ab", count: 65)) -> String {
        let dataLength = data.count / 2, sigLength = signatures.count / 2
        let dataOffset = 10 * 32, sigOffset = dataOffset + 32 + (dataLength + 31) / 32 * 32
        return T.call("6a761202", T.address(to), T.number(value), T.number(UInt64(dataOffset)), T.number(operation),
                      T.number(0), T.number(0), T.number(gasPrice), T.address("0x" + String(repeating: "0", count: 40)),
                      T.address("0x" + String(repeating: "0", count: 40)), T.number(UInt64(sigOffset)),
                      T.number(UInt64(dataLength)), padded(data), T.number(UInt64(sigLength)), padded(signatures))
    }

    @Test func approveHashDecodesFromTheRealCardsCalldata() {
        let call = WalletCall.decode(Self.approveHash, contract: Self.safe)
        #expect(call.function == "approveHash(bytes32)")
        #expect(call.headline == "Approve a Safe transaction" && !call.alarming)
        #expect(call.fields == [.init("Safe transaction hash", "0x" + Self.hash), .init("Safe", Self.safe.lowercased())])
        #expect(call.line == "Approve Safe transaction 0x2ff4171f… on Safe 0x16F7…915b")
    }

    @Test func malformedApproveHashIsUnknown() {
        for data in [Self.approveHash + "00", String(Self.approveHash.dropLast(2)), Self.approveHash + String(repeating: "0", count: 64), "0xd4d9bdcd"] {
            let call = WalletCall.decode(data, contract: Self.safe)
            #expect(call.function == nil && call.headline == WalletCall.unknownHeadline && call.alarming, "\(data)")
            #expect(call.line == "Call 0xd4d9bdcd on 0x16F7…915b (not decoded)", "\(data)")
            #expect(call.fields.first?.value.contains("its arguments don't decode") == true, "\(data)")
        }
    }

    @Test func execTransactionNamesTheTargetAndItsDecodedFunction() throws {
        let approve = "095ea7b3" + T.address(T.spender) + T.number(1_000)
        let call = WalletCall.decode(Self.exec(to: T.token, data: approve), contract: Self.safe)
        #expect(call.function == "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)")
        #expect(call.headline == "Execute a Safe transaction" && !call.alarming)
        #expect(call.line == "Execute a Safe transaction on 0x16F7…915b: approve(address,uint256) on 0x0000…00aa")
        let fields = Dictionary(call.fields.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
        #expect(fields["Target"] == T.token && fields["Operation"] == "call" && fields["Inner call"] == "Approve a spender (approve(address,uint256))")
        #expect(fields["Inner: Spender"] == T.spender && fields["Signatures"] == "65 bytes")
        #expect(call.confirmation != nil)

        // A value with no data: a plain send from the Safe.
        let send = WalletCall.decode(Self.exec(to: T.owner, value: 5), contract: Self.safe)
        #expect(send.function != nil && send.line == "Execute a Safe transaction on 0x16F7…915b: send 5 base units of the native coin to 0x0000…00cc")
        // Inner data not decoded: its selector, said plainly, and red.
        let other = WalletCall.decode(Self.exec(to: T.owner, data: "12345678aa"), contract: Self.safe)
        #expect(other.alarming && other.line == "Execute a Safe transaction on 0x16F7…915b: call 0x12345678 on 0x0000…00cc (not decoded)")
        // A delegatecall is said so, and red.
        let delegate = WalletCall.decode(Self.exec(to: T.owner, data: approve, operation: 1), contract: Self.safe)
        #expect(delegate.alarming && delegate.line == "Execute a Safe transaction on 0x16F7…915b: delegatecall approve(address,uint256) on 0x0000…00cc")
        // A gas refund is red.
        #expect(WalletCall.decode(Self.exec(to: T.owner, data: approve, gasPrice: 1), contract: Self.safe).alarming)
        // An execTransaction inside another isn't decoded further.
        let nested = WalletCall.decode(Self.exec(to: T.owner, data: String(Self.exec(to: T.owner).dropFirst(2))), contract: Self.safe)
        #expect(nested.line == "Execute a Safe transaction on 0x16F7…915b: call 0x6a761202 on 0x0000…00cc (not decoded)")
    }

    @Test func malformedExecTransactionIsUnknown() {
        let good = Self.exec(to: T.token, data: "095ea7b3" + T.address(T.spender) + T.number(1))
        #expect(WalletCall.decode(good, contract: Self.safe).function != nil)
        func word(_ index: Int, of calldata: String, set value: String) -> String {
            var hex = Array(calldata.dropFirst(10))
            hex.replaceSubrange(index * 64..<(index + 1) * 64, with: Array(value))
            return "0x6a761202" + String(hex)
        }
        let bad = [
            good + "00",                                                     // not whole words
            good + String(repeating: "0", count: 64),                        // a word after the signatures
            String(good.dropLast(64)),                                       // signatures cut short
            word(2, of: good, set: T.number(352)),                           // data's offset moved
            word(2, of: good, set: T.number(1 << 40)),                       // data's offset out of bounds
            word(9, of: good, set: T.number(10_000)),                        // signatures' offset out of bounds
            word(10, of: good, set: T.number(1_000)),                        // data's length past the end
            word(3, of: good, set: T.number(2)),                             // no such operation
            word(0, of: good, set: String(repeating: "f", count: 64)),       // to isn't an address
            "0x6a761202" + T.address(T.token),                               // one argument only
        ]
        for data in bad {
            let call = WalletCall.decode(data, contract: Self.safe)
            #expect(call.function == nil && call.alarming && call.line == "Call 0x6a761202 on 0x16F7…915b (not decoded)", "\(data)")
        }
        // Nonzero padding after the data isn't what an encoder writes.
        let dirty = Self.exec(to: T.token, data: "12345678").replacingOccurrences(of: "12345678" + String(repeating: "0", count: 56), with: "12345678" + String(repeating: "0", count: 55) + "1")
        #expect(WalletCall.decode(dirty, contract: Self.safe).function == nil)
    }

    @Test func eachTokenFunctionHasItsLine() {
        func line(_ data: String) -> String { WalletCall.decode(data, contract: T.token).line }
        #expect(line(T.call("095ea7b3", T.address(T.spender), T.max)) == "Approve a spender: 0x0000…00bb may spend an unlimited amount of token 0x0000…00aa")
        #expect(line(T.call("095ea7b3", T.address(T.spender), T.number(7))) == "Approve a spender: 0x0000…00bb may spend 7 base units of token 0x0000…00aa")
        #expect(line(T.call("39509351", T.address(T.spender), T.number(7))) == "Raise a spender's allowance: 0x0000…00bb may spend 7 base units more of token 0x0000…00aa")
        #expect(line(T.call("a9059cbb", T.address(T.spender), T.number(3))) == "Transfer tokens: 3 base units of token 0x0000…00aa to 0x0000…00bb")
        #expect(line(T.call("23b872dd", T.address(T.owner), T.address(T.spender), T.number(3))) == "Transfer tokens from an account: 3 base units of token 0x0000…00aa from 0x0000…00cc to 0x0000…00bb")
        #expect(line(T.call("a22cb465", T.address(T.spender), T.number(1))) == "Approve an operator for every token: 0x0000…00bb may move every token of collection 0x0000…00aa")
        #expect(line(T.call("a22cb465", T.address(T.spender), T.number(0))) == "Revoke an operator's approval: 0x0000…00bb on collection 0x0000…00aa")
        #expect(line(T.call("42842e0e", T.address(T.owner), T.address(T.spender), T.number(9))) == "Transfer an NFT: token id 9 of collection 0x0000…00aa from 0x0000…00cc to 0x0000…00bb")
        #expect(line(T.call("d505accf", T.address(T.owner), T.address(T.spender), T.max, T.number(1), T.number(27), T.max, T.max))
            == "Permit: approve a spender: 0x0000…00bb may spend an unlimited amount of token 0x0000…00aa from 0x0000…00cc")
        #expect(line("0x12345678") == "Call 0x12345678 on 0x0000…00aa (not decoded)")
        #expect(line("0x12") == "Call 0x0000…00aa with 1 bytes of calldata (not decoded)")
    }

    /// The line is plain code over the bytes: the same calldata gives the identical string every time.
    @Test func theSameBytesGiveTheSameLine() {
        for data in [Self.approveHash, Self.exec(to: T.token, data: "095ea7b3" + T.address(T.spender) + T.number(1)), "0x12345678"] {
            #expect(WalletCall.decode(data, contract: Self.safe) == WalletCall.decode(data, contract: Self.safe))
            #expect(WalletCall.decode(data, contract: Self.safe).line == WalletCall.decode(String(data), contract: String(Self.safe)).line)
        }
    }
}
