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

/// The colored square that says which agent runs in a row, with its status dot on the corner.
struct AgentMark: View {
    let kind: MarkKind
    var status: Color?
    var hollow = false
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(kind.color.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: kind.symbol).font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(.white))
            .overlay(alignment: .bottomTrailing) {
                if let status {
                    let dot = size * 0.42
                    ZStack {
                        Circle().fill(Color(nsColor: .windowBackgroundColor))
                        if hollow {
                            Circle().strokeBorder(status, lineWidth: 1.5).padding(2)
                        } else {
                            Circle().fill(status).padding(2)
                        }
                    }
                    .frame(width: dot, height: dot)
                    .offset(x: dot * 0.3, y: dot * 0.3)
                }
            }
            .accessibilityLabel(kind.name)
    }
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
            if !info.isLive { return .gray.opacity(0.5) }
            return info.agent != nil ? .orange.opacity(0.6) : .gray.opacity(0.6)
        case .agent(let session):
            return session.dotColor
        }
    }

    var statusIsHollow: Bool { session?.dotIsHollow ?? false }

    var isDimmed: Bool {
        if case .hosted(let info) = content { return !info.isLive }
        return session?.isPaused == true
    }
}

extension Durations {
    /// Just the largest unit: "45s", "12m", "3h", "2d".
    static func compact(_ seconds: TimeInterval) -> String {
        String(short(seconds).split(separator: " ").first ?? "")
    }
}
