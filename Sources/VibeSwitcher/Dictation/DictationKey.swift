import Foundation
import VibeCore

/// An OpenAI key found outside the Keychain that Settings offers to import (never used until you confirm).
struct FoundOpenAIKey: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// `OPENAI_API_KEY` exported in your login shell.
        case shell
        /// The API key Codex keeps in ~/.codex/auth.json (when you signed in to Codex with one, not with ChatGPT).
        case codex

        /// Settings' words for it.
        var name: String {
            switch self {
            case .shell: return "OPENAI_API_KEY in your shell"
            case .codex: return "Codex's API key (~/.codex/auth.json)"
            }
        }
    }

    var source: Source
    /// Held in memory only, until it's imported or Settings forgets it.
    var key: String
}

/// Dictation's OpenAI key: the login Keychain item only (`AppProof.openAIAccount`), never a file, the defaults, a log
/// or the phone. A key in your shell or Codex's auth file is offered for import by Settings, and saved only when you
/// confirm; until then it's never used.
enum DictationKey {
    static let variable = "OPENAI_API_KEY"
    /// Codex's credentials, from the home folder (looked up where it's read: a test's is its scratch home).
    static let codexAuthInHome = ".codex/auth.json"
    /// Bigger than this, it's not Codex's auth file: not read.
    static let fileLimit = 64 * 1024

    /// A key to offer: the shell's first, then Codex's. `shell` reads the login shell's variable, `codexAuth` the
    /// auth file's text; tests give stand-ins. Blocks (a shell starts): never on the main thread.
    static func find(shell: () -> String?, codexAuth: () -> String?) -> FoundOpenAIKey? {
        if let key = usable(shell()) { return FoundOpenAIKey(source: .shell, key: key) }
        if let key = codexAuth().flatMap(apiKey(inCodexAuth:)) { return FoundOpenAIKey(source: .codex, key: key) }
        return nil
    }

    /// The app's: the user's login shell, and Codex's auth file in their home.
    static func findLive() -> FoundOpenAIKey? {
        find(shell: {
            if case .found(let value) = LoginShellVariable.read(variable) { return value }
            return nil
        }, codexAuth: {
            BriefingKey.readFile(NSHomeDirectory() + "/" + codexAuthInHome)
        })
    }

    /// The API key in Codex's auth.json (`"OPENAI_API_KEY": "sk-…"`); nil when it holds ChatGPT login tokens instead
    /// (`"OPENAI_API_KEY": null` beside `"tokens"`): those are never taken.
    static func apiKey(inCodexAuth text: String) -> String? {
        guard text.utf8.count <= fileLimit, let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return usable(object[variable] as? String)
    }

    /// A key as OpenAI gives them: `sk-` and printable ASCII without spaces or quotes. A ChatGPT token (a JWT,
    /// `eyJ…`) isn't one.
    static func usable(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), value.hasPrefix("sk-"),
              (20...512).contains(value.count),
              value.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7f && $0 != "\"" && $0 != "'" && $0 != "$" && $0 != "`" })
        else { return nil }
        return value
    }
}
