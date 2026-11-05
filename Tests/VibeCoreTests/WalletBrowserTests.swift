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

    static func request(reason: String, from: String = from) -> WalletRequest {
        var request = request(from: from)
        request.reason = reason
        return request
    }

    /// A reason whose first line is the marker LOCAL FORK ONLY: the browser wallet, which skips the Wallet Manager's
    /// checks, can't sign it, whatever its `from`. The first line is everything before the first line feed, or all of it.
    @Test(arguments: [
        ("the marker alone, as the whole reason", "LOCAL FORK ONLY"),
        ("the marker, a line feed and more text", "LOCAL FORK ONLY\nDeploy the example contract to the fork."),
        ("the marker and a line feed, nothing after", "LOCAL FORK ONLY\n"),
    ])
    func aRequestMarkedLocalForkOnlyCantBeSignedInTheBrowser(name: String, reason: String) {
        let marked = Self.request(reason: reason)
        #expect(WalletRequestFormat.isAddress(marked.from))
        #expect(!WalletBrowser.canSign(marked), "\(name)")
        #expect(WalletBrowser.transaction(for: marked) == nil, "\(name)")
        // A wallet id: no browser either way.
        #expect(!WalletBrowser.canSign(Self.request(reason: reason, from: "example-hardware")), "\(name)")
    }

    /// Fail closed on the first line: spaces, tabs and a carriage return at its ends are dropped and case is ignored, so
    /// a marker that is nearly right is refused the browser too.
    @Test(arguments: [
        ("spaces at both ends, in lower case", " local fork only "),
        ("in lower case", "local fork only"),
        ("in mixed case", "Local Fork Only"),
        ("a space before it", " LOCAL FORK ONLY"),
        ("spaces after it, then more lines", "LOCAL FORK ONLY   \nDeploy the example contract to the fork."),
        ("tabs at both ends", "\tLOCAL FORK ONLY\t"),
        ("a carriage return after it", "LOCAL FORK ONLY\r"),
        ("a carriage return and line feed after it, then more text", "LOCAL FORK ONLY\r\nDeploy the example contract to the fork."),
        ("a carriage return before it", "\rLOCAL FORK ONLY"),
        ("spaces, a tab and a carriage return around it, in lower case", " \tlocal fork only \r\nmore"),
    ])
    func aNearlyRightMarkerIsRefusedTheBrowserToo(name: String, reason: String) {
        let marked = Self.request(reason: reason)
        #expect(!WalletBrowser.canSign(marked), "\(name)")
        #expect(WalletBrowser.transaction(for: marked) == nil, "\(name)")
    }

    /// Not the first line, or only part of it: not marked, so it stays signable from an 0x address (and only from one).
    @Test(arguments: [
        ("the marker on line 2", "Deploy the example contract.\nLOCAL FORK ONLY"),
        ("the marker on line 2, after an empty first line", "\nLOCAL FORK ONLY"),
        ("the marker with more after it on the first line", "LOCAL FORK ONLY please"),
        ("the marker with more before it on the first line", "This is LOCAL FORK ONLY"),
        ("the marker with a full stop", "LOCAL FORK ONLY."),
        ("a reason that doesn't have it", "Pay the example invoice."),
    ])
    func aReasonWithoutTheMarkerAsItsFirstLineStaysSignable(name: String, reason: String) {
        let unmarked = Self.request(reason: reason)
        #expect(WalletBrowser.canSign(unmarked), "\(name)")
        #expect(WalletBrowser.transaction(for: unmarked) != nil, "\(name)")
        #expect(!WalletBrowser.canSign(Self.request(reason: reason, from: "example-hardware")), "\(name)")
    }

    /// One table names the six chains and links their EIP-3091 explorers, for the card, the messages and the page.
    @Test func knownChainsHaveTheirNamesAndExplorers() {
        let expected: [(Int64, String, String, String)] = [
            (1, "Ethereum", "https://etherscan.io", "ETH"),
            (11_155_111, "Sepolia", "https://sepolia.etherscan.io", "ETH"),
            (8453, "Base", "https://basescan.org", "ETH"),
            (84532, "Base Sepolia", "https://sepolia.basescan.org", "ETH"),
            (4221, "GenLayer Testnet", "https://scan.testnet-chain.genlayer.com", "GEN"),
            (42_424_242, "GenLayer", "https://scan.chain.genlayer.com", "GEN"),
        ]
        #expect(WalletChain.known.count == expected.count)
        let hash = "0x" + String(repeating: "ab", count: 32)
        for (id, name, explorer, symbol) in expected {
            #expect(WalletChain.name(id) == name)
            #expect(WalletChain.named(id)?.symbol == symbol && WalletChain.named(id)?.decimals == 18)
            #expect(WalletBrowser.explorerURL(chainId: id, txHash: hash)?.absoluteString == "\(explorer)/tx/\(hash)")
        }
        #expect(WalletChain.name(5) == "chain 5" && WalletChain.named(5) == nil)
        #expect(WalletBrowser.explorerURL(chainId: 5, txHash: hash) == nil)
        #expect(WalletBrowser.explorerURL(chainId: 8453, txHash: "0x12") == nil)
    }

    /// Base, Base Sepolia and GenLayer's two are added with their official public RPCs; Ethereum and Sepolia, which
    /// wallets ship, are only switched to.
    @Test func chainsWithAPublicRPCAreAddable() throws {
        let rpcs: [Int64: String] = [
            8453: "https://mainnet.base.org", 84532: "https://sepolia.base.org",
            42_424_242: "https://rpc.chain.genlayer.com", 4221: "https://rpc.testnet-chain.genlayer.com",
        ]
        #expect(WalletBrowser.addableChains.mapValues(\.rpc) == rpcs)
        #expect(WalletBrowser.addableChains[1] == nil && WalletBrowser.addableChains[11_155_111] == nil)
        let base = try #require(WalletBrowser.addableChains[8453])
        #expect(base.name == "Base" && base.symbol == "ETH" && base.decimals == 18 && base.explorer == "https://basescan.org")
        let baseSepolia = try #require(WalletBrowser.addableChains[84532])
        #expect(baseSepolia.name == "Base Sepolia" && baseSepolia.symbol == "ETH" && baseSepolia.explorer == "https://sepolia.basescan.org")
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
