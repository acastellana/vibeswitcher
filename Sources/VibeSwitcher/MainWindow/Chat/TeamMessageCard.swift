import SwiftUI
import VibeCore

/// A message VibeSwitcher handed the agent (a worker's report, an audit, a notice, the user's words relayed): a
/// collapsed card in a colour of its own, titled with its sender, its first line below, opening to the whole text.
/// With the Team view's AI summaries on, a long one gets a one-line TL;DR.
struct TeamMessageCard: View {
    let entry: ChatEntry
    let message: TeamMessage
    /// For toggling only: the card doesn't observe the model (see `ChatItemView`).
    let chat: ChatModel
    let expanded: Set<String>
    @Environment(\.teamSummaries) private var summaries
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func key(_ entry: ChatEntry) -> String { "team:\(entry.id)" }

    /// Not the user's blue, not the agent's plain text, not a steered message's orange.
    static let tint = Color.purple

    var body: some View {
        let open = expanded.contains(Self.key(entry))
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { chat.toggle(Self.key(entry)) } } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(symbolColor)
                        .frame(width: 18).padding(.top, 1).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(message.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.primary)
                        if !open {
                            Text(message.gist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                            // The whole card opens it; this says there's more than the cut shows.
                            if hasMore {
                                Text("More").font(.system(size: 11, weight: .medium)).foregroundStyle(Self.tint)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    if let at = entry.at {
                        Text(at.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.tertiary)
                            .padding(.top, 2)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0)).padding(.top, 3).accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .chatRowControl()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(open ? message.title : "\(message.title): \(message.gist)")
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            .accessibilityHint(open ? "Hides the whole message" : "Shows the whole message")
            .accessibilityAddTraits(.isButton)
            if let summaries { TeamMessageTLDR(summaries: summaries, message: message, id: entry.id) }
            if open {
                Group {
                    if message.kind == .userAnswer {
                        // Your own words, as your messages look.
                        Text(message.body).font(.system(size: 13)).lineSpacing(2).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.16)))
                            .accessibilityLabel("Your words: \(message.body)")
                    } else {
                        MarkdownView(text: message.body, fontSize: 13).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Self.tint.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Self.tint.opacity(0.3)))
        .contextMenu { Button("Copy") { Pasteboard.copy(message.body) } }
    }

    private var symbol: String {
        switch message.kind {
        case .report: return "doc.text"
        case .audit: return failed ? "xmark.seal" : "checkmark.seal"
        case .witness: return "eye"
        case .userAnswer: return "person.fill"
        case .leadMessage: return "person.2"
        case .notice: return "bell"
        }
    }

    /// Whether the collapsed card leaves something out: more than its first line, or a first line too long for two.
    private var hasMore: Bool {
        message.body.trimmingCharacters(in: .whitespacesAndNewlines) != message.gist || message.gist.count > 140
    }

    private var failed: Bool { message.kind == .audit && message.title.contains("didn't pass") }

    private var symbolColor: Color { failed ? .red : Self.tint }
}

/// The TL;DR line: asked for once when the card shows, drawn when it's come (nothing with summaries off).
private struct TeamMessageTLDR: View {
    @ObservedObject var summaries: TeamSummaryModel
    let message: TeamMessage
    let id: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let line = summaries.line(message, id: id) {
                Label { Text(line) } icon: { Image(systemName: "sparkles") }
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .padding(.leading, 26)
                    .accessibilityLabel("Summary: \(line)")
            }
        }
        // On showing, and again when summaries are turned on.
        .task(id: summaries.enabled) { summaries.request(message, id: id) }
    }
}

private struct TeamSummariesKey: EnvironmentKey {
    static let defaultValue: TeamSummaryModel? = nil
}

extension EnvironmentValues {
    /// Where a team message's TL;DR comes from (the Team view's summaries); nil: none.
    var teamSummaries: TeamSummaryModel? {
        get { self[TeamSummariesKey.self] }
        set { self[TeamSummariesKey.self] = newValue }
    }
}
