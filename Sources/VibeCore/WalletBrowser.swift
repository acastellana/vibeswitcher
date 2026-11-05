import Foundation

/// The fallback for a wallet request that never reached the Wallet Manager: at the user's click, a minimal local page
/// (`WalletSignServer` in the app) has the browser's own wallet extension (Rabby, MetaMask) show and sign it. Skips the
/// Wallet Manager's checks: the extension's popup is what the user reads. Here: the transaction the page asks the
/// extension to send, the chains it may add, the strict check of what the page posts back, and the mark that records,
/// beside the filed request, that it went this way (so it can't also go to the Wallet Manager). Nothing here signs or
/// sees a key.
public enum WalletBrowser {
    /// How long the page is served for one request, at most.
    public static let pageLifetime: TimeInterval = 15 * 60

    /// The chains the page may add to the wallet (`wallet_addEthereumChain`) when it doesn't know them yet: the known
    /// ones with a public RPC (Base, Base Sepolia, GenLayer's two). Ethereum and Sepolia, which wallets ship, and any
    /// other chain are only switched to.
    public static let addableChains: [Int64: WalletChain] = WalletChain.known.filter { $0.value.rpc != nil }

    /// Where a transaction on `chainId` can be seen (`WalletChain.known`'s explorers); nil for other chains.
    public static func explorerURL(chainId: Int64, txHash: String) -> URL? {
        guard isHash(txHash) else { return nil }
        return WalletChain.named(chainId).flatMap { URL(string: "\($0.explorer)/tx/\(txHash)") }
    }

    /// `eth_sendTransaction`'s parameters: hex quantities and data as the wallet takes them.
    public struct Transaction: Equatable, Sendable {
        public var from: String
        public var to: String
        /// 0x and hex digits, no leading zero ("0x0" for none).
        public var value: String
        /// 0x calldata, or nil for a plain transfer of the chain's coin.
        public var data: String?
    }

    /// The marker a request's `reason` carries as its first line when it is meant for a local fork only
    /// (docs/protocol/wallet-request.md, History, 2026-11-05). The Wallet Manager refuses such a request unless it runs
    /// against a local fork; the browser wallet, which skips the Wallet Manager's checks, is never offered for one.
    public static let localForkMarker = "LOCAL FORK ONLY"

    /// Whether `request` is marked for a local fork only, or nearly: its reason's first line (everything before the
    /// first line feed, or all of it) is the marker once spaces, tabs and carriage returns (any white space) at both
    /// ends are dropped and case is ignored. Wider than the exact marker on purpose: a near-miss is refused the browser
    /// too (the Wallet Manager refuses it outright).
    public static func isLocalForkOnly(_ request: WalletRequest) -> Bool {
        // By scalars: a carriage return and line feed are one Character, which no "\n" would match.
        let scalars = request.reason.unicodeScalars
        let first = String(String.UnicodeScalarView(scalars.prefix { $0 != "\n" }))
        return first.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == localForkMarker.lowercased()
    }

    /// Why the browser wallet can't sign `request`, in a few words; nil when it can (`canSign`).
    public static func whyNot(_ request: WalletRequest) -> String? {
        if isLocalForkOnly(request) { return "it's marked \(localForkMarker)" }
        if !WalletRequestFormat.isAddress(request.from) { return "its from isn't an 0x address" }
        return nil
    }

    /// Whether `request` can go this way at all: `from` is an 0x address (a wallet id names a wallet only the Wallet
    /// Manager knows), and the request isn't marked for a local fork only (`isLocalForkOnly`). The one rule behind the
    /// card's button, the signing page and vs-wallet's output.
    public static func canSign(_ request: WalletRequest) -> Bool { whyNot(request) == nil }

    /// The transaction `request` asks for: the coin to `to`; a token's `transfer(to, amount)` on the token contract;
    /// or the call's data to `to` with its value. Nil when the browser wallet can't sign it (`canSign`).
    public static func transaction(for request: WalletRequest) -> Transaction? {
        guard canSign(request), let amount = hexQuantity(request.amount) else { return nil }
        switch request.action {
        case .call:
            return Transaction(from: request.from, to: request.to, value: amount, data: request.data)
        case .transfer where request.asset == "native":
            return Transaction(from: request.from, to: request.to, value: amount, data: nil)
        case .transfer:
            let digits = String(amount.dropFirst(2))
            guard digits.count <= 64 else { return nil }
            let word = { (hex: String) in String(repeating: "0", count: 64 - hex.count) + hex }
            let data = "0xa9059cbb" + word(String(request.to.dropFirst(2)).lowercased()) + word(digits)
            return Transaction(from: request.from, to: request.asset, value: "0x0", data: data)
        }
    }

    /// Decimal digits (no sign, 1–78 of them) as a hex quantity: "0x" and lower-case digits, no leading zero.
    public static func hexQuantity(_ decimal: String) -> String? {
        var digits = Array(decimal.utf8).map { Int($0) - 0x30 }
        guard (1...78).contains(digits.count), digits.allSatisfy({ (0...9).contains($0) }) else { return nil }
        let symbols = Array("0123456789abcdef")
        var hex = ""
        while digits.contains(where: { $0 != 0 }) {
            var remainder = 0
            var quotient: [Int] = []
            for digit in digits {
                let value = remainder * 10 + digit
                quotient.append(value / 16)
                remainder = value % 16
            }
            hex.insert(symbols[remainder], at: hex.startIndex)
            digits = quotient
        }
        return "0x" + (hex.isEmpty ? "0" : hex)
    }

