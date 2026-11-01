import Foundation
import Testing
@testable import VibeCore

/// The browser wallet fallback's core (`WalletBrowser`): the transaction the page asks the wallet to send, the chains it
/// may add, the strict check of what the page posts back, and the mark that records a request went that way.
struct WalletBrowserTests {
    let scratch = Scratch()
    static let created = Date(timeIntervalSince1970: 1_793_448_000)
    static let from = "0x00000000000000000000000000000000000000aa"

    static func request(from: String = from, action: WalletRequest.Action = .transfer, asset: String = "native",
                        amount: String = "1250000000000000000", data: String? = nil, chain: Int64 = 42_424_242) -> WalletRequest {
        WalletRequest(id: "00000000-0000-4000-8000-000000000001", createdAt: created, expiresAt: created.addingTimeInterval(86_400),
                      requestedBy: .init(project: "example-project", session: "11111111-2222-4333-8444-555555555555", label: "Example agent"),
                      workspace: "example", from: from, chainId: chain, action: action, to: "0x0000000000000000000000000000000000000001",
                      asset: asset, amount: amount, data: data, reason: "Pay the example invoice.")
    }

    @Test func amountsBecomeHexQuantities() {
        #expect(WalletBrowser.hexQuantity("0") == "0x0")
        #expect(WalletBrowser.hexQuantity("255") == "0xff")
        #expect(WalletBrowser.hexQuantity("1000000000000000000") == "0xde0b6b3a7640000")
        #expect(WalletBrowser.hexQuantity("1250000000000000000") == "0x1158e460913d0000")
        // 2^200, 61 digits: well past 64-bit.
        #expect(WalletBrowser.hexQuantity("1606938044258990275541962092341162602522202993782792835301376") == "0x1" + String(repeating: "0", count: 50))
        #expect(WalletBrowser.hexQuantity("") == nil)
        #expect(WalletBrowser.hexQuantity("-1") == nil)
        #expect(WalletBrowser.hexQuantity("1e18") == nil)
    }

    @Test func theTransactionIsTheRequestAsTheWalletTakesIt() throws {
        let coin = try #require(WalletBrowser.transaction(for: Self.request()))
        #expect(coin == .init(from: Self.from, to: "0x0000000000000000000000000000000000000001", value: "0x1158e460913d0000", data: nil))
        let call = try #require(WalletBrowser.transaction(for: Self.request(action: .call, amount: "0", data: "0xdeadbeef")))
        #expect(call == .init(from: Self.from, to: "0x0000000000000000000000000000000000000001", value: "0x0", data: "0xdeadbeef"))
        // A token: transfer(to, amount) on the token's contract, no coin sent.
        let token = "0x00000000000000000000000000000000000000cc"
        let transfer = try #require(WalletBrowser.transaction(for: Self.request(asset: token, amount: "255")))
        #expect(transfer.to == token && transfer.value == "0x0")
        #expect(transfer.data == "0xa9059cbb" + String(repeating: "0", count: 63) + "1" + String(repeating: "0", count: 62) + "ff")
        // A wallet id names a wallet only the Wallet Manager knows: no browser.
        #expect(WalletBrowser.transaction(for: Self.request(from: "example-hardware")) == nil)
        #expect(!WalletBrowser.canSign(Self.request(from: "example-hardware")))
    }

    @Test func genLayerChainsAreAddableWithTheirExplorers() throws {
        let main = try #require(WalletBrowser.addableChains[42_424_242])
        #expect(main.rpc == "https://rpc.chain.genlayer.com" && main.explorer == "https://scan.chain.genlayer.com")
        #expect(main.symbol == "GEN" && main.decimals == 18)
        let test = try #require(WalletBrowser.addableChains[4221])
        #expect(test.rpc == "https://rpc.testnet-chain.genlayer.com" && test.explorer == "https://explorer.testnet-chain.genlayer.com")
        #expect(test.symbol == "GEN" && test.decimals == 18)
        #expect(WalletBrowser.addableChains.count == 2)
        let hash = "0x" + String(repeating: "ab", count: 32)
        #expect(WalletBrowser.explorerURL(chainId: 42_424_242, txHash: hash)?.absoluteString == "https://scan.chain.genlayer.com/tx/" + hash)
        #expect(WalletBrowser.explorerURL(chainId: 4221, txHash: hash)?.absoluteString == "https://explorer.testnet-chain.genlayer.com/tx/" + hash)
        #expect(WalletBrowser.explorerURL(chainId: 1, txHash: hash)?.absoluteString == "https://etherscan.io/tx/" + hash)
        #expect(WalletBrowser.explorerURL(chainId: 5, txHash: hash) == nil)
        #expect(WalletBrowser.explorerURL(chainId: 1, txHash: "0x12") == nil)
    }

