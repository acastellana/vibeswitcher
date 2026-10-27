import SwiftUI
import VibeCore

/// What runs in a row: an agent, or a plain shell.
enum MarkKind: Equatable {
    case agent(Agent)
    case shell

    var color: Color {
        switch self {
        case .agent(.claude): return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .agent(.codex): return Color(red: 0.36, green: 0.42, blue: 0.86)
        case .shell: return Color(white: 0.45)
        }
    }

    var symbol: String {
        switch self {
        case .agent(.claude): return "sparkle"
        case .agent(.codex): return "chevron.left.forwardslash.chevron.right"
        case .shell: return "terminal"
        }
    }

    var name: String {
        switch self {
        case .agent(let agent): return agent.displayName
        case .shell: return "Shell"
        }
    }
}

/// The colored square that says which agent runs in a row, with its status dot on the corner. With `statusFirst` (the
/// sidebar's rows) the two swap: the status's shape is the mark, the agent's square a badge on its corner.
struct AgentMark: View {
    let kind: MarkKind
    var status: Color?
    var hollow = false
    var size: CGFloat = 22
    /// The status's shape in that dot ("!" needs you, a spinner arc working, a check done), so it reads without colour.
    var mark: StatusMark?
    /// The status in words, for VoiceOver: "Claude, needs input".
    var spoken: String?
    /// The status big and the agent small (when there's a status to show).
    var statusFirst = false

    var body: some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenLabel)
    }

    /// What VoiceOver says, whichever part is big: "Claude, needs input".
    var spokenLabel: String { spoken.map { "\(kind.name), \($0.lowercased())" } ?? kind.name }

    @ViewBuilder private var content: some View {
        if statusFirst, let status, let mark {
            statusMark(mark, color: status)
        } else {
            agentMark
        }
    }

    private var agentMark: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(kind.color.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: kind.symbol).font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(.white)
                .accessibilityHidden(true))
            .overlay(alignment: .bottomTrailing) {
                if let status {
                    let dot = size * 0.42
                    ZStack {
                        Circle().fill(Color(nsColor: .windowBackgroundColor))
                        if let mark {
                            StatusMarkView(mark, color: status, size: dot - 3)
                        } else if hollow {
                            Circle().strokeBorder(status, lineWidth: 1.5).padding(2)
                        } else {
                            Circle().fill(status).padding(2)
                        }
                    }
                    .frame(width: dot, height: dot)
                    .offset(x: dot * 0.3, y: dot * 0.3)
                }
            }
    }

    private func statusMark(_ mark: StatusMark, color: Color) -> some View {
        let layout = StatusFirstLayout(size: size)
        return ZStack(alignment: .topLeading) {
            StatusMarkView(mark, color: color, size: layout.status.width)
                .offset(x: layout.status.minX, y: layout.status.minY)
            // A ring in the window's colour round the badge, so it stands apart from the status and the row.
            RoundedRectangle(cornerRadius: layout.badgeRadius + layout.ring, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: layout.badge.width + 2 * layout.ring, height: layout.badge.height + 2 * layout.ring)
                .offset(x: layout.badge.minX - layout.ring, y: layout.badge.minY - layout.ring)
            RoundedRectangle(cornerRadius: layout.badgeRadius, style: .continuous)
                .fill(kind.color.gradient)
                .frame(width: layout.badge.width, height: layout.badge.height)
                .overlay(Image(systemName: kind.symbol).font(.system(size: layout.badge.width * 0.6, weight: .bold)).foregroundStyle(.white))
                .offset(x: layout.badge.minX, y: layout.badge.minY)
        }
        .frame(width: size, height: size, alignment: .topLeading)
    }
}

/// Where `AgentMark(statusFirst:)` draws its parts in its `size` square (y down): the status's shape at the top left,
/// and the agent's badge on the bottom-right corner, past the square's edge, as the status dot was. The badge and its
/// ring stay clear of the status's disc (no shape is cut), which is why the status is a little smaller than the square.
struct StatusFirstLayout {
    let size: CGFloat

    var status: CGRect { CGRect(x: 0, y: 0, width: size * 0.8, height: size * 0.8) }
    var badge: CGRect {
        let side = size * 0.5
        return CGRect(x: size - side * 0.6, y: size - side * 0.6, width: side, height: side)
    }
    var badgeRadius: CGFloat { badge.width * 0.28 }
    /// The window-coloured ring round the badge.
    var ring: CGFloat { max(1, size * 0.06) }
}

extension WindowRow {
    var markKind: MarkKind {
        switch content {
        case .agent(let session): return .agent(session.agent)
        case .hosted(let info): return info.agent.flatMap(Agent.init(rawValue:)).map(MarkKind.agent) ?? .shell
        }
    }

    /// The status dot: red needs you, orange working, blue background jobs, green ready, grey otherwise.
    var statusColor: Color {
        switch content {
        case .hosted(let info):
            if !info.isLive { return SessionStatus.unknown.color }
            if let program = info.liveProgramStatus { return StatusRules.status(for: program).color }
            return state(now: Date()).group == .working ? SessionStatus.working.color : SessionStatus.idle.color
        case .agent(let session):
            return session.dotColor
        }
    }

    var statusIsHollow: Bool { session?.dotIsHollow ?? false }

    /// The status dot's shape, matching `statusColor`.
    var statusMark: StatusMark {
        switch content {
        case .hosted(let info):
            if !info.isLive { return .outline }
            if let program = info.liveProgramStatus { return StatusMark(status: StatusRules.status(for: program)) }
            return state(now: Date()).group == .working ? .spinner : .smallDot
        case .agent(let session):
            return session.mark
        }
    }

    /// The status in words, as the header's pill says it: "Needs you", "Working", "Ended"…
    var spokenStatus: String { pillLabel(state(now: Date())) }

    var isDimmed: Bool {
        if case .hosted(let info) = content { return !info.isLive }
        return session?.isPaused == true
    }
}
