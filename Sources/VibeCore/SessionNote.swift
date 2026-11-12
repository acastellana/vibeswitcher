import Foundation

/// What a session VibeSwitcher started is told when its agent starts: that it can ask for a transaction with `vs-wallet`
/// (see `WalletAsk`). The hook hands it to Claude Code at SessionStart as added context, the same JSON the hook replies
/// with when it hands over messages (`SteerReply.output`). Only sessions the session host started (they carry
/// `VIBESWITCHER_SESSION`, which `vs-wallet` needs anyway) and not a lead's, worker's or verifier's: those have prompts of
/// their own and carry `roleVariable` (`LeadLaunch.prepare`).
public enum SessionNote {
    /// Set to the role's name in the sessions `LeadLaunch` starts (lead, worker, verifier).
    public static let roleVariable = "VIBESWITCHER_ROLE"

    /// What every agent VibeSwitcher starts is told about anything needing a real terminal: this note's and the lead's and
    /// worker's prompts' one wording (`LeadPrompts.lead`, `.worker`), since those sessions don't get this note. Claude Code's
    /// own system prompt tells an agent to suggest `! <command>`, so it has to say it replaces that: on 2026-11-08 a lead sent
    /// the user to Terminal.app and `!` failed three times on a locked signing keychain before `vs-shell run` worked.
    public static let realTerminal = "When something needs a real terminal (a password or other prompt, an install, an "
        + "interactive program, anything that asks questions on stdin or files wallet requests), ask for it with "
        + "`vs-shell run [--cwd DIR] [--label TEXT] -- COMMAND…` (on your PATH; `vs-shell help`): it puts the exact command on a "
        + "card in this session's chat, and one Run click from the user opens it in a new shell session with a real terminal; "
        + "when the command ends, its exit status and last lines of output come back to you as a message. "
        + "In VibeSwitcher this replaces Claude Code's advice to suggest `! <command>`: don't ask the user to open Terminal.app, "
        + "to paste a command into a shell, or to type `! <command>` for it (a `!` command has no terminal to type a password "
        + "into). A password is typed only into that shell, never into chat: don't ask for one here, and never put one in the command."

    public static let text = """
        [VibeSwitcher · session note] This session runs in VibeSwitcher. When a transaction is needed (a payment, a \
        transfer, a contract call), ask for it with `vs-wallet request …` (on your PATH; `vs-wallet help` lists the fields). \
        It files the request as a card in this session's chat: nothing is sent until the user clicks Send to Wallet Manager there. \
        The Wallet Manager then checks it on its own Mac and the user signs it there with a hardware wallet; its answers come back to you as \
        messages. From an 0x address the card also offers Sign in browser wallet, which works without a Wallet Manager: when \
        none is set up, vs-wallet says so and the browser wallet is the way to sign. vs-wallet never holds or takes keys: never put a key, seed or recovery phrase in a request. \
        \(realTerminal)
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
