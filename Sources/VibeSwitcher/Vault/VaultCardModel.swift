import Foundation

/// What a vault request card shows: a transaction an agent asked for, and where it is on its way to the vault Mac and
/// back. Plain values only, already worded for display (the amount in its asset's units, not base units), so the card
/// doesn't depend on the request and result types it will be built from: a caller maps those onto this.
///
/// VibeSwitcher never signs or judges the transaction: the card makes the request plain to read and shows what the
/// vault answered. Nothing leaves the Mac until you press Send to vault (`Action.send`, only while `.waiting`).
struct VaultCardModel: Equatable, Identifiable {
    /// The request's id, for the card's identity and its actions.
    var id: String
    /// The vault's workspace the `from` wallet is in (the request's `workspace`).
    var workspace: String
    var from: String
    /// What kind of wallet `from` is, when known: the request doesn't say (the vault resolves it); a Safe shows once the
    /// vault answers with a Safe transaction.
    var wallet: Wallet?
    var to: String
    var chainID: Int
    /// "ETH", "GEN" or a token's symbol.
    var asset: String
    /// The amount in the asset's units, as text ("0.25").
    var amount: String
    /// Why the agent asks, in its words.
    var reason: String
    /// A contract call's calldata size in bytes; nil for a transfer.
    var calldataBytes: Int? = nil
    /// Who asked: the session's name.
    var requestedBy: String
    var state: State
    /// The vault's checks, when it sent any (with a rejection, but also along with other answers).
    var checks: [Check] = []

    /// The kinds of wallet a request can come from: it decides what signing it means.
    enum Wallet: String, CaseIterable {
        case hardware, hot, safe

        var title: String {
            switch self {
            case .hardware: return "Hardware wallet"
            case .hot: return "Hot wallet"
            case .safe: return "Safe"
            }
        }
    }

    struct Check: Equatable, Hashable {
        var name: String
        var ok: Bool
        var detail: String = ""
    }

    enum State: Equatable {
        /// Asked for, and not sent: waits for you to send it or discard it.
        case waiting
        /// Handed to Passage, no answer yet.
        case sent
        /// Passage couldn't reach the vault Mac (and why, when it said).
        case unreachable(message: String?)
        /// Passage stopped after it may have delivered it (exit 1, a signal, out of time): the vault may have it.
        case unsure(message: String?)
        /// It didn't leave this Mac and sending again won't change that (Passage refused it as a secret, its format).
        case notSent(reason: String)
        /// The vault has it and is checking it.
        case received
        /// The vault proposed it to the Safe, where it waits for the other owners' signatures (its Safe transaction
        /// hash, when it said).
        case proposed(safeTxHash: String?)
        /// Signed on the vault, not yet submitted to the chain.
        case signedNotSubmitted
        /// Signed on the vault's hardware wallet and sent.
        case signed(txHash: String, explorerURL: URL?)
        /// The vault refused it.
        case rejected(reason: String)
        /// The vault tried and something failed.
        case failed(message: String)
        /// No answer in time, or you didn't send it in time: it can't be sent any more.
        case expired
    }

    /// What you can do on the card.
    enum Action: String, CaseIterable {
        case send, discard, retry

        var title: String {
            switch self {
            case .send: return "Send to vault"
            case .discard: return "Discard"
            case .retry: return "Retry"
            }
        }
    }

    /// The buttons the card shows in `state`, the main one first. Send only while waiting: once a request has left,
    /// nothing on this card sends it again but Retry, after Passage said it couldn't reach the vault.
    static func actions(for state: State) -> [Action] {
        switch state {
        case .waiting: return [.send, .discard]
        case .unreachable, .unsure: return [.retry, .discard]
        case .notSent: return [.discard]
        case .sent, .received, .proposed, .signedNotSubmitted, .signed, .rejected, .failed, .expired: return []
        }
    }

    var actions: [Action] { Self.actions(for: state) }

    /// A check that failed in an answer that isn't a rejection (an "unknown calldata" check on a proposal): the vault
    /// went on, and the person there decides; shown as a warning, not as a failure.
    func isWarning(_ check: Check) -> Bool {
        if check.ok { return false }
        if case .rejected = state { return false }
        return true
    }

