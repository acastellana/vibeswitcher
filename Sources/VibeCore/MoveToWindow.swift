import Foundation

/// Moving a conversation from a Terminal tab into the window: the agent is stopped there and resumed here,
/// where the terminal has full color.
public enum MoveToWindow {
    /// Only between turns (nothing is cut off), only from Terminal, only when its id is known for --resume,
    /// and only once there's a conversation on disk to resume (an agent writes none before its first prompt).
    public static func canMove(_ session: Session,
                               transcriptExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        guard session.inTerminalApp, !session.inWindow, session.agentSessionID != nil,
              [.idle, .done].contains(session.status), let transcript = session.transcriptPath else { return false }
        return transcriptExists(transcript)
    }

    public struct Plan: Equatable, Sendable {
        public var command: String
        public var env: [String: String]
        public var label: String
    }

    /// Resumes with the folder's first window preset for that agent (keeping its flags and environment),
    /// else the agent's plain command.
    public static func plan(agent: Agent, sessionID: String, presets: [LaunchPreset]) -> Plan {
        let preset = presets.first { $0.agent == agent && $0.place == .window }
        let base = preset.flatMap(LaunchPlan.command(for:))
        return Plan(command: LaunchPlan.resumeCommand(base: base, agent: agent, sessionID: sessionID),
                    env: preset?.env ?? [:], label: preset?.name ?? agent.displayName)
    }
}
