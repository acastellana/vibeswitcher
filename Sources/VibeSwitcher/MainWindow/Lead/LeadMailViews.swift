import SwiftUI
import VibeCore

/// The Team tab's "Between leads": every message this project's lead and other projects' leads sent each other with
/// tell_lead (see `LeadMail`), as the project's private record keeps them, refused ones included, newest first.
struct LeadMailFeed: Equatable {
    struct Item: Identifiable, Equatable {
        /// Its line in the record (oldest 0): the record is only ever appended to.
        let id: Int
        let at: Double
        let from: String
        let to: String
        /// Sent to this project's lead, not by it.
        let received: Bool
        /// "Question", "Report", "Answer", or "No kind" for one refused for its kind.
        let kind: String
        let text: String
        let outcome: LeadMail.Outcome
        /// What became of it, in a word or two: "Delivered", "Waiting", "Refused"…
        let outcomeLabel: String
        /// Why it wasn't sent, from what tell_lead answered (nil: it was).
        let reason: String?
        /// What tell_lead answered, whole.
        let detail: String

        var refused: Bool { !outcome.sent }
    }

    let items: [Item]

    /// `records` as `LeadMail.load` gives them (oldest first), for the project named `project` (`LeadMail.project`).
    init(_ records: [LeadMail.Record], project: String) {
        items = records.enumerated().map { index, record in
            Item(id: index, at: record.at, from: record.from, to: record.to,
                 received: record.to.caseInsensitiveCompare(project) == .orderedSame && record.from.caseInsensitiveCompare(project) != .orderedSame,
                 kind: Self.kindLabel(record.kind), text: record.text, outcome: record.outcome, outcomeLabel: Self.outcomeLabel(record.outcome),
                 reason: record.outcome.sent ? nil : Self.reason(record.detail), detail: record.detail)
        }
        // Newest first; the later line first for two sent in the same instant.
        .sorted { $0.at != $1.at ? $0.at > $1.at : $0.id > $1.id }
    }

    static func kindLabel(_ kind: LeadMail.Kind?) -> String {
        switch kind {
        case .question: return "Question"
        case .report: return "Report"
        case .answer: return "Answer"
        case nil: return "No kind"
        }
    }

    static func outcomeLabel(_ outcome: LeadMail.Outcome) -> String {
        switch outcome {
        case .delivered: return "Delivered"
        case .waiting: return "Waiting in its inbox"
        case .refused: return "Refused"
        case .noLead: return "Not sent: no lead running"
        case .off: return "Refused: lead mail is off"
        case .failed: return "Not sent: delivery failed"
        }
    }

    /// The reason in tell_lead's answer, without its "Refused, not sent:" or "Not sent:" start.
    static func reason(_ detail: String) -> String {
        var reason = detail
        for start in ["Refused, not sent: ", "Not sent: "] where reason.hasPrefix(start) {
            reason.removeFirst(start.count)
            break
        }
        return reason.isEmpty ? detail : reason.prefix(1).uppercased() + reason.dropFirst()
    }
}

/// The messages, newest first: the latest few in view, the rest folded into "Earlier (n)". A long message shows its
/// first lines; clicking it shows it whole, with what tell_lead answered.
struct LeadMailList: View {
    static let shown = 4
    let feed: LeadMailFeed
    @State var showEarlier = false
    /// Messages shown whole, by id, to begin with (pictures).
    @State var openItems: Set<Int> = []

    var body: some View {
        let earlier = feed.items.dropFirst(Self.shown)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(feed.items.prefix(Self.shown)) { item in row(item) }
            if !earlier.isEmpty {
                Fold(title: "Earlier (\(earlier.count))", isOpen: $showEarlier, hint: "the earlier messages between leads")
                    .padding(.horizontal, -8)
                if showEarlier {
                    ForEach(earlier) { item in row(item) }
                }
            }
        }
    }

    static func time(_ at: Double, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: at)
        return Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// What VoiceOver reads for a message.
    static func spoken(_ item: LeadMailFeed.Item) -> String {
        "\(item.kind) from the lead of \(item.from) to the lead of \(item.to), \(time(item.at)): \(item.text). "
            + (item.reason.map { "\(item.outcomeLabel): \($0)" } ?? item.outcomeLabel)
    }

    private func row(_ item: LeadMailFeed.Item) -> some View {
        let isOpen = openItems.contains(item.id)
        let toggle = { if isOpen { openItems.remove(item.id) } else { openItems.insert(item.id) } }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.kind).font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(item.refused ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                    .fixedSize()
                // Sent by this project's lead, or received by it: the other project's name has the room.
                Text(item.received ? "from \(item.from)" : "to \(item.to)").font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                Spacer(minLength: 4)
                Text(Self.time(item.at)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary).fixedSize()
            }
            Text(item.text).font(.system(size: 12))
                .foregroundStyle(item.refused ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .strikethrough(item.outcome == .refused || item.outcome == .off, color: .secondary.opacity(0.5))
                .lineLimit(isOpen ? nil : 3).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let reason = item.reason {
                (Text(item.outcomeLabel + ": ").font(.system(size: 11, weight: .semibold)) + Text(reason).font(.system(size: 11)))
                    .foregroundStyle(item.outcome == .refused || item.outcome == .off ? Color.red : Color.orange)
                    .lineLimit(isOpen ? nil : 2).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(isOpen ? item.detail : item.outcomeLabel).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(item.refused ? Color.red.opacity(0.05) : Color.secondary.opacity(0.06)))
        .overlay(alignment: .leading) {
            if item.refused { RoundedRectangle(cornerRadius: 1).fill(Color.red.opacity(0.6)).frame(width: 2).padding(.vertical, 4) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(item))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isOpen ? "Shows the message's first lines" : "Shows the whole message and what tell_lead answered")
        .accessibilityAction(.default, toggle)
    }
}
