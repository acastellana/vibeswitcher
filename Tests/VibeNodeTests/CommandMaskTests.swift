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

    /// A flag word with no value after it masks nothing; the word after one is masked whatever it starts with (a value
    /// can start with a dash), and a flag of three dashes is a flag.
    @Test func theWordAfterASecretFlagIsAlwaysMasked() {
        #expect(CommandMask.masked("claude --token") == "claude --token")
        #expect(CommandMask.masked("'claude' '--api-key' '-dash-first-secret' 'opus'") == "'claude' '--api-key' '•••' 'opus'")
        #expect(CommandMask.masked("tool ---password hunter2 --verbose") == "tool ---password ••• --verbose")
        #expect(CommandMask.masked("tool ---token=hunter2") == "tool ---token=•••")
    }

    /// `user:pass` anywhere, `--user`/`-u`, a header holding a credential, and a short flag's attached value.
    @Test func credentialsInTheirOtherShapesAreMasked() {
        let cases: [(String, String)] = [
            ("curl -u bob:hunter2 https://example.com", "curl -u ••• https://example.com"),
            ("curl --user bob https://example.com", "curl --user ••• https://example.com"),
            ("curl --user=bob:hunter2 x", "curl --user=••• x"),
            ("curl -ubob:hunter2 x", "curl -u••• x"),
            ("mysql -phunter2 -h db", "mysql -p••• -h db"),
            ("tool -kSECRETKEY", "tool -k•••"),
            ("tool bob:hunter2", "tool bob:•••"),
            ("tool 'bob:hunter2'", "tool 'bob:•••'"),
            ("curl -H 'Authorization: Bearer abc123' x", "curl -H 'Authorization: •••' x"),
            ("curl --header 'X-Api-Key: abc123' x", "curl --header 'X-Api-Key: •••' x"),
            ("curl -H 'Accept: text/plain' x", "curl -H 'Accept: text/plain' x"),
            ("curl --header='Cookie: sid=abc123' x", "curl --header='•••' x"),
            ("claude --model opus -c", "claude --model opus -c"),
        ]
        for (command, expected) in cases {
            let masked = CommandMask.masked(command)
            #expect(masked == expected, "\(command) → \(masked)")
            for secret in ["hunter2", "abc123", "SECRETKEY"] where command.contains(secret) {
                #expect(!masked.contains(secret), "\(command) → \(masked)")
            }
        }
    }

    /// Round 2 of the review: a short flag's attached header, a user:pass value in any env word, and a scheme-less
    /// `user:pass@host`.
    @Test func attachedHeadersEnvCredentialsAndSchemelessHostsAreMasked() {
        let cases: [(String, String)] = [
            ("curl -HAuthorization:Bearer-abc123 x", "curl -HAuthorization:••• x"),
            ("curl -H'X-Api-Key: abc123' https://example.com/v1", "curl -H'X-Api-Key: •••' https://example.com/v1"),
            ("curl -H'Accept: text/plain' x", "curl -H'Accept: text/plain' x"),
            // A credential header attached with nothing after its colon, or no colon: the next word is its value.
            ("curl -HAuthorization: Bearer-abc123 x", "curl -HAuthorization: ••• x"),
            ("curl -HX-Api-Key abc123 x", "curl -HX-Api-Key ••• x"),
            ("curl '-HAuthorization:' 'Bearer abc123' x", "curl '-HAuthorization:' '•••' x"),
            ("curl -uuser:hunter2 x", "curl -u••• x"),
            ("DATABASE=bob:hunter2 tool", "DATABASE=bob:••• tool"),
            ("DATABASE_URL=bob:hunter2@db:5432 tool", "DATABASE_URL=bob:•••@db:5432 tool"),
            ("psql postgres:hunter2@db.internal/app", "psql postgres:•••@db.internal/app"),
            ("tool --to bob:hunter2@host", "tool --to bob:•••@host"),
            ("git clone git@github.com:org/repo", "git clone git@github.com:org/repo"),
            ("LANG=en_US.UTF-8 tool", "LANG=en_US.UTF-8 tool"),
        ]
        for (command, expected) in cases {
            let masked = CommandMask.masked(command)
            #expect(masked == expected, "\(command) → \(masked)")
            for secret in ["hunter2", "abc123"] where command.contains(secret) { #expect(!masked.contains(secret), "\(command) → \(masked)") }
        }
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
