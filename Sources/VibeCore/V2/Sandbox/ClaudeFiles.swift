import Foundation

/// What Claude Code finds of its config inside a box (the session sandbox plan's "The agent itself", as SB0 measured
/// Claude Code 2.1.326: the inventory's "The session sandbox, measured"). The config folder (`~/.claude`) is the
/// session's own; the user's entries that say how the agent behaves are bound into it read-only, so a session can't
/// change what the next one loads; the transcript's folder is the real one, but for the memory in it (`memory`), which
/// is read-only for the same reason; the login is read-only (SB-D8); everything else Claude Code writes there starts
/// empty and goes with the box. `~/.claude.json` is a seeded copy in the session's own home, since Claude Code
/// rewrites it by a rename beside it (six times in one turn, measured), made from an allow-list of the account's file
/// (`configKeys`).
///
/// A new Claude Code version changes these lists and their test (`SandboxPlannerTests`), nothing else.
public enum ClaudeFiles {
    /// The config folder's entries bound read-only from the user's, each where it exists.
    public static let readOnlyEntries = ["settings.json", "settings.local.json", "CLAUDE.md", "skills", "agents", "commands",
                                         "plugins", "keybindings.json", "statusline.sh", "policy-limits.json",
                                         "remote-settings.json", "output-styles"]

    /// What Claude Code writes in its config folder in a box, measured: each the session's own, empty at start.
    public static let ownEntries = ["backups", "debug", "history.jsonl", "mcp-needs-auth-cache.json", "projects", "session-env",
                                    "sessions", "shell-snapshots", "jobs", "file-history", "paste-cache", "cache", "tasks",
                                    "teams", "todos", "state", "statsig", "ide"]

    /// Claude Code's memory, a folder in the transcripts' one (`projects/<folder>/memory/`, its index `MEMORY.md`):
    /// what a session saves there, every later session of that project loads as instructions, the user's and the lead's
    /// outside any box among them. Read-only in a box, there or not (the review of 2026-11-19): a boxed session reads
    /// what is there and saves nothing.
    public static let memory = "memory"

    /// The login, read-only in slices 1 to 3 (SB-D8), never copied.
    public static let login = ".credentials.json"

    /// The folder of `cwd`'s transcripts under the config folder's `projects/`: Claude Code's own name for it, every
    /// character but a letter or a digit made `-` (SB0: `/tmp/sb0/worktree` is `-tmp-sb0-worktree`).
    public static func projectFolder(cwd: String) -> String {
        String(cwd.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)) ? Character(scalar) : "-"
        })
    }

    /// The keys of `~/.claude.json` the box's copy takes, each only with a value of the kind named: who the user is
    /// (an anonymous id) and what Claude Code has already shown them, so it starts with no onboarding, release notes or
    /// migration (the keys of the test login's file, SB0). Nothing else is copied: not the user's other projects, not
    /// tool servers, not caches, not a key or token, nor whatever a later version adds.
    public static let configKeys: [String: ConfigValue] = [
        "userID": .text, "hasCompletedOnboarding": .flag, "lastOnboardingVersion": .text, "lastReleaseNotesSeen": .text,
        "installMethod": .text, "migrationVersion": .number, "opusProMigrationComplete": .flag,
        "sonnet1m45MigrationComplete": .flag, "hasSeenAutoDefaultNotice": .flag, "hasSeenAutoModeEntryWarning": .flag,
        "hasResetAutoModeOptInForDefaultOffer": .flag,
    ]

    /// The account's description (`oauthAccount`), taken only with the login (`agentLogin`) and only these fields of it:
    /// which account and organization it is, never a token (the file holds none there; the login is
    /// `.credentials.json`).
    public static let accountKey = "oauthAccount"
    public static let accountFields: [String: ConfigValue] = [
        "accountUuid": .text, "emailAddress": .text, "displayName": .text, "organizationUuid": .text, "organizationName": .text,
        "organizationRole": .text, "organizationType": .text, "workspaceRole": .text, "billingType": .text,
    ]

    /// The kind of value a copied key may hold; any other is dropped.
    public enum ConfigValue: Sendable {
        case text, flag, number
    }

    /// One value of the account's file, as JSON wrote it: a JSON `true` is a flag and never a number, `1` a number and
    /// never a flag (JSONDecoder's own rule).
    enum Scalar: Decodable {
        case text(String), flag(Bool), number(Double), other

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let flag = try? container.decode(Bool.self) {
                self = .flag(flag)
            } else if let number = try? container.decode(Double.self) {
                self = .number(number)
            } else if let text = try? container.decode(String.self) {
                self = .text(text)
            } else {
                self = .other
            }
        }

        /// The value for JSONSerialization when it is of `kind`; nil otherwise.
        func value(as kind: ConfigValue) -> Any? {
            switch (self, kind) {
            case (.text(let text), .text): return text
            case (.flag(let flag), .flag): return flag
            case (.number(let number), .number): return number.rounded() == number && abs(number) < 1e15 ? Int(number) : number
            default: return nil
            }
        }
    }

    /// An object of the account's file: its keys, each a scalar or not.
    struct Object: Decodable {
        var values: [String: Scalar] = [:]
        var objects: [String: [String: Scalar]] = [:]

        init() {}

        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            for key in container.allKeys {
                if let nested = try? container.decode([String: Scalar].self, forKey: key) {
                    objects[key.stringValue] = nested
                } else if let scalar = try? container.decode(Scalar.self, forKey: key) {
                    values[key.stringValue] = scalar
                }
            }
        }
    }

    /// The seeded `~/.claude.json` for a session in `cwd`: from the account's file, the keys `configKeys` allows (and,
    /// with the login, `accountFields` of `oauthAccount`), each with a value of its kind; then one project, `cwd`,
    /// trusted and onboarded, which spares the trust question (measured). A file that isn't a JSON object gives that
    /// project alone.
    public static func seededConfig(from data: Data, cwd: String, login: Bool) -> Data {
        let given = (try? JSONDecoder().decode(Object.self, from: data)) ?? Object()
        var object: [String: Any] = [:]
        for (key, kind) in configKeys {
            if let value = given.values[key]?.value(as: kind) { object[key] = value }
        }
        if login, let account = given.objects[accountKey] {
            var kept: [String: Any] = [:]
            for (field, kind) in accountFields {
                if let value = account[field]?.value(as: kind) { kept[field] = value }
            }
            if !kept.isEmpty { object[accountKey] = kept }
        }
        object["projects"] = [cwd: ["hasTrustDialogAccepted": true, "hasCompletedProjectOnboarding": true,
                                    "allowedTools": [String]()] as [String: Any]]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
