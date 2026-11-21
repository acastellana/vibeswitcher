import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// A command line as a page sees it (`CommandMask`, the security review of 2026-11-21): a value after a secret-ish
/// flag, quoted or not (the node's own `'claude' '--api-key' '…'` form too), a secret-ish environment word's value, a
/// URL's secret-ish query value and its password are masked; the rest is as written. A session's `command` and a
/// launch preset's sent to a page are masked so; a terminal's confirmation shows the preset whole.
struct CommandMaskTests {
    @Test func secretsAfterFlagsInEnvWordsAndInURLsAreMasked() {
        let cases: [(String, String)] = [
            ("'claude' '--api-key' 'hunter2hunter2'", "'claude' '--api-key' '•••'"),
            ("claude --token hunter2 --model opus", "claude --token ••• --model opus"),
            ("claude --password=hunter2", "claude --password=•••"),
            ("claude '--password=hunter2'", "claude '--password=•••'"),
            ("tool --auth user:pass --verbose", "tool --auth ••• --verbose"),
            ("tool --key 0123456789abcdef", "tool --key ••• "),
            ("MY_SECRET=abc claude", "MY_SECRET=••• claude"),
            ("GH_TOKEN='abc def' DB_PASSWORD=\"x y\" claude", "GH_TOKEN='•••' DB_PASSWORD=\"•••\" claude"),
            ("curl 'https://api.example.com/v1?key=abc123&page=2'", "curl 'https://api.example.com/v1?key=•••&page=2'"),
            // Redaction and PushText.scrub take these whole (the token to the word's end, the URL's user and password).
            ("curl https://example.com/x?access_token=abc123#top", "curl https://example.com/x?access_token=•••"),
            ("git clone https://user:hunter2@example.com/repo", "git clone https://example.com/repo"),
            ("claude --model opus --verbose", "claude --model opus --verbose"),
            ("HOME=/home/u claude", "HOME=/home/u claude"),
            ("", ""),
        ]
        for (command, expected) in cases {
            let masked = CommandMask.masked(command)
            if command == "tool --key 0123456789abcdef" {
                #expect(!masked.contains("0123456789abcdef") && masked.hasPrefix("tool --key "), "\(masked)")
            } else {
                #expect(masked == expected, "\(command) → \(masked)")
            }
            for secret in ["hunter2", "abc123", "0123456789abcdef", "user:pass"] where command.contains(secret) {
                #expect(!masked.contains(secret), "\(command) → \(masked)")
            }
        }
    }

    /// A flag word with no value after it masks nothing; another flag after one isn't taken for its value.
    @Test func aFlagWithNoValueMasksNothing() {
        #expect(CommandMask.masked("claude --token") == "claude --token")
        #expect(CommandMask.masked("'claude' '--api-key' '--model' 'opus'") == "'claude' '--api-key' '--model' 'opus'")
    }

    @Test func aSessionsCommandAndAPresetsSentToAPageAreMasked() throws {
        let session = Session(tty: "pts/4", agent: .claude, pid: 1, startedAt: Date(), cwd: nil, project: "p", task: nil, status: .idle,
                              statusSince: Date(), detail: nil, hasHooks: false, inTerminalApp: false)
        let host = HostSession(id: UUID(), tty: "pts/4", childPID: 2, cwd: "/w", command: "'claude' '--api-key' 'hunter2hunter2'", label: "Claude",
                               agent: "claude", title: "", startedAt: Date(), cols: 80, rows: 24, exit: nil)
        #expect(session.liveValue(prompt: nil, draft: nil, host: host)["command"] == .string("'claude' '--api-key' '•••'"))

        let preset = LaunchPreset(name: "Keyed", kind: .claude, command: "claude --token hunter2", env: [:])
        let listed = SessionPresets.Listed(preset: preset, project: false, isDefault: false, refusal: nil)
        #expect(SessionPresets.value(listed)["command"] == .string("claude --token •••"))
        #expect(SessionPresets.value(listed, values: true)["command"] == .string("claude --token hunter2"), "a terminal's confirmation shows it whole")
    }
}