    // MARK: What the page posts back

    /// What the wallet did: sent the transaction (its hash), or the user rejected it there.
    public enum Outcome: Equatable, Sendable {
        case sent(txHash: String)
        case rejected
    }

    /// The page's answer, checked strictly: a JSON object of exactly `{"txHash": "0x" + 64 hex}` or `{"rejected": true}`,
    /// 1 KiB at most. Anything else is nil.
    public static func outcome(_ body: Data) -> Outcome? {
        guard body.count <= 1024, case let .object(members)? = try? WalletRequestFormat.Value.parse(body), members.count == 1 else { return nil }
        switch (members[0].key, members[0].value) {
        case ("txHash", .string(let hash)) where isHash(hash): return .sent(txHash: hash.lowercased())
        case ("rejected", .bool(true)): return .rejected
        default: return nil
        }
    }

    /// 0x and 64 hex digits.
    public static func isHash(_ text: String) -> Bool { WalletRequestFormat.isHash(text) }

    // MARK: The mark

    /// That a request went to the browser wallet, and how it ended: `.<id>.browser` beside the filed request (`filed` reads
    /// no dot-file), written before the browser opens. While it's there the request can't go to the Wallet Manager.
    public struct Mark: Equatable, Sendable {
        public enum State: String, Equatable, Sendable {
            /// The page was opened; no answer yet.
            case opened
            /// The wallet sent it: `txHash`.
            case sent
            /// The user rejected it in the wallet.
            case rejected
            /// No answer came back before the page stopped (its 15 minutes, or the app quit).
            case noAnswer
        }

        public var state: State
        public var txHash: String?
        public var at: Date
        /// The request as it was when the user clicked Sign in browser wallet: the page was made from it, so the card and
        /// the messages after it come from it, whatever the filed request says later. Nil in a mark from before it was kept.
        public var request: WalletRequest?

        public init(state: State, txHash: String? = nil, at: Date, request: WalletRequest? = nil) {
            self.state = state
            self.txHash = txHash
            self.at = Date(timeIntervalSince1970: floor(at.timeIntervalSince1970))
            self.request = request
        }
    }

    static func markFile(_ id: String, in folder: URL) -> URL { folder.appendingPathComponent(".\(id).browser") }

    /// The mark for request `id`, or nil when there is none. A mark file that can't be read as one reads as `noAnswer`:
    /// it went to the browser, how it ended isn't known.
    public static func mark(_ id: String, in folder: URL = WalletAsk.folder) -> Mark? {
        let file = markFile(id, in: folder)
        guard (try? FileManager.default.attributesOfItem(atPath: file.path)) != nil else { return nil }
        guard let data = try? WalletAsk.read(file), let mark = try? parseMark(data) else { return Mark(state: .noAnswer, at: Date(timeIntervalSince1970: 0)) }
        return mark
    }

    /// Writes `mark` (0600). Throws when it couldn't be written: the browser isn't opened then.
    public static func setMark(_ mark: Mark, for id: String, in folder: URL = WalletAsk.folder) throws {
        var members: [WalletRequestFormat.Value.Member] = [.init("state", .string(mark.state.rawValue))]
        if let hash = mark.txHash { members.append(.init("txHash", .string(hash))) }
        members.append(.init("at", .string(WalletRequestFormat.string(mark.at))))
        if let request = mark.request { members.append(.init("request", request.value)) }
        try VibePaths.ensurePrivate(folder)
        try VibePaths.writePrivate(WalletRequestFormat.Value.object(members).encoded(), to: markFile(id, in: folder))
    }

    static func parseMark(_ data: Data) throws -> Mark {
        let fields = try WalletRequestFormat.Fields(WalletRequestFormat.Value.parse(data), path: "", allowed: ["state", "txHash", "at", "request"])
        guard let state = Mark.State(rawValue: try fields.string("state")) else { throw WalletRequestFormat.Failure.invalid("state", "unknown") }
        let hash = try fields.optionalString("txHash")
        guard (state == .sent) == (hash != nil), hash.map(isHash) ?? true else { throw WalletRequestFormat.Failure.invalid("txHash", "only, and always, with sent") }
        let request = fields.has("request") ? try WalletRequest.read(fields.value("request"), path: "request") : nil
        return Mark(state: state, txHash: hash, at: try WalletRequestFormat.date(fields.string("at"), field: "at"), request: request)
    }

    // MARK: Messages to the asking session

    /// What the asking session hears when the browser wallet's answer came back, or none did.
    public static func message(_ mark: Mark, request: WalletRequest, summary: String) -> String {
        let head = "Wallet request \(request.id) (\(summary)): "
        switch mark.state {
        case .sent:
            let hash = mark.txHash ?? ""
            return head + "the user sent it from their browser wallet, signed there without the Wallet Manager's checks. Transaction: \(hash)."
                + (explorerURL(chainId: request.chainId, txHash: hash).map { " \($0.absoluteString)" } ?? "") + " This request is finished."
        case .rejected:
            return head + "the user rejected it in their browser wallet. Nothing was sent. This request is finished."
        case .noAnswer:
            return head + "it was opened in the user's browser wallet, but no answer came back. It may or may not have been sent from there: "
                + "ask the user before filing it again. It can't go to the Wallet Manager any more."
        case .opened:
            return head + "the user opened it in their browser wallet."
        }
    }
}
