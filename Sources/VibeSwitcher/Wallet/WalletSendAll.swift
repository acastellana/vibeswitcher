import AppKit
import SwiftUI
import VibeCore

/// Send all: one session's waiting wallet requests, sent to the Wallet Manager by one action that first lists exactly
/// what will go (`WalletSendAllView`). Nothing leaves the Mac that the list didn't show.
///
/// It is a snapshot: the requests and cards as they were when the list opened (`items`, in filing order). Confirming
/// sends those and no other: a request filed since isn't in it. Before anything goes, and again before each request,
/// every one listed must still be as listed (the same request, the same card, still waiting with Send); if not,
/// nothing more is sent and the list says to open it again. Fail closed.
///
/// It has no way to the Wallet Manager of its own: each request goes through its card's Send (the desk's `act` with
/// send, which checks it as for a click), one at a time, and its card shows its own outcome. The run goes on only
/// past a request whose card then says it went; at any other outcome (the Wallet Manager not reachable, not sent, may
/// have arrived, expired) it stops, and the rest stay waiting, untouched. Only Send to Wallet Manager: never the
/// browser wallet, never Retry, never another session's requests. No rule, timer or setting sends anything: only
/// `confirm`, from the list's button.
///
/// On the main thread, as the desk's cards are.
final class WalletSendAll: ObservableObject, Identifiable {
    /// A listed request: what its card was drawn from, and the card as shown then.
    struct Item: Equatable, Identifiable {
        let request: WalletRequest
        let card: WalletCardModel
        var id: String { request.id }
    }

    /// One fact of a request, as the list words it.
    struct Field: Equatable, Hashable {
        /// Which fact, the same for every request: fields are compared under it.
        var key: String
        var name: String
        var value: String
        /// An address or id: monospaced, on one line.
        var mono = false
        /// The agent's own words (its label, its reason): set apart as such.
        var agents = false
        /// A call that isn't decoded or grants too much, as its card marks it.
        var alarming = false
    }

    enum Phase: Equatable {
        /// Listed, nothing sent: waits for Send or Cancel.
        case review
        case sending
        /// Over: what went and what didn't.
        case done(Summary)
        /// Cancelled or closed before Send: nothing was sent, and nothing can be from this list.
        case cancelled
    }

    struct Summary: Equatable {
        /// How many of the listed requests went to the Wallet Manager.
        var sent: Int
        /// How many didn't: they keep their cards.
        var notSent: Int
        /// Nothing was sent because a listed request was no longer as listed: the list must be opened again.
        var reopen = false
        var text: String
    }

    let desk: WalletDesk
    let session: UUID
    /// The session's name, as its cards have it.
    let requestedBy: String
    let items: [Item]
    @Published private(set) var phase: Phase = .review
    /// The request being sent now.
    @Published private(set) var sending: String?
    /// Each request's card state once its send came back (nil in it: its card was gone).
    @Published private(set) var outcomes: [String: WalletCardModel.State?] = [:]
    private var sent = 0
    private var stopAsked = false
    private var finished: () -> Void = {}

    /// The list for `session`'s waiting requests as the desk shows them now; nil when it isn't offered (`WalletDesk.sendAllCount`).
    fileprivate init?(desk: WalletDesk, session: UUID) {
        guard desk.sendAllCount(for: session) != nil else { return nil }
        let cards = desk.waitingToSend(for: session)
        var items: [Item] = []
        for card in cards {
            guard let request = desk.drawn[card.id] else { return nil }
            items.append(Item(request: request, card: card))
        }
        self.desk = desk
        self.session = session
        self.requestedBy = cards[0].requestedBy
        self.items = items
    }

    static func offerTitle(_ count: Int) -> String { "Send all \(count) to Wallet Manager…" }
    var title: String { "Send \(items.count) requests to the Wallet Manager" }
    var confirmTitle: String { "Send \(items.count) to Wallet Manager" }
    static let note = "Nothing has left this Mac. Each request below goes as its own request, in this order, and keeps its own card. "
        + "One filed after this list opened isn't in it."

