import SwiftUI
import VibeCore

/// A shell an agent asked for (`ShellDesk.Card`): who asks, the folder, and the exact command as one monospaced block
/// (all of it: wrapped, and scrolled when long, never cut), then Run and Decline while it waits, or what became of it.
struct ShellCard: View {
    let card: ShellDesk.Card
    var act: (ShellDesk.Action) -> Void = { _ in }
    @IncreasedContrast private var increased

    static func tint(_ state: ShellDesk.Card.State) -> Color {
        switch state {
        case .waiting: return SessionStatus.needsInput.color
        case .starting: return SessionStatus.working.color
        case .started: return SessionStatus.done.color
        case .failed: return Color(nsColor: .systemRed)
        case .declined, .expired: return .secondary
        }
    }

    static func title(_ state: ShellDesk.Card.State) -> String {
        switch state {
        case .waiting: return "Waiting for you"
        case .starting: return "Starting"
        case .started(_, let auto): return auto ? "Started without asking" : "Started"
        case .declined: return "Declined"
        case .expired: return "Expired"
        case .failed: return "Didn't start"
        }
    }

    static func symbol(_ state: ShellDesk.Card.State) -> String {
        switch state {
        case .waiting: return "hand.raised.fill"
        case .starting: return "hourglass"
        case .started: return "checkmark.circle.fill"
        case .declined: return "xmark.circle"
        case .expired: return "clock.badge.xmark"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    /// The line under the command: what Run does, or what happened.
    static func detail(_ card: ShellDesk.Card) -> String {
        switch card.state {
        case .waiting(let until):
            return "Run opens a new shell session in this folder that runs the command as you, with your login shell, and stays open "
                + "when it ends. Nothing runs until you press Run. It expires at \(until.formatted(date: .omitted, time: .shortened))."
        case .starting: return "Starting the shell session…"
        case .started(let name, let auto):
            return "Running in the session “\(name)”" + (auto ? ", started without asking (Settings › Agents)." : ".")
        case .declined: return "You declined it; nothing ran. The agent was told."
        case .expired: return "No answer in 30 minutes; nothing ran. The agent was told."
        case .failed(let why): return "It didn't start: \(why)"
        }
    }

    var body: some View {
        let tint = Self.tint(card.state)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "terminal").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("New shell request").font(.system(size: 13.5, weight: .bold))
                Spacer(minLength: 8)
                Label(Self.title(card.state), systemImage: Self.symbol(card.state))
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(tint)
                    .accessibilityLabel("State: \(Self.title(card.state))")
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                GridRow {
                    label("Asked by")
                    Text(card.asker).font(.system(size: 12.5, weight: .semibold))
                }
                GridRow {
                    label("Folder")
                    Text(card.request.cwd).font(.system(size: 12, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
                }
                if !card.request.label.isEmpty {
                    GridRow {
                        label("Session name")
                        Text(ShellAsk.sessionLabel(card.request)).font(.system(size: 12.5))
                    }
                }
            }
            .textSelection(.enabled)
            command
            Text(Self.detail(card))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            buttons
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(increased ? 0 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(increased ? 1 : 0.4), lineWidth: 1.5))
        .contextMenu { Button("Copy Command") { Pasteboard.copy(card.request.command) } }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    /// The exact command, every character of it: wrapped, scrolled past a dozen lines or so, selectable.
    private var command: some View {
        let lines = card.request.command.split(separator: "\n", omittingEmptySubsequences: false).count
        return VStack(alignment: .leading, spacing: 3) {
            if lines > 1 {
                Text("Command, \(lines) lines").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            commandBlock
        }
    }

    private var commandBlock: some View {
        ScrollView(.vertical) {
            Text(card.request.command)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(8)
        }
        .scrollIndicators(.visible)
        .frame(maxHeight: 200)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.secondary.opacity(0.35), lineWidth: 1))
        .accessibilityLabel("Command: \(card.request.command)")
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 8) {
            Spacer()
            switch card.state {
            case .waiting:
                Button("Decline") { act(.decline) }
                Button("Run") { act(.run) }.buttonStyle(.borderedProminent)
                    // No key: Return in the composer must never start a shell.
            case .starting:
                EmptyView()
            default:
                Button("Dismiss") { act(.dismiss) }
            }
        }
        .controlSize(.regular)
    }
}

/// The selected session's shell requests, under its conversation beside its wallet cards.
struct ShellRequestStrip: View {
    @ObservedObject var desk: ShellDesk
    let session: UUID

    var body: some View {
        let cards = desk.cards(for: session)
        if !cards.isEmpty {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(cards) { card in
                        ShellCard(card: card) { action in desk.act(action, on: card.id) }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: cards.count == 1)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Shell requests")
        }
    }
}
