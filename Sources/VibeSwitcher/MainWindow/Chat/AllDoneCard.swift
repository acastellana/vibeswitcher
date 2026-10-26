import SwiftUI
import VibeCore

/// Where a lead's board cleared (`LeadAllDone`): a card in a green of its own with a checkmark seal, titled "All tasks
/// finished", the batch's plain-words summary below (a headline and a few bullets), and a fold listing its tasks and
/// how many merged. One view per mark, drawn from what the board holds: nothing is asked for here.
struct AllDoneCard: View {
    let mark: LeadAllDone
    /// For toggling only: the card doesn't observe the model (see `ChatItemRow`).
    let chat: ChatModel
    let expanded: Set<String>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @IncreasedContrast private var increased

    static func key(_ mark: LeadAllDone) -> String { "all-done:\(mark.id)" }

    /// The done status's green: text-safe on the chat's background, and on the card's tint of it (`tintOpacity`).
    static var tint: Color { SessionStatus.done.color }
    /// The tint's strength; none with Increase Contrast, where the 7:1 inks are measured on the plain background (the
    /// border still marks the card).
    static func tintOpacity(increased: Bool) -> Double { increased ? 0 : 0.08 }

    var body: some View {
        let open = expanded.contains(Self.key(mark))
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(Self.tint)
                    .accessibilityHidden(true)
                Text("All tasks finished").font(.system(size: 13.5, weight: .bold)).foregroundStyle(Self.tint)
                Spacer(minLength: 0)
                Text(Date(timeIntervalSince1970: mark.at).formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if let summary = mark.summary {
                VStack(alignment: .leading, spacing: 5) {
                    Text(summary.headline).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                    ForEach(summary.bullets.indices, id: \.self) { index in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(Self.tint).accessibilityHidden(true)
                            Text(summary.bullets[index]).foregroundStyle(.primary)
                        }
                        .font(.system(size: 12.5))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(([summary.headline] + summary.bullets).joined(separator: " "))
            } else {
                Text("Writing a short summary of what was done…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let receipts = mark.receipts {
                // What the batch cost: its receipts summed (marks from before receipts have none, and show nothing).
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "receipt").font(.system(size: 11)).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(Self.cost(receipts))
                }
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .help("Each task's receipt: its worker's working time, and the tokens its worker and verifier sessions spent, read "
                    + "from their transcripts. Costs are estimates at the API prices of \(receipts.pricesAsOf).")
            }
            Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { chat.toggle(Self.key(mark)) } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0)).accessibilityHidden(true)
                    Text(Self.count(mark))
                }
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.count(mark))
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            .accessibilityHint(open ? "Hides the list of tasks" : "Lists the tasks")
            if open {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(mark.tasks.indices, id: \.self) { index in
                        let task = mark.tasks[index]
                        Label { Text(task.title).foregroundStyle(.primary) } icon: {
                            Image(systemName: Self.symbol(task.outcome)).foregroundStyle(task.outcome == .merged ? Self.tint : .secondary)
                                .frame(width: 14).accessibilityHidden(true)
                        }
                        .font(.system(size: 12))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(task.title), \(Self.word(task.outcome))")
                    }
                }
                .textSelection(.enabled)
                .padding(.leading, 14)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Self.tint.opacity(Self.tintOpacity(increased: increased))))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Self.tint.opacity(increased ? 1 : 0.45), lineWidth: 1.5))
        .contextMenu { Button("Copy Summary") { Pasteboard.copy(Self.text(mark)) } }
    }

    /// "Cost: 4 tasks, 6.2 h of worker time, 61M tokens, est. $38.12; most expensive: …".
    static func cost(_ receipts: LeadReceiptTotals) -> String { "Cost: " + receipts.text + "." }

    /// "5 tasks · 4 merged".
    static func count(_ mark: LeadAllDone) -> String {
        "\(mark.tasks.count) task\(mark.tasks.count == 1 ? "" : "s") · \(mark.merged) merged"
    }

    static func symbol(_ outcome: LeadAllDone.Task.Outcome) -> String {
        switch outcome {
        case .merged: return "checkmark.circle.fill"
        case .folded: return "arrow.triangle.merge"
        case .abandoned: return "minus.circle"
        }
    }

    static func word(_ outcome: LeadAllDone.Task.Outcome) -> String {
        switch outcome {
        case .merged: return "merged"
        case .folded: return "folded into another task"
        case .abandoned: return "set aside"
        }
    }

    /// The card as text, for Copy.
    static func text(_ mark: LeadAllDone) -> String {
        var lines = ["All tasks finished"]
        if let summary = mark.summary { lines += [summary.headline] + summary.bullets.map { "- \($0)" } }
        if let receipts = mark.receipts { lines.append(cost(receipts)) }
        lines.append(count(mark))
        lines += mark.tasks.map { "- \($0.title) (\(word($0.outcome)))" }
        return lines.joined(separator: "\n")
    }
}