    // MARK: What the list shows

    /// A card's facts, in the list's order: the same keys for every card.
    static func fields(of card: WalletCardModel) -> [Field] {
        var calldata = "None: a transfer"
        var alarming = false
        if let call = card.call {
            calldata = call.headline + (call.function.map { " (\($0))" } ?? "")
            calldata += call.fields.map { "\n\($0.name): \($0.value)" }.joined()
            if let bytes = card.calldataBytes { calldata += "\n\(bytes) bytes" }
            alarming = call.alarming || call.fields.contains { $0.alarming }
        }
        return [
            Field(key: "chain", name: "Chain", value: card.chainText),
            Field(key: "from", name: "From", value: card.from, mono: true),
            Field(key: "to", name: card.call == nil ? "To" : "Contract", value: card.to, mono: true),
            Field(key: "amount", name: card.call == nil ? "Amount" : "Value sent", value: "\(card.amount) \(card.asset)"),
            Field(key: "calldata", name: "Calldata", value: calldata, alarming: alarming),
            Field(key: "workspace", name: "Workspace", value: card.workspace),
            Field(key: "label", name: "The agent's label", value: card.requestedByLabel.isEmpty ? "None given" : "“\(card.requestedByLabel)”",
                  agents: !card.requestedByLabel.isEmpty),
            Field(key: "reason", name: WalletCardModel.reasonTitle, value: "“\(card.reason)”", agents: true),
        ]
    }

    /// The fields every card has alike (stated once above the list), and each card's that differ, in the cards' order.
    static func split(_ cards: [WalletCardModel]) -> (common: [Field], rows: [[Field]]) {
        let all = cards.map(fields(of:))
        guard let first = all.first else { return ([], []) }
        let alike = Set(first.filter { field in all.allSatisfy { $0.contains(field) } }.map(\.key))
        return (first.filter { alike.contains($0.key) }, all.map { $0.filter { !alike.contains($0.key) } })
    }

    var common: [Field] { Self.split(items.map(\.card)).common }
    var rows: [[Field]] { Self.split(items.map(\.card)).rows }
    static let sameRow = "The same as above in everything shown"

    /// A row's state beside it, once the run started: its card's, as the desk has it now.
    func status(of item: Item) -> String? {
        switch phase {
        case .review, .cancelled: return nil
        case .sending, .done:
            if sending == item.id { return "Sending…" }
            guard let card = desk.cards.first(where: { $0.id == item.id }) else { return "Gone" }
            return WalletCardModel.title(card.state)
        }
    }