    /// Only exactly `{"txHash": "0x" + 64 hex}` or `{"rejected": true}` is taken.
    @Test func whatThePagePostsBackIsCheckedStrictly() {
        let hash = "0x" + String(repeating: "Ab", count: 32)
        #expect(WalletBrowser.outcome(Data(#"{"txHash":"\#(hash)"}"#.utf8)) == .sent(txHash: hash.lowercased()))
        #expect(WalletBrowser.outcome(Data(#"{"rejected":true}"#.utf8)) == .rejected)
        for body in [#"{"rejected":false}"#, #"{"rejected":"true"}"#, #"{"txHash":"0x\#(String(repeating: "a", count: 63))"}"#,
                     #"{"txHash":"0x\#(String(repeating: "a", count: 65))"}"#, #"{"txHash":"\#(String(repeating: "a", count: 66))"}"#,
                     #"{"txHash":"0x\#(String(repeating: "g", count: 64))"}"#, #"{"txHash":"\#(hash)","rejected":true}"#,
                     #"{"txHash":"\#(hash)","note":"x"}"#, #"{"hash":"\#(hash)"}"#, #"["\#(hash)"]"#, #""\#(hash)""#, "{}", "",
                     #"{"txHash":"\#(hash)"} trailing"#, "{\"txHash\":\"" + hash + "\"" + String(repeating: " ", count: 1100) + "}"] {
            #expect(WalletBrowser.outcome(Data(body.utf8)) == nil, "\(body.prefix(80))")
        }
    }

    @Test func theMarkIsKeptBesideTheRequestAndGoesWithIt() throws {
        let folder = scratch.url("asked")
        let request = Self.request()
        try WalletAsk.file(request, in: folder)
        #expect(WalletBrowser.mark(request.id, in: folder) == nil)
        let at = Self.created.addingTimeInterval(60)
        try WalletBrowser.setMark(.init(state: .opened, at: at), for: request.id, in: folder)
        #expect(WalletBrowser.mark(request.id, in: folder) == .init(state: .opened, at: at))
        let hash = "0x" + String(repeating: "ab", count: 32)
        try WalletBrowser.setMark(.init(state: .sent, txHash: hash, at: at), for: request.id, in: folder)
        #expect(WalletBrowser.mark(request.id, in: folder) == .init(state: .sent, txHash: hash, at: at))
        // `filed` doesn't take it for a request.
        let filed = WalletAsk.filed(in: folder)
        #expect(filed.requests == [request] && filed.refused.isEmpty)
        // A mark that can't be read still says it went to the browser: how it ended isn't known.
        try Data("not json".utf8).write(to: WalletBrowser.markFile(request.id, in: folder))
        #expect(WalletBrowser.mark(request.id, in: folder)?.state == .noAnswer)
        WalletAsk.remove(request.id, in: folder)
        #expect(WalletBrowser.mark(request.id, in: folder) == nil)
    }

    /// The mark keeps the request as it was when the page was made from it; a mark from before it was kept still reads.
    @Test func theMarkKeepsTheRequestThePageWasMadeFrom() throws {
        let folder = scratch.url("asked")
        let request = Self.request()
        let at = Self.created.addingTimeInterval(60)
        try WalletBrowser.setMark(.init(state: .opened, at: at, request: request), for: request.id, in: folder)
        #expect(WalletBrowser.mark(request.id, in: folder) == .init(state: .opened, at: at, request: request))
        // As large as a request may be (its longest calldata and reason), the mark still reads whole.
        var large = Self.request(action: .call, data: "0x" + String(repeating: "ab", count: WalletRequest.maxDataBytes))
        large.reason = String(repeating: "pay ", count: 250)
        _ = try large.encoded()
        try WalletBrowser.setMark(.init(state: .opened, at: at, request: large), for: request.id, in: folder)
        #expect(WalletBrowser.mark(request.id, in: folder)?.request == large)
        try Data(#"{"state":"opened","at":"2026-10-31T12:01:00Z"}"#.utf8).write(to: WalletBrowser.markFile(request.id, in: folder))
        #expect(WalletBrowser.mark(request.id, in: folder) == .init(state: .opened, at: at))
    }

    /// The record keeps when passage said it was delivered, so the "not picked up" hint outlives a restart; a record
    /// from before it was kept still reads.
    @Test func theRecordKeepsWhenItWasSent() throws {
        let store = WalletRequestStore(folder: scratch.url("requests"))
        let request = Self.request()
        let sentAt = Self.created.addingTimeInterval(90.6)
        try store.save(.init(request: request, state: .sent, sentAt: sentAt))
        #expect(store.load().first?.sentAt == Date(timeIntervalSince1970: floor(sentAt.timeIntervalSince1970)))
        try store.save(.init(request: request, state: .sent))
        #expect(store.load().count == 1 && store.load().first?.sentAt == nil)
    }

    @Test func theAskingSessionHearsHowItEnded() {
        let request = Self.request()
        let hash = "0x" + String(repeating: "ab", count: 32)
        let sent = WalletBrowser.message(.init(state: .sent, txHash: hash, at: Self.created), request: request, summary: "1.25 GEN")
        #expect(sent.contains(request.id) && sent.contains(hash) && sent.contains("https://scan.chain.genlayer.com/tx/" + hash))
        #expect(sent.contains("browser wallet") && sent.contains("without the Wallet Manager's checks") && sent.contains("finished"))
        let rejected = WalletBrowser.message(.init(state: .rejected, at: Self.created), request: request, summary: "1.25 GEN")
        #expect(rejected.contains("rejected it in their browser wallet") && rejected.contains("Nothing was sent"))
        let none = WalletBrowser.message(.init(state: .noAnswer, at: Self.created), request: request, summary: "1.25 GEN")
        #expect(none.contains("no answer came back") && none.contains("may or may not have been sent"))
    }
}
