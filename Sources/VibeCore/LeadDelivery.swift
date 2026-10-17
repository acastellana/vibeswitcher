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
    /// What happened to a message: steered into a working agent (it gets it at its next step), typed in as an idle
    /// agent's prompt, or queued (idle, but its box held a draft or couldn't be read): it then rides along with the
    /// next prompt, or `flush` types it once the box is empty.
    public enum Delivered: Equatable, Sendable { case steered, typed, queued }

    /// Steers the message in, or types it when the agent is idle, its input box is empty and `typeInto` reaches its
    /// terminal (a window session; returns whether the keys went out). Otherwise it waits in the inbox.
    @discardableResult
    public static func deliver(_ text: String, from sender: SteerMessage.Sender, to agent: LeadAgent,
                               inputIsEmpty: (() -> Bool)? = nil, typeInto: ((String) -> Bool)?) throws -> Delivered {
        try deliver(text, from: sender, to: agent, state: HookState.load(from: VibePaths.stateFile(tty: agent.tty)),
                    inputIsEmpty: inputIsEmpty, typeInto: typeInto)
    }

    public static func deliver(_ text: String, from sender: SteerMessage.Sender, to agent: LeadAgent, state: HookState?,
                               inputIsEmpty: (() -> Bool)?, typeInto: ((String) -> Bool)?, root: URL = VibePaths.root) throws -> Delivered {
        if way(for: state) == .type {
            if inputIsEmpty?() ?? false, let typeInto, typeInto(typed(text, from: sender)) { return .typed }
            try SteerInbox.post(SteerMessage(text: text, from: sender, agentPid: agent.pid), tty: agent.tty, root: root)
            return .queued
        }
        try SteerInbox.post(SteerMessage(text: text, from: sender, agentPid: agent.pid), tty: agent.tty, root: root)
        return .steered
    }

    /// Types the messages waiting for an idle agent once its input box is empty (an idle agent fires no hook, so
    /// nothing else would deliver them). Returns whether it typed.
    @discardableResult
    public static func flush(_ agent: LeadAgent, state: HookState?, inputIsEmpty: () -> Bool, typeInto: (String) -> Bool,
                             root: URL = VibePaths.root) -> Bool {
        guard way(for: state) == .type,
              SteerInbox.pending(tty: agent.tty, root: root).contains(where: { $0.agentPid == agent.pid }),
              inputIsEmpty() else { return false }
        let messages = SteerInbox.take(tty: agent.tty, agentPid: agent.pid, root: root)
        guard let first = messages.first else { return false }
        // The first becomes the prompt (marked as its sender's); the rest go back, and the prompt's own hook
        // hands them to the agent with it. Not typed: all of them wait, in order, for the next try.
        let typedIt = typeInto(typed(first.text, from: first.from))
        for message in typedIt ? Array(messages.dropFirst()) : messages { try? SteerInbox.post(message, tty: agent.tty, root: root) }
        return typedIt
    }
}