    /// The list as text (the sandbox prints it).
    var text: String {
        var lines = [title, "Requested by: \(requestedBy)", Self.note, "The same in all \(items.count):"]
        func line(_ field: Field) -> String { "  \(field.name): \(field.value.replacingOccurrences(of: "\n", with: "; "))" }
        lines += common.map(line)
        for (index, row) in rows.enumerated() {
            lines.append("Request \(index + 1)" + (status(of: items[index]).map { " [\($0)]" } ?? ""))
            lines += row.isEmpty ? ["  " + Self.sameRow] : row.map(line)
        }
        switch phase {
        case .review: lines.append("Buttons: Cancel, \(confirmTitle)")
        case .sending: lines.append("Sending")
        case .done(let summary): lines.append(summary.text)
        case .cancelled: lines.append("Cancelled: nothing was sent")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Sending

    /// Whether a card in `state`, after its Send, says the request went to the Wallet Manager. Anything else stops the run.
    static func went(_ state: WalletCardModel.State) -> Bool {
        switch state {
        case .sent, .received, .proposed, .signedNotSubmitted, .signed, .rejected, .failed: return true
        case .waiting, .unreachable, .unsure, .notSent, .expired, .inBrowser, .sentFromBrowser, .rejectedInWallet, .browserNoAnswer: return false
        }
    }

    /// Whether `item` is still what the list showed: the same request, drawn as the same card, of this session, waiting
    /// with Send.
    private func asListed(_ item: Item) -> Bool {
        guard desk.sessions[item.id] == session.uuidString.lowercased(), desk.drawn[item.id] == item.request,
              let card = desk.cards.first(where: { $0.id == item.id }) else { return false }
        return card == item.card && card.state == .waiting && card.actions.contains(.send)
    }

    /// The list's Send: the listed requests, each through its card's Send, in order. Only from `.review`, once.
    /// `then` runs when it's over (see `phase`).
    func confirm(then: @escaping () -> Void = {}) {
        guard phase == .review else { return then() }
        phase = .sending
        finished = then
        // The desk looks at the filed requests again first, so a listed one that changed on disk since is seen as changed.
        desk.refresh(polling: false) { [self] in
            if let index = items.firstIndex(where: { !asListed($0) }) {
                return finish(reopen: true, "Nothing was sent. Request \(index + 1) is no longer waiting as this list shows it "
                              + "(sent, discarded, expired or changed since it opened). Close this list and open it again to review the requests as they are now.")
            }
            send(0)
        }
    }

    private func send(_ index: Int) {
        let count = items.count
        guard index < count else { return finish("All \(count) sent to the Wallet Manager. Each card shows its own answer.") }
        let left = count - index
        if stopAsked { return finish("\(sent) of \(count) sent. You stopped it: the other \(left) still wait on their cards.") }
        let item = items[index]
        guard asListed(item) else {
            return finish("\(sent) of \(count) sent. Request \(index + 1) is no longer waiting as this list shows it, so it and "
                          + "the \(left - 1) after it weren't sent by this list: \(left) not sent.")
        }
        sending = item.id
        desk.act(.send, on: item.id) { [self] in
            sending = nil
            let state = desk.cards.first { $0.id == item.id }?.state
            outcomes[item.id] = .some(state)
            if let state, Self.went(state) {
                sent += 1
                return send(index + 1)
            }
            // Still waiting: the desk didn't send it (it changed since its card was drawn).
            let why = state == .waiting ? "not sent: it changed" : state.map { WalletCardModel.title($0) } ?? "its card is gone"
            finish("\(sent) of \(count) sent. Stopped at request \(index + 1) (\(why)): its card says what happened. "
                   + (left > 1 ? "The \(left - 1) after it weren't tried and still wait on their cards." : "None was left after it."))
        }
    }

    private func finish(reopen: Bool = false, _ text: String) {
        sending = nil
        phase = .done(Summary(sent: sent, notSent: items.count - sent, reopen: reopen, text: text))
        let then = finished
        finished = {}
        then()
    }

    /// Cancel, or the list closed: before Send, nothing is sent and this list can send nothing later; during the run,
    /// no further request is started (the one under way ends as it ends).
    func cancel() {
        switch phase {
        case .review: phase = .cancelled
        case .sending: stopAsked = true
        case .done, .cancelled: break
        }
    }
}

extension WalletDesk {
    /// The session's cards that wait for Send to Wallet Manager and offer it (so one is chosen and can be run), oldest first.
    func waitingToSend(for session: UUID) -> [WalletCardModel] {
        cards(for: session).filter { $0.state == .waiting && $0.actions.contains(.send) }
    }

    /// How many requests Send all would list for `session`: 2 or more, each with the request its card was drawn from;
    /// nil when it isn't offered (fewer, or no Wallet Manager to send to).
    func sendAllCount(for session: UUID) -> Int? {
        let waiting = waitingToSend(for: session)
        guard waiting.count >= 2, waiting.allSatisfy({ drawn[$0.id] != nil }) else { return nil }
        return waiting.count
    }

    /// The Send all list for `session` as its cards are now; nil when it isn't offered.
    func sendAll(for session: UUID) -> WalletSendAll? { WalletSendAll(desk: self, session: session) }
}

/// The Send all list: what is the same in every request once, then a row per request with what differs, and the
/// buttons. While it sends and after, each row has its card's state and the summary says how many went.
struct WalletSendAllView: View {
    @ObservedObject var review: WalletSendAll
    @ObservedObject var desk: WalletDesk
    /// Cancel or Close pressed.
    var close: () -> Void = {}
    @IncreasedContrast private var increased

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(review.title).font(.system(size: 15, weight: .bold)).accessibilityAddTraits(.isHeader)
                Text("Requested by \(review.requestedBy)").font(.system(size: 12.5, weight: .medium))
                Text(WalletSendAll.note).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !review.common.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The same in all \(review.items.count)").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                    grid(review.common)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.secondary.opacity(increased ? 0 : 0.08)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.secondary.opacity(increased ? 1 : 0.25), lineWidth: 1))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(review.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        row(index, item)
                    }
                }
            }
            .frame(maxHeight: 340)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("The \(review.items.count) requests")
            if case .done(let summary) = review.phase {
                Label {
                    Text(summary.text)
                } icon: {
                    Image(systemName: summary.notSent == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").accessibilityHidden(true)
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(summary.notSent == 0 ? SessionStatus.done.color : SessionStatus.needsInput.color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            }
            buttons
        }
        .padding(16)
        .frame(width: 580)
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            switch review.phase {
            case .review, .cancelled:
                Button("Cancel") {
                    review.cancel()
                    close()
                }
                .keyboardShortcut(.cancelAction)
                // No default key: Return alone doesn't send them.
                Button(review.confirmTitle) { review.confirm() }
                    .buttonStyle(.borderedProminent)
                    .disabled(review.phase != .review)
                    .accessibilityHint("Sends the \(review.items.count) requests listed, one at a time")
            case .sending:
                ProgressView().controlSize(.small).accessibilityLabel("Sending")
                Button("Stop After This One") { review.cancel() }
            case .done:
                Button("Close") { close() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func row(_ index: Int, _ item: WalletSendAll.Item) -> some View {
        let fields = review.rows[index]
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(index + 1)").font(.system(size: 12.5, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .trailing)
                .accessibilityLabel("Request \(index + 1)")
            if fields.isEmpty {
                Text(WalletSendAll.sameRow).font(.system(size: 12.5)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                grid(fields)
            }
            if let status = review.status(of: item) {
                let state = desk.cards.first { $0.id == item.id }?.state
                Text(status).font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(review.sending == item.id ? Color.secondary : state.map(WalletCard.tint) ?? .secondary)
                    .fixedSize()
                    .accessibilityLabel("State: \(status)")
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private func grid(_ fields: [WalletSendAll.Field]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(fields, id: \.key) { field in
                GridRow {
                    Text(field.name).font(.system(size: 11.5)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(field.value)
                        .font(field.mono ? .system(size: 12, design: .monospaced) : field.agents ? .system(size: 12.5).italic() : .system(size: 12.5, weight: field.alarming ? .semibold : .regular))
                        .foregroundStyle(field.alarming ? Color(nsColor: .systemRed) : .primary)
                        .lineLimit(field.mono ? 1 : field.agents ? WalletRequestFormat.maxReasonLines : nil).truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(field.mono ? field.value : "")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(field.name): \(field.alarming ? "warning, " : "")\(field.value)")
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Send all list as a sheet on the window its button was pressed in.
enum WalletSendAllSheet {
    /// Shows `review` over `parent`; `closed` runs once it's gone. With no window to show it on, nothing is shown and
    /// the list is cancelled: nothing is sent unseen.
    static func present(_ review: WalletSendAll, over parent: NSWindow?, closed: @escaping () -> Void = {}) {
        guard let parent else {
            review.cancel()
            return closed()
        }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.contentViewController = NSHostingController(rootView: WalletSendAllView(review: review, desk: review.desk) { [weak parent, weak sheet] in
            if let sheet { parent?.endSheet(sheet) }
        })
        parent.beginSheet(sheet) { _ in
            // Closed some other way than its buttons: as Cancel.
            review.cancel()
            closed()
        }
    }
}
