import Foundation
import VibeCore

/// What a wallet request card shows: a transaction an agent asked for, and where it is on its way to the Wallet Manager's Mac and
/// back. Plain values only, already worded for display (the amount in its asset's units, not base units), so the card
/// doesn't depend on the request and result types it will be built from: a caller maps those onto this.
///
/// VibeSwitcher never signs or judges the transaction: the card makes the request plain to read and shows what the
/// Wallet Manager answered. Nothing leaves the Mac until you press Send to Wallet Manager (`Action.send`, only while `.waiting`).
struct WalletCardModel: Equatable, Identifiable {
    /// The request's id, for the card's identity and its actions.
    var id: String
    /// The Wallet Manager's workspace the `from` wallet is in (the request's `workspace`).
    var workspace: String
    var from: String
    /// What kind of wallet `from` is, when known: the request doesn't say (the Wallet Manager resolves it); a Safe shows once the
    /// Wallet Manager answers with a Safe transaction.
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
    /// A contract call's calldata in words (`WalletCall`); nil for a transfer.
    var call: WalletCall? = nil
    /// Who asked: the session's name as VibeSwitcher knows it (the window's), never as the request says.
    var requestedBy: String
    /// The label the agent gave (`--label`): shown beside the name as the agent's own words; empty when it gave none.
    var requestedByLabel: String = ""
    var state: State
    /// The Wallet Manager's checks, when it sent any (with a rejection, but also along with other answers).
    var checks: [Check] = []
    /// The browser's wallet could sign it (`WalletBrowser.canSign`): `from` is an 0x address, and it isn't marked for a
    /// local fork only.
    var browserSignable = false
    /// The reason's first line marks it for a local fork only (`WalletBrowser.isLocalForkOnly`): never the browser
    /// wallet, whatever its `from`. Only the detail's wording reads this; `browserSignable` is already false for one.
    var localForkOnly = false
    /// Sent, with no word from the Wallet Manager for 5 minutes: the card asks whether it's running.
    var notPickedUp = false
    /// The Wallet Manager isn't set up in Settings › Wallet (no peer chosen, no Passage found): the line that says so,
    /// shown with Open Settings where Send or Retry would be. Nil when it is.
    var setupNeeded: String? = nil
    /// The filed request was rewritten (or is gone) since it was opened in the browser wallet: the card shows what the
    /// page was made from, and says so (`fileChangedNote`).
    var fileChanged = false
    /// A message about this request (its outcome) couldn't reach the asking agent: its session ended. Said on the card
    /// (`agentMissedNote`) until the request's results window is over.
    var agentMissed = false

    /// `setupNeeded`'s line for each way the Wallet Manager isn't set up.
    static let noPeerNote = "No Wallet Manager chosen: choose its Mac in Settings › Wallet"
    static let noPassageNote = "Passage isn't found: set its path in Settings › Wallet"
    static let passageNotAbsoluteNote = "The passage path in Settings › Wallet isn't absolute: set it there"
    static let passageNotRunnableNote = "Nothing at the passage path in Settings › Wallet can run: set it there"

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
        /// Passage couldn't reach the Wallet Manager's Mac (and why, when it said).
        case unreachable(message: String?)
        /// Passage stopped after it may have delivered it (exit 1, a signal, out of time): the Wallet Manager may have it.
        case unsure(message: String?)
        /// It didn't leave this Mac and sending again won't change that (Passage refused it as a secret, its format).
        case notSent(reason: String)
        /// The Wallet Manager has it and is checking it.
        case received
        /// The Wallet Manager built it and shows it for signing: to a Safe, it waits for the other owners' signatures (its
        /// Safe transaction hash, when it said); any other wallet waits for the person at the Wallet Manager's Mac.
        case proposed(safeTxHash: String?)
        /// Signed on the Wallet Manager's Mac, not yet submitted to the chain.
        case signedNotSubmitted
        /// Signed on the Wallet Manager's hardware wallet and sent.
        case signed(txHash: String, explorerURL: URL?)
        /// The Wallet Manager refused it.
        case rejected(reason: String)
        /// The Wallet Manager tried and something failed.
        case failed(message: String)
        /// No answer in time, or you didn't send it in time: it can't be sent any more.
        case expired
        /// Opened in the browser's wallet (`WalletBrowser`): waiting for it to be confirmed or rejected there.
        case inBrowser
        /// Signed and sent by the browser's wallet.
        case sentFromBrowser(txHash: String, explorerURL: URL?)
        /// Rejected in the browser's wallet.
        case rejectedInWallet
        /// Opened in the browser's wallet, and no answer came back before the page stopped.
        case browserNoAnswer

