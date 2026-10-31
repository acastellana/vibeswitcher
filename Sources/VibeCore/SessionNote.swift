import Foundation

/// What a session VibeSwitcher started is told when its agent starts: that it can ask for a transaction with `vs-vault`
/// (see `VaultAsk`). The hook hands it to Claude Code at SessionStart as added context, the same JSON the hook replies
/// with when it hands over messages (`SteerReply.output`). Only sessions the session host started (they carry
/// `VIBESWITCHER_SESSION`, which `vs-vault` needs anyway) and not a lead's, worker's or verifier's: those have prompts of
/// their own and carry `roleVariable` (`LeadLaunch.prepare`).
public enum SessionNote {
    /// Set to the role's name in the sessions `LeadLaunch` starts (lead, worker, verifier).
    public static let roleVariable = "VIBESWITCHER_ROLE"

    public static let text = """
        [VibeSwitcher · session note] This session runs in VibeSwitcher. When a transaction is needed (a payment, a \
        transfer, a contract call), ask for it with `vs-vault request …` (on your PATH; `vs-vault help` lists the fields). \
        It files the request as a card in this session's chat: nothing is sent until the user clicks Send to vault there. \
        The vault Mac then checks it and the user signs it there with a hardware wallet; its answers come back to you as \
        messages. vs-vault never holds or takes keys: never put a key, seed or recovery phrase in a request.
        """

    /// The hook's reply to `payload`: the note at a Claude Code session's start (a new one, a resumed one, one cleared
    /// with /clear; not the restart after a compaction, whose context keeps it), on its main thread, in a session
    /// VibeSwitcher started that isn't a lead's, worker's or verifier's. Nil otherwise.
    public static func output(payload: [String: Any], environment: [String: String]) -> Data? {
        guard payload["hook_event_name"] as? String == "SessionStart",
              ["startup", "resume", "clear"].contains(payload["source"] as? String ?? "startup") else { return nil }
        switch payload["agent_id"] {
        case nil, is NSNull: break
        case let id as String where id.isEmpty: break
        default: return nil
        }
        guard let session = environment["VIBESWITCHER_SESSION"], UUID(uuidString: session) != nil,
              (environment[roleVariable] ?? "").isEmpty else { return nil }
        let object = ["hookSpecificOutput": ["hookEventName": "SessionStart", "additionalContext": text]]
        return try? JSONSerialization.data(withJSONObject: object)
    }
}
