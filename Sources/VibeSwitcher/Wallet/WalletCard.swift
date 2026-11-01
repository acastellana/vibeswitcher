import SwiftUI
import VibeCore

/// A transaction an agent asked for (`WalletCardModel`): who asked, from where to where, how much, on which chain and
/// why, then what the Wallet Manager answered. Calm by design: one tinted border in the state's color, the request as a short
/// table, and buttons only where you can act (`WalletCardModel.actions(for:)`).
struct WalletCard: View {
    let card: WalletCardModel
    /// A button pressed: the caller sends, discards or retries; the card only shows the state it's given.
    var act: (WalletCardModel.Action) -> Void = { _ in }
    @IncreasedContrast private var increased

    static func tint(_ state: WalletCardModel.State) -> Color {
        switch state {
        case .waiting, .unreachable, .unsure, .browserNoAnswer: return SessionStatus.needsInput.color
        case .sent, .received, .proposed, .signedNotSubmitted, .inBrowser: return SessionStatus.working.color
        case .signed, .sentFromBrowser: return SessionStatus.done.color
        case .rejected, .failed, .notSent, .rejectedInWallet: return Color(nsColor: .systemRed)
        case .expired: return .secondary
        }
    }

    static func symbol(_ state: WalletCardModel.State) -> String {
        switch state {
        case .waiting: return "hand.raised.fill"
        case .sent: return "paperplane.fill"
        case .unreachable: return "wifi.exclamationmark"
        case .unsure: return "questionmark.circle.fill"
        case .notSent: return "xmark.circle.fill"
        case .signedNotSubmitted: return "signature"
        case .received: return "tray.and.arrow.down.fill"
        case .proposed: return "person.2.fill"
        case .signed: return "checkmark.seal.fill"
        case .rejected: return "xmark.octagon.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .expired: return "clock.badge.xmark"
        case .inBrowser: return "safari"
        case .sentFromBrowser: return "checkmark.circle.fill"
        case .rejectedInWallet: return "xmark.octagon.fill"
        case .browserNoAnswer: return "questionmark.circle.fill"
        }
    }

    var body: some View {
        let tint = Self.tint(card.state)
        VStack(alignment: .leading, spacing: 10) {
            header(tint)
            request
            if card.fileChanged { fileChanged }
            Text(card.detail)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            outcome
            if card.agentMissed { agentMissed }
            if !card.checks.isEmpty { checks }
            if !card.actions.isEmpty { buttons }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(increased ? 0 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(increased ? 1 : 0.4), lineWidth: 1.5))
        .contextMenu { Button("Copy Request") { Pasteboard.copy(card.text) } }
    }

    private func header(_ tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lock.shield").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Transaction request").font(.system(size: 13.5, weight: .bold))
            Spacer(minLength: 8)
            Label(WalletCardModel.title(card.state), systemImage: Self.symbol(card.state))
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(tint)
                .accessibilityLabel("State: \(WalletCardModel.title(card.state))")
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// The request, a row per fact: the amount first and largest, as it's what a glance is for; for a contract call, what
    /// the call does (decoded, or plainly unknown) comes first instead, and the native value it sends after. Then who
    /// asked, and the reason set apart as the agent's words.
    private var request: some View {
        VStack(alignment: .leading, spacing: 9) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                if let call = card.call {
                    callRows(call)
                } else {
                    GridRow {
                        label("Amount")
                        Text("\(card.amount) \(card.asset)").font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    }
                }
                row("Chain", card.chainText)
                GridRow {
                    label("From")
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(card.from).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            .help(card.from)
                        if let wallet = card.wallet {
                            Text(wallet.title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 1.5)
                                .background(Capsule().strokeBorder(.secondary.opacity(0.5), lineWidth: 1))
                                .fixedSize()
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                row(card.call == nil ? "To" : "Contract", card.to, mono: true)
                if card.call != nil {
                    row("Value sent", "\(card.amount) \(card.asset)")
                    if let bytes = card.calldataBytes { row("Calldata", "\(bytes) bytes") }
                }
                row("Workspace", card.workspace)
                requestedBy
            }
            reason
        }
        .textSelection(.enabled)
    }

