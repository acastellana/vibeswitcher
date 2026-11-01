import Foundation
import VibeCore

/// wallet-request and wallet-result v1 (docs/protocol/wallet-request.md) as the card shows them: the amount in its
/// asset's units where they're known, and each status as the card's state, word for word what the Wallet Manager said.
extension WalletCardModel {
    /// The card for `request`, in `state`; `requestedBy`: the asking session's name as the window shows it; `label`: the
    /// agent's own (`requestedBy.label`), shown beside it.
    init(request: WalletRequest, requestedBy: String, label: String = "", state: State, checks: [Check] = [], wallet: Wallet? = nil) {
        let (amount, asset) = Self.amount(request)
        self.init(id: request.id, workspace: request.workspace, from: request.from, wallet: wallet, to: request.to,
                  chainID: Int(clamping: request.chainId), asset: asset, amount: amount, reason: request.reason,
                  calldataBytes: request.data.map { ($0.utf8.count - 2) / 2 },
                  call: request.data.map { WalletCall.decode($0, contract: request.to) },
                  requestedBy: requestedBy, requestedByLabel: label, state: state, checks: checks,
                  browserSignable: WalletBrowser.canSign(request))
    }

    /// The card state a browser wallet mark stands for.
    static func state(_ mark: WalletBrowser.Mark, chainId: Int64) -> State {
        switch mark.state {
        case .opened: return .inBrowser
        case .sent:
            let hash = mark.txHash ?? ""
            return .sentFromBrowser(txHash: hash, explorerURL: WalletBrowser.explorerURL(chainId: chainId, txHash: hash))
        case .rejected: return .rejectedInWallet
        case .noAnswer: return .browserNoAnswer
        }
    }

    /// The request in a few words for a message: "1.25 GEN to 0x… on GenLayer".
    static func summary(_ request: WalletRequest) -> String {
        let (amount, asset) = amount(request)
        return "\(amount) \(asset) to \(request.to) on \(chainName(Int(clamping: request.chainId)))"
    }

    /// The native coin's symbol on the chains the card names, else nil.
    static func nativeSymbol(_ chainID: Int64) -> String? { WalletChain.named(chainID)?.symbol }

    /// The amount as the card shows it: the native coin in whole units (18 decimals: "0.25 GEN"); a token's in its base
    /// units, naming the token, since its decimals aren't known here.
    static func amount(_ request: WalletRequest) -> (amount: String, asset: String) {
        guard request.asset == "native" else {
            let token = request.asset
            let short = token.count > 14 ? "\(token.prefix(8))…\(token.suffix(4))" : token
            return (request.amount, "base units of token \(short)")
        }
        return (units(request.amount, decimals: WalletChain.named(request.chainId)?.decimals ?? 18),
                nativeSymbol(request.chainId) ?? "(the chain's native coin)")
    }

    /// Base units as whole units: "1000000000000000000" at 18 decimals is "1", "250000000000000000" is "0.25".
    static func units(_ digits: String, decimals: Int) -> String {
        let padded = String(repeating: "0", count: max(0, decimals + 1 - digits.count)) + digits
        let whole = String(padded.dropLast(decimals))
        var fraction = String(padded.suffix(decimals))
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return fraction.isEmpty ? whole : "\(whole).\(fraction)"
    }

    /// What the Wallet Manager's result says, as the card's state.
    static func state(_ result: WalletResult) -> State {
        switch result.status {
        case .received: return .received
        case .proposed: return .proposed(safeTxHash: result.safeTxHash)
        case .signed: return .signedNotSubmitted
        case .submitted: return .signed(txHash: result.txHash ?? "", explorerURL: result.explorerURL.flatMap(URL.init(string:)))
        case .rejected:
            let failing = result.checks.filter { !$0.ok }.map(\.name)
            return .rejected(reason: !result.message.isEmpty ? result.message
                             : failing.isEmpty ? "it gave no reason" : "failed " + failing.joined(separator: ", "))
        case .failed:
            let message = result.message.isEmpty ? "it gave no reason" : result.message
            return .failed(message: message + (result.txHash.map { " (transaction \($0))" } ?? ""))
        }
    }

    /// A sent request's card state from its record: the Wallet Manager's last result; else sent, or unsure (`unsure`: why, as
    /// Passage said); expired once no answer can come any more.
    static func state(of record: WalletRequestStore.Record, unsure: String?, now: Date) -> (state: State, checks: [Check], wallet: Wallet?) {
        let checks = (record.results.last(where: { !$0.checks.isEmpty })?.checks ?? []).map { Check(name: $0.name, ok: $0.ok, detail: $0.detail) }
        let wallet: Wallet? = record.results.contains { $0.safeTxHash != nil } ? .safe : nil
        if let last = record.results.last {
            if !last.status.isFinal, now >= record.request.expiresAt.addingTimeInterval(WalletCourier.resultGrace) { return (.expired, checks, wallet) }
            return (state(last), checks, wallet)
        }
        if now >= record.request.expiresAt.addingTimeInterval(WalletCourier.resultGrace) { return (.expired, checks, wallet) }
        return (record.state == .unsure ? .unsure(message: unsure) : .sent, checks, wallet)
    }

    /// The message the asking session gets for a result: what the Wallet Manager said, plainly, marked as the Wallet Manager's.
    static func message(for result: WalletResult, request: WalletRequest) -> String {
        let (amount, asset) = amount(request)
        var text = "Wallet request \(request.id) (\(amount) \(asset) to \(request.to) on \(chainName(Int(clamping: request.chainId)))): "
            + "the Wallet Manager says \(result.status.rawValue)" + (result.message.isEmpty ? "." : ": \(result.message)")
        if let hash = result.txHash { text += " Transaction: \(hash)." }
        if let hash = result.safeTxHash { text += " Safe transaction: \(hash)." }
        if let url = result.explorerURL { text += " \(url)" }
        let failing = result.checks.filter { !$0.ok }
        if !failing.isEmpty { text += (result.status == .rejected ? " Failed checks: " : " Warnings (the Wallet Manager went on; the person there decides): ") + failing.map { "\($0.name)" + ($0.detail.isEmpty ? "" : " (\($0.detail))") }.joined(separator: "; ") + "." }
        text += result.status.isFinal ? " This request is finished." : " More answers may follow."
        return text
    }
}
