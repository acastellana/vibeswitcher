import Foundation

/// How a message reaches an agent: steered in while it works (at its next step, without stopping it), typed in
/// as its next prompt while it's idle (a steer would wait for a turn that never comes).
public enum LeadDelivery {
    public enum Way: Equatable, Sendable { case steer, type }

    public static func way(for state: HookState?) -> Way {
        guard let state else { return .type }
        return ["Stop", "SessionStart", "SessionEnd", "Notification", "PermissionRequest"].contains(state.lastEvent) ? .type : .steer
    }

    static let prefix = "[VibeSwitcher"

    /// The prompt typed for an idle agent: messages not from the user are marked, so neither the agent nor the
    /// chat takes them for the user's words.
    public static func typed(_ text: String, from sender: SteerMessage.Sender) -> String {
        switch sender {
        case .user: return text
        case .lead(let name): return "\(prefix) · from \(name), not the user] \(text)"
        case .system(let about): return "\(prefix) · \(about), not the user] \(text)"
        }
    }
}

extension LeadDelivery {
    /// Steers the message in, or types it when the agent is idle and `typeInto` can reach its terminal (a window
    /// session); a steer waits in the inbox otherwise and arrives with the agent's next prompt.
    /// `inputIsEmpty`: whether the agent's input box is empty right now (typing over a draft would mix the two;
    /// the steer then rides along with the user's own next prompt).
    public static func deliver(_ text: String, from sender: SteerMessage.Sender, to agent: LeadAgent,
                               inputIsEmpty: (() -> Bool)? = nil, typeInto: ((String) -> Bool)?) throws {
        let state = HookState.load(from: VibePaths.stateFile(tty: agent.tty))
        if way(for: state) == .type, inputIsEmpty?() ?? false, let typeInto, typeInto(typed(text, from: sender)) { return }
        try SteerInbox.post(SteerMessage(text: text, from: sender, agentPid: agent.pid), tty: agent.tty)
    }
}