    /// A contract call in words: what it does, large (red when it's unknown or grants everything), then who it lets
    /// spend or receive what, a row each, an unlimited amount in red.
    @ViewBuilder private func callRows(_ call: WalletCall) -> some View {
        let red = Color(nsColor: .systemRed)
        GridRow {
            label("Call")
            VStack(alignment: .leading, spacing: 1) {
                Label {
                    Text(call.headline)
                } icon: {
                    if call.alarming { Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true) }
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(call.alarming ? red : .primary)
                if let function = call.function {
                    Text(function).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Call: \(call.alarming ? "warning, " : "")\(call.headline)\(call.function.map { ", \($0)" } ?? "")")
        ForEach(Array(call.fields.enumerated()), id: \.offset) { _, field in
            let mono = WalletRequestFormat.isAddress(field.value)
            GridRow {
                label(field.name)
                Text(field.value)
                    .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12.5, weight: field.alarming ? .semibold : .regular))
                    .foregroundStyle(field.alarming ? red : .primary)
                    .lineLimit(mono ? 1 : nil).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(mono ? field.value : "")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(field.name): \(field.alarming ? "warning, " : "")\(field.value)")
        }
    }

    /// The session as the window names it; the agent's own label, when it gave another, beside it in its words.
    private var requestedBy: some View {
        GridRow {
            label("Requested by")
            VStack(alignment: .leading, spacing: 1) {
                Text(card.requestedBy).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                if !card.requestedByLabel.isEmpty, card.requestedByLabel != card.requestedBy {
                    Text("its label: “\(card.requestedByLabel)”").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Requested by \(card.requestedByText)")
    }

    /// The reason, quoted and set apart under the rows, so nothing in it reads as one of them.
    private var reason: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(WalletCardModel.reasonTitle).font(.system(size: 11.5)).foregroundStyle(.secondary)
            Text("“\(card.reason)”")
                .font(.system(size: 12.5).italic())
                .lineLimit(WalletRequestFormat.maxReasonLines)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(.secondary.opacity(increased ? 1 : 0.45)).frame(width: 3)
                }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(WalletCardModel.reasonTitle): \(card.reason)")
    }

    /// The filed request changed after it went to the browser wallet: the card shows what the page was made from.
    private var fileChanged: some View {
        Label(WalletCardModel.fileChangedNote, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12, weight: .medium)).foregroundStyle(SessionStatus.needsInput.color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Warning: \(WalletCardModel.fileChangedNote)")
    }

    /// The outcome never reached the asking agent: its session ended.
    private var agentMissed: some View {
        Label(WalletCardModel.agentMissedNote, systemImage: "bubble.left.and.exclamationmark.bubble.right")
            .font(.system(size: 12, weight: .medium)).foregroundStyle(SessionStatus.needsInput.color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Warning: \(WalletCardModel.agentMissedNote)")
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func row(_ name: String, _ value: String, mono: Bool = false) -> some View {
        GridRow {
            label(name)
            Text(value)
                .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12.5))
                .lineLimit(mono ? 1 : nil).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(mono ? value : "")
        }
        .accessibilityElement(children: .combine)
    }

    /// What the Wallet Manager sent back that's worth keeping: the transaction hash and its explorer link.
    @ViewBuilder private var outcome: some View {
        switch card.state {
        case .signed(let hash, let url), .sentFromBrowser(let hash, let url):
            hashRow("Transaction", hash)
            if let url {
                Link(destination: url) {
                    Label("View on explorer", systemImage: "arrow.up.forward.square")
                        .font(.system(size: 12, weight: .medium))
                }
                .accessibilityLabel("View the transaction on the explorer")
                .help(url.absoluteString)
            }
        case .proposed(let hash?):
            hashRow("Safe transaction", hash)
        default:
            EmptyView()
        }
    }

    private func hashRow(_ name: String, _ hash: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).font(.system(size: 11.5)).foregroundStyle(.secondary)
            Text(hash).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled).help(hash)
            Button { Pasteboard.copy(hash) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).accessibilityLabel("Copy the \(name.lowercased()) hash")
                .help("Copy")
        }
    }

    private var checks: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("The Wallet Manager's checks").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(card.checks, id: \.self) { check in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    let warning = card.isWarning(check)
                    Image(systemName: check.ok ? "checkmark.circle.fill" : warning ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                        .foregroundStyle(check.ok ? SessionStatus.done.color : warning ? SessionStatus.needsInput.color : Color(nsColor: .systemRed))
                        .frame(width: 14).accessibilityHidden(true)
                    Text(check.name).font(.system(size: 12, weight: .medium))
                    if !check.detail.isEmpty {
                        Text(check.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(check.name), \(check.ok ? "passed" : card.isWarning(check) ? "warning" : "failed")\(check.detail.isEmpty ? "" : ": \(check.detail)")")
            }
        }
        .textSelection(.enabled)
    }

    private var buttons: some View {
        let main = card.actions.filter { $0 != .browser && $0 != .settings }
        // The state's buttons lead, the first prominent; while the Wallet Manager isn't set up (no Send or Retry), the
        // browser wallet leads and Discard is plain.
        let leads = !card.actions.contains(.settings)
        return VStack(alignment: .leading, spacing: 8) {
            if !leads { browser }
            if !main.isEmpty {
                HStack(spacing: 8) {
                    ForEach(main, id: \.self) { action in
                        if action == main.first && leads {
                            Button(action.title) { act(action) }.buttonStyle(.borderedProminent)
                        } else {
                            Button(action.title) { act(action) }.buttonStyle(.bordered)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            if leads { browser }
            if card.actions.contains(.settings) { setup }
        }
        .controlSize(.regular)
    }

    /// The fallback, secondary: it skips the Wallet Manager, so it says so.
    @ViewBuilder private var browser: some View {
        if card.actions.contains(.browser) {
            VStack(alignment: .leading, spacing: 3) {
                Button { act(.browser) } label: { Label(WalletCardModel.Action.browser.title, systemImage: "safari") }
                    .buttonStyle(.bordered)
                    .accessibilityHint(WalletCardModel.browserNote)
                Text(WalletCardModel.browserNote)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Where Send to Wallet Manager would be while the Wallet Manager isn't set up: what's missing, and Settings › Wallet.
    private var setup: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(card.setupNeeded ?? "", systemImage: "gearshape")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(WalletCardModel.Action.settings.title) { act(.settings) }
                .buttonStyle(.bordered)
                .accessibilityHint("Opens Settings › Wallet")
        }
    }
}

/// The wallet requests the selected session's agent filed, pinned under its conversation: each a `WalletCard` whose
/// buttons go to the desk (nothing is sent until Send to Wallet Manager is pressed). Empty: nothing shown.
struct WalletRequestStrip: View {
    @ObservedObject var desk: WalletDesk
    let session: UUID

    var body: some View {
        let cards = desk.cards(for: session)
        if !cards.isEmpty {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(cards) { card in
                        WalletCard(card: card) { action in desk.act(action, on: card.id) }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: cards.count == 1)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Transaction requests")
        }
    }
}