    /// The chains the card names; others read "chain <id>".
    static func chainName(_ id: Int) -> String {
        switch id {
        case 42424242: return "GenLayer"
        case 4221: return "GenLayer testnet"
        case 1: return "Ethereum"
        default: return "chain \(id)"
        }
    }

    var chainName: String { Self.chainName(chainID) }

    /// "GenLayer (42424242)"; just "chain 5" for one without a name.
    var chainText: String {
        let name = chainName
        return name.hasPrefix("chain ") ? name : "\(name) (\(chainID))"
    }

    /// The state's one word, for the card's badge.
    static func title(_ state: State) -> String {
        switch state {
        case .waiting: return "Waiting for you"
        case .sent: return "Sent"
        case .unreachable: return "Vault not reachable"
        case .unsure: return "May have reached the vault"
        case .notSent: return "Not sent"
        case .signedNotSubmitted: return "Signed, not yet submitted"
        case .received: return "Received"
        case .proposed: return "Proposed"
        case .signed: return "Signed"
        case .rejected: return "Rejected"
        case .failed: return "Failed"
        case .expired: return "Expired"
        }
    }

    /// What the state means, in a line under the request; signing reads as `wallet` signs.
    static func detail(_ state: State, wallet: Wallet?) -> String {
        switch state {
        case .waiting: return "Nothing has left this Mac. Send it to the vault to check and sign, or discard it."
        case .sent: return "Sent through Passage. Waiting for the vault to answer."
        case .unreachable(let message):
            return "Passage couldn't reach the vault Mac" + (message.map { ": \($0)." } ?? ".") + " Nothing was sent."
        case .unsure(let message):
            return "Passage stopped before the vault confirmed it" + (message.map { ": \($0)." } ?? ".")
                + " It may have reached the vault: its answer shows here if it did. Retry sends the same request again (the vault"
                + " ignores a repeat); Discard stops waiting for it here, though the vault may still act on it."
        case .notSent(let reason): return "Not sent: \(reason). Nothing left this Mac."
        case .signedNotSubmitted: return "Signed on the vault; waiting for it to be submitted to the chain."
        case .received:
            switch wallet {
            case nil: return "The vault has it and is checking it. It's signed there, not here."
            case .hardware: return "The vault has it and is checking it. Sign it there on the hardware wallet."
            case .hot: return "The vault has it and is checking it."
            case .safe: return "The vault has it and is checking it. Sign it there to propose it to the Safe."
            }
        case .proposed:
            return wallet == .safe ? "Proposed to the Safe: waiting for the other owners' signatures."
                : "Proposed: waiting for the other signatures."
        case .signed: return wallet == .safe ? "Signed by the Safe's owners and submitted." : "Signed on the vault and submitted."
        case .rejected(let reason): return "The vault refused it: \(reason)"
        case .failed(let message): return "The vault couldn't finish it: \(message)"
        case .expired: return "No longer valid: it can't be sent. Ask the agent again if it's still needed."
        }
    }

    var detail: String { Self.detail(state, wallet: wallet) }

    /// The card as text, for Copy.
    var text: String {
        var lines = ["Vault request: \(Self.title(state))",
                     "Workspace: \(workspace)", "From: \(from)" + (wallet.map { " (\($0.title))" } ?? ""), "To: \(to)",
                     "Amount: \(amount) \(asset)", "Chain: \(chainText)",
                     "Reason: \(reason)", "Requested by: \(requestedBy)"]
        if let calldataBytes { lines.append("Contract call: \(calldataBytes) bytes of calldata") }
        lines += [
                     detail]
        switch state {
        case .signed(let hash, let url):
            lines.append("Transaction: \(hash)")
            if let url { lines.append(url.absoluteString) }
        case .proposed(let hash?): lines.append("Safe transaction: \(hash)")
        default: break
        }
        lines += checks.map { "\($0.ok ? "✓" : isWarning($0) ? "⚠" : "✗") \($0.name)\($0.detail.isEmpty ? "" : ": \($0.detail)")" }
        return lines.joined(separator: "\n")
    }
}