        /// Nothing more will happen to it: it didn't go, or the Wallet Manager or the browser wallet had the last word.
        var isFinished: Bool {
            switch self {
            case .notSent, .signed, .rejected, .failed, .expired, .sentFromBrowser, .rejectedInWallet, .browserNoAnswer: return true
            case .waiting, .sent, .unreachable, .unsure, .received, .proposed, .signedNotSubmitted, .inBrowser: return false
            }
        }
    }

    /// What you can do on the card.
    enum Action: String, CaseIterable {
        case send, discard, retry
        /// Sign it with the browser's wallet extension instead (`WalletBrowser`): skips the Wallet Manager.
        case browser
        /// Opens Settings › Wallet, where Send or Retry would be while the Wallet Manager isn't set up (`setupNeeded`).
        case settings

        var title: String {
            switch self {
            case .send: return "Send to Wallet Manager"
            case .discard: return "Discard"
            case .retry: return "Retry"
            case .browser: return "Sign in browser wallet"
            case .settings: return "Open Settings"
            }
        }
    }

    /// The line under Sign in browser wallet.
    static let browserNote = "Skips the Wallet Manager's checks: read the wallet's own popup"
    /// A waiting card's line for a request marked for a local fork only, while the Wallet Manager isn't set up.
    static let localForkOnlyDetail = "Nothing has left this Mac. It needs the Wallet Manager: it's marked local fork only, "
        + "so the browser wallet isn't offered for it."
    /// Added to a Sent card's line after `notPickedUpAfter` with no word from the Wallet Manager.
    static let notPickedUpNote = "Delivered to the Wallet Manager's Mac, but it hasn't picked it up yet. Is the Wallet Manager running?"
    static let notPickedUpAfter: TimeInterval = 5 * 60
    /// The warning on a card whose filed request changed after it was opened in the browser wallet (`fileChanged`).
    /// The line on a card whose outcome the asking agent never got (`agentMissed`).
    static let agentMissedNote = "The agent didn't get this: its session ended."
    static let fileChangedNote = "The filed request was changed after you opened it in the browser wallet. This card shows what the browser wallet was given; the new version isn't shown or sent."

    /// The buttons the card shows in `state`, the main one first. Send only while waiting: once a request has left,
    /// nothing on this card sends it again but Retry, after Passage said it couldn't reach the Wallet Manager.
    static func actions(for state: State) -> [Action] {
        switch state {
        case .waiting: return [.send, .discard]
        case .unreachable, .unsure: return [.retry, .discard]
        case .notSent: return [.discard]
        case .inBrowser, .rejectedInWallet, .browserNoAnswer: return [.discard]
        case .sent, .received, .proposed, .signedNotSubmitted, .signed, .rejected, .failed, .expired, .sentFromBrowser: return []
        }
    }

    /// Whether Sign in browser wallet shows: only while the request has never reached the Wallet Manager (waiting,
    /// unreachable, not sent), from an 0x address that isn't known to be a Safe, and never for one marked for a local
    /// fork only. Once it's used the card is `inBrowser` or after, where neither it nor Send shows again.
    var offersBrowser: Bool {
        guard browserSignable, !localForkOnly, wallet != .safe else { return false }
        switch state {
        case .waiting, .unreachable, .notSent: return true
        default: return false
        }
    }

    /// The buttons: the state's, with Sign in browser wallet before Discard where `offersBrowser`. While the Wallet
    /// Manager isn't set up (`setupNeeded`), Send and Retry give way to Open Settings: the request can't go there yet.
    var actions: [Action] {
        var list = Self.actions(for: state)
        if setupNeeded != nil, list.contains(where: { $0 == .send || $0 == .retry }) {
            list.removeAll { $0 == .send || $0 == .retry }
            list.append(.settings)
        }
        if offersBrowser { list.insert(.browser, at: list.firstIndex(of: .discard) ?? list.endIndex) }
        return list
    }

    /// A check that failed in an answer that isn't a rejection (an "unknown calldata" check on a proposal): the Wallet Manager
    /// went on, and the person there decides; shown as a warning, not as a failure.
    func isWarning(_ check: Check) -> Bool {
        if check.ok { return false }
        if case .rejected = state { return false }
        return true
    }

    /// The chains the card names (`WalletChain.known`); others read "chain <id>".
    static func chainName(_ id: Int) -> String { WalletChain.name(Int64(id)) }

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
        case .unreachable: return "Wallet Manager not reachable"
        case .unsure: return "May have reached the Wallet Manager"
        case .notSent: return "Not sent"
        case .signedNotSubmitted: return "Signed, not yet submitted"
        case .received: return "Received"
        case .proposed: return "Proposed"
        case .signed: return "Signed"
        case .rejected: return "Rejected"
        case .failed: return "Failed"
        case .expired: return "Expired"
        case .inBrowser: return "Waiting for the browser wallet"
        case .sentFromBrowser: return "Sent from browser wallet"
        case .rejectedInWallet: return "Rejected in the wallet"
        case .browserNoAnswer: return "No answer from the browser wallet"
        }
    }

    /// What the state means, in a line under the request; signing reads as `wallet` signs.
    static func detail(_ state: State, wallet: Wallet?) -> String {
        switch state {
        case .waiting: return "Nothing has left this Mac. Send it to the Wallet Manager to check and sign, or discard it."
        case .sent: return "Sent through Passage. Waiting for the Wallet Manager to answer."
        case .unreachable(let message):
            return "Passage couldn't reach the Wallet Manager's Mac" + (message.map { ": \($0)." } ?? ".") + " Nothing was sent."
        case .unsure(let message):
            return "Passage stopped before the Wallet Manager confirmed it" + (message.map { ": \($0)." } ?? ".")
                + " It may have reached the Wallet Manager: its answer shows here if it did. Retry sends the same request again (the Wallet Manager"
                + " ignores a repeat); Discard stops waiting for it here, though the Wallet Manager may still act on it."
        case .notSent(let reason): return "Not sent: \(reason). Nothing left this Mac."
        case .signedNotSubmitted: return "Signed on the Wallet Manager's Mac; waiting for it to be submitted to the chain."
        case .received:
            switch wallet {
            case nil: return "The Wallet Manager has it and is checking it. It's signed there, not here."
            case .hardware: return "The Wallet Manager has it and is checking it. Sign it there on the hardware wallet."
            case .hot: return "The Wallet Manager has it and is checking it."
            case .safe: return "The Wallet Manager has it and is checking it. Sign it there to propose it to the Safe."
            }
        case .proposed:
            // Only a Safe has other owners; any other wallet (or one not known to be a Safe) waits for the person there.
            return wallet == .safe ? "Proposed to the Safe: waiting for the other owners' signatures."
                : "Proposed: waiting for the person at the Wallet Manager's Mac to sign it."
        case .signed: return wallet == .safe ? "Signed by the Safe's owners and submitted." : "Signed on the Wallet Manager's Mac and submitted."
        case .rejected(let reason): return "The Wallet Manager refused it: \(reason)"
        case .failed(let message): return "The Wallet Manager couldn't finish it: \(message)"
        case .expired: return "No longer valid: it can't be sent. Ask the agent again if it's still needed."
        case .inBrowser:
            return "Opened in your browser: confirm or reject it in the wallet's own popup, and read the transaction there. "
                + "It no longer goes to the Wallet Manager."
        case .sentFromBrowser: return "Signed and sent from your browser wallet, without the Wallet Manager's checks."
        case .rejectedInWallet: return "You rejected it in the browser wallet. Nothing was sent."
        case .browserNoAnswer:
            return "Opened in the browser wallet, but no answer came back. Check the wallet's activity to see whether it was sent."
        }
    }

    var detail: String {
        // Waiting with no Wallet Manager set up: the browser wallet is the way, or, for a request marked for a local fork
        // only or a wallet id, there is none yet.
        if state == .waiting, setupNeeded != nil {
            if offersBrowser { return "Nothing has left this Mac. Sign it in your browser wallet, or discard it." }
            return localForkOnly ? Self.localForkOnlyDetail
                : "Nothing has left this Mac. It needs the Wallet Manager: a browser wallet can't use a wallet id."
        }
        let line = Self.detail(state, wallet: wallet)
        return state == .sent && notPickedUp ? line + " " + Self.notPickedUpNote : line
    }

    /// "Requested by"'s line: the session's name, and the agent's own label beside it when it gave one.
    var requestedByText: String {
        requestedByLabel.isEmpty || requestedByLabel == requestedBy ? requestedBy : "\(requestedBy) (the agent's label: \(requestedByLabel))"
    }

    /// The label over the reason: whose words they are.
    static let reasonTitle = "Reason, in the agent's words"

    /// The card as text, for Copy.
    var text: String {
        var lines = ["Wallet request: \(Self.title(state))", "Workspace: \(workspace)", "From: \(from)" + (wallet.map { " (\($0.title))" } ?? "")]
        if let call {
            lines.append("Contract: \(to)")
            lines.append("Call: \(call.headline)" + (call.function.map { " (\($0))" } ?? ""))
            lines += call.fields.map { "  \($0.name): \($0.value)" }
            lines.append("Value sent: \(amount) \(asset)")
            if let calldataBytes { lines.append("Calldata: \(calldataBytes) bytes") }
        } else {
            lines += ["To: \(to)", "Amount: \(amount) \(asset)"]
        }
        lines += ["Chain: \(chainText)", "Requested by: \(requestedByText)", "\(Self.reasonTitle): “\(reason)”", detail]
        if fileChanged { lines.append("⚠ " + Self.fileChangedNote) }
        if agentMissed { lines.append("⚠ " + Self.agentMissedNote) }
        if let setupNeeded, actions.contains(.settings) { lines.append(setupNeeded) }
        switch state {
        case .signed(let hash, let url), .sentFromBrowser(let hash, let url):
            lines.append("Transaction: \(hash)")
            if let url { lines.append(url.absoluteString) }
        case .proposed(let hash?): lines.append("Safe transaction: \(hash)")
        default: break
        }
        lines += checks.map { "\($0.ok ? "✓" : isWarning($0) ? "⚠" : "✗") \($0.name)\($0.detail.isEmpty ? "" : ": \($0.detail)")" }
        return lines.joined(separator: "\n")
    }
}
