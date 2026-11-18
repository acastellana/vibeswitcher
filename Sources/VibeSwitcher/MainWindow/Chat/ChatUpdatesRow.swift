import SwiftUI
import VibeCore

/// A burst of VibeSwitcher's cards for the lead as one quiet line (see `ChatUpdates`): how many, and each in a few
/// words from its AI summary or its title; a red mark when one is a failure the user may care about. Opened, the
/// cards and the lead's tool runs between them show as they always do (the wake-up for waiting reports left out: it
/// only names them).
struct ChatUpdatesRow: View {
    let updates: ChatUpdates
    /// For toggling only: the row doesn't observe the model (see `ChatItemView`).
    let chat: ChatModel
    let expanded: Set<String>
    let openImage: (ChatImage) -> Void
    @Environment(\.teamSummaries) private var summaries
    @Environment(\.chatTaskStandings) private var standings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let open = expanded.contains(updates.id)
        VStack(alignment: .leading, spacing: 8) {
            Group {
                // Only a line whose mark can change with the board watches it.
                if let standings, updates.watchesBoard {
                    StandingsReader(standings: standings) { tasks in line(open: open, marked: updates.alarming(tasks: tasks)) }
                } else {
                    line(open: open, marked: updates.alarming)
                }
            }
            if open {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(updates.shown, id: \.id) { item in
                        switch item {
                        case .team(let entry, let message):
                            TeamMessageCard(entry: entry, message: message, chat: chat, expanded: expanded).padding(.trailing, 40)
                        case .tools(let id, let tools):
                            ToolGroupView(id: id, tools: tools, chat: chat, expanded: expanded, openImage: openImage).padding(.leading, 30)
                        default:
                            EmptyView()
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder private func line(open: Bool, marked: Bool) -> some View {
        if let summaries {
            SummarizedLine(summaries: summaries, updates: updates, marked: marked, open: open, toggle: toggle)
        } else {
            UpdatesLine(updates: updates, text: updates.line(), marked: marked, open: open, toggle: toggle)
        }
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { chat.toggle(updates.id) }
    }
}

/// The line with the cards' AI summaries as they come; asks for them when it shows, as each card does.
private struct SummarizedLine: View {
    @ObservedObject var summaries: TeamSummaryModel
    let updates: ChatUpdates
    let marked: Bool
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        UpdatesLine(updates: updates, text: updates.line { summaries.line($0, id: $1) }, marked: marked, open: open, toggle: toggle)
            // On showing, again when summaries are turned on or the burst gains a card.
            .task(id: "\(summaries.enabled)|\(updates.cards.count)") {
                for card in updates.cards { summaries.request(card.message, id: card.entry.id) }
            }
    }
}

/// The lead's tasks as its board has them now, for the lines whose mark can change with it (`ChatUpdates.watchesBoard`).
private struct StandingsReader<Content: View>: View {
    @ObservedObject var standings: ChatTaskStandings
    let content: ([String: ChatTaskStanding]?) -> Content

    var body: some View { content(standings.tasks) }
}

/// The lead's tasks as its board has them, for the folded update lines' red marks (`ChatUpdates.alarming(tasks:)`):
/// one object for as long as the chat is up, set from the board the Team panel already gets (`ChatContainer`), and
/// published only when a task's standing changes. A new value in the environment at each board change would have every
/// row's environment looked at again (see `LeadAnswer`); only the lines that watch the board observe this.
final class ChatTaskStandings: ObservableObject {
    /// By slug; nil: not a lead's chat, or its board not read.
    @Published private(set) var tasks: [String: ChatTaskStanding]?

    func update(_ tasks: [String: ChatTaskStanding]?) {
        if tasks != self.tasks { self.tasks = tasks }
    }
}

private struct ChatTaskStandingsKey: EnvironmentKey {
    static let defaultValue: ChatTaskStandings? = nil
}

extension EnvironmentValues {
    /// The lead's tasks for the folded update lines' marks; nil: none (every alarming card counts as current).
    var chatTaskStandings: ChatTaskStandings? {
        get { self[ChatTaskStandingsKey.self] }
        set { self[ChatTaskStandingsKey.self] = newValue }
    }
}

private struct UpdatesLine: View {
    let updates: ChatUpdates
    let text: String
    /// A card in it is a failure that's still current (`ChatUpdates.alarming(tasks:)`).
    let marked: Bool
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: "tray.full").accessibilityHidden(true)
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(TeamMessageCard.tint.opacity(0.8))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(TeamMessageCard.tint.opacity(0.09)))
                    .overlay(alignment: .topTrailing) {
                        if marked { Circle().fill(Color.red).frame(width: 7, height: 7).offset(x: 1, y: -1) }
                    }
                Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 90 : 0)).accessibilityHidden(true)
                Spacer(minLength: 0)
                if let at = updates.cards.last?.entry.at {
                    Text(at.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chatRowControl()
        .help(text)
        .chatRowButton((marked ? "Includes a failure. " : "") + text, toggle: toggle)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
        .padding(.leading, 30)
    }
}
