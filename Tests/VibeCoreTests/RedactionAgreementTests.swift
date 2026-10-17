import Foundation
import Testing
@testable import VibeCore

/// The hand-written rules mask exactly what the regular expressions they replaced did (`RedactionReference`),
/// on every input the other Redaction tests use and on generated input built from the rules' own words.
struct RedactionAgreementTests {
    /// A fixed-seed generator, so a failure is the same on every run.
    struct SplitMix {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    /// Pieces of every rule (words in several cases, separators, quotes, escapes, runs of token characters)
    /// and of what ends them (spaces, newlines, punctuation, letters outside ASCII, a combining mark, a format
    /// character, an emoji). Left out: ß, which ICU's `(?i)` folds to "ss" and the hand-written rules don't.
    static let pieces: [String] = [
        "token", "TOKEN", "Token", "secret", "SECRET", "pass", "password", "PASSWORD", "passwd", "passphrase", "pwd",
        "PWD", "Pwd", "_pwd", "_PWD", "OLDPWD", "api", "api_key", "api-key", "apikey", "access_key", "AccessKey",
        "private_key", "private-key", "credential", "credentials", "cookie", "Cookie", "cookie:", "Set-Cookie:",
        "key-data", "key_data", "auth", "auth_", "AUTH_TOKEN", "author", "authorization:", "Authorization:",
        "bearer", "Bearer", "basic", "Basic", "to\u{212A}en", "\u{17F}ecret",
        "=", ":", " = ", ": ", "\"", "'", "\\", "\\\"", "&", ",", ";", "|", "<", ">", "@", "/", ".", "-", "_", "--",
        " -", " --", "-p", " -p", " -u", "--user", "--user=", "--token", "--api-key=", "--pass", " --my-secret-file",
        "mysql", "mysqldump", "mysqladmin", "mariadb", "sshpass", "curl", "://", "https://", "user:pw@", "a:b@",
        "-----BEGIN ", "-----END ", "RSA PRIVATE KEY-----", "PRIVATE KEY-----", "PGP PRIVATE KEY BLOCK-----",
        "-----BEGIN RSA PRIVATE KEY-----", "-----END RSA PRIVATE KEY-----", "-----BEGIN PGP PRIVATE KEY BLOCK-----",
        "sk-", "pk-", "rk-", "task-", "sk_live_", "rk_test_", "AKIA", "AIza", "AGE-SECRET-KEY-1", "ghp_", "gho_",
        "github_pat_", "glpat-", "hf_", "hooks.slack.com/services/", "hooks.slack.com/workflows/", "xoxb-",
        "xoxp-", "npm_", "pypi-AgE", "SG.", "eyJ", "discord.com/api/webhooks/", "discordapp.com/api/webhooks/",
        "AbCdEfGhIjKlMnOp", "QRSTUVWXYZ012345", "abcdefgh", "0123456789", "a1B2", "aB3/+", "x", "Z", "9",
        " ", "  ", "\t", "\n", "\r\n", "\u{A0}", "\u{2028}", "é", "\u{301}", "\u{AD}", "日本", "😀",
    ]

    func expectAgreement(_ input: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let expected = RedactionReference.secrets(in: input), actual = Redaction.secrets(in: input)
        #expect(actual == expected, "\(input.debugDescription)\n  expected \(expected.debugDescription)\n  got      \(actual.debugDescription)",
                sourceLocation: sourceLocation)
    }

    @Test func agreesOnGeneratedInput() {
        var random = SplitMix(state: 0x5EC2E7)
        for _ in 0..<6000 {
            var text = ""
            for _ in 0..<(1 + random.below(24)) { text += Self.pieces[random.below(Self.pieces.count)] }
            expectAgreement(text)
        }
    }

    @Test func agreesOnGeneratedTokens() {
        // Long runs of token characters after each shape's prefix, around the minimum lengths.
        var random = SplitMix(state: 0x70CE45)
        let alphabet = Array("abcXYZ019_-/+.=")
        let prefixes = ["sk-", "sk_live_", "AKIA", "AIza", "AGE-SECRET-KEY-1", "ghp_", "github_pat_", "glpat-", "hf_",
                        "xoxb-", "npm_", "pypi-AgE", "SG.", "eyJ", "Bearer ", "token=", " --password ", "x ", "\n"]
        for _ in 0..<4000 {
            var text = random.below(2) == 0 ? "" : Self.pieces[random.below(Self.pieces.count)]
            for _ in 0..<(1 + random.below(3)) {
                text += prefixes[random.below(prefixes.count)]
                for _ in 0..<random.below(48) { text.append(alphabet[random.below(alphabet.count)]) }
            }
            expectAgreement(text)
        }
    }

    @Test func agreesOnSoftWrappedScreens() {
        // Rows as wide as the widest, so tokens cross row ends.
        var random = SplitMix(state: 0x3C2EE7)
        for _ in 0..<1500 {
            var line = ""
            for _ in 0..<(2 + random.below(12)) { line += Self.pieces[random.below(Self.pieces.count)] }
            line += "ghp_" + String(repeating: "aB3", count: 4 + random.below(12))
            let width = 16 + random.below(24)
            var rows: [String] = []
            var rest = Substring(line)
            while !rest.isEmpty { rows.append(String(rest.prefix(width))); rest = rest.dropFirst(width) }
            expectAgreement((["$ ls"] + rows + ["$ "]).joined(separator: "\n"))
        }
    }

    @Test func agreesOnTheOtherTestsInputs() {
        let letters = "AbCdEfGhIjKlMnOpQrStUvWxYz"
        func fake(_ prefix: String, _ count: Int) -> String {
            prefix + String(String(repeating: letters + "0123456789", count: 3).prefix(count))
        }
        let inputs = [
            "STRIPE=\(fake("sk" + "_live_", 24))", "key \(fake("sk" + "_live_", 24)) here", "use \(fake("rk" + "_live_", 24))",
            "git push https://oauth2@gitlab.com # glpat-AbCdEfGhIjKlMnOpQrSt", "maps?key=AIzaSyA-EXAMPLE-0123456789abcdefghijkl&q=x",
            "echo \(fake("npm" + "_", 36))", "twine upload -p pypi-AgEIcHlwaS5vcmcCJGFiY2RlZmdoLWlqa2wtbW5vcC1xcnN0",
            "HF said \(fake("hf" + "_", 34)).", "mail SG.AbCdEfGhIjKlMnOpQr.StUvWxYz0123456789abcd",
            "identity: AGE-SECRET-KEY-1QQPQZRG3Y5Z4P8VVAA2KV4Y3D9X5Z7C6M0N2WQ8E",
            "curl -X POST https://hooks.slack.com/services/T0123ABCD/B0456EFGH/AbCdEfGhIjKlMnOpQrStUvWx",
            "hook: https://discord.com/api/webhooks/123456789012345678/AbCdEf-GhIjKl_MnOpQrStUvWxYz0123456789",
            "aws_secret = x\nwJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\n", "secret is wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY.",
            "commit 3f786850e387550fdab836ed7e6dc881de23001b", "blob wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEYA",
            "Cookie: session=s3cr3tvalue; csrf=abc", #"curl -H "Cookie: session=s3cr3tvalue" https://x"#,
            "Set-Cookie: sid=s3cr3tvalue; HttpOnly", "X-Auth: Bearer abc123def456", #"{"authorization": "Bearer abc123def456"}"#,
            "curl -u admin:hunter2 https://api.example.com", "curl --user admin:hunter2 https://x", "mysql -u root -phunter2 shop",
            "sshpass -p hunter2 ssh me@host", "tool --pass hunter2 --verbose", "mysql -u root -p shop", "MYSQL_PWD=hunter2 mysql",
            "Server=db;Uid=sa;pwd=hunter2;", "passphrase=correct-horse", "ANTHROPIC_AUTH=abc123xyz claude",
            #"{"auth": "dXNlcjpwYXNz"}"#, "    client-key-data: LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQo=",
            "token=\"unterminated value", "ghp_AbCdEfGhIjKlMnOp\nQrStUvWxYz01", #"password="two words here" next"#,
            #"{"api_key": "abc def", "user": "me"}"#, "secret='a b'", "TOKEN=abc123 rest", #"password="a\"bcd" next"#,
            "Bearer tokens expire after an hour", "author: Me", "PWD=/Users/me/dev", "OLDPWD=/tmp", "the my-token value",
            "task-abcdefghijklmnopqrstuvwxyz", "mkdir -p build && cd build", "MSG.someLongVariableName.anotherLongerName",
            "git log --oneline -n 3", "docker run -it --rm alpine", "curl -s https://example.com/path", "an authority: none",
            "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ\n-----END OPENSSH PRIVATE KEY-----\nafter",
            "$ cat id_ed25519\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ",
            "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ\n-----END OPENSSH PRIVATE KEY-----\n$ ls",
            "-----BEGIN PGP PRIVATE KEY BLOCK-----\nlQOYBF0Ar\n-----END PGP PRIVATE KEY BLOCK-----",
        ]
        for input in inputs { expectAgreement(input) }
        // The 200 KB inputs built to make the rules work hardest, but two: one below, and 200 KB of `eyJ-`, on which
        // the expressions take minutes (each start reads to the end looking for a dot); 2 KB of it here instead.
        for input in RedactionSpeedTests.inputs where !input.hasPrefix("token=\"aaaa") && !input.hasPrefix("eyJ-eyJ-") {
            expectAgreement(input)
        }
        expectAgreement(String(repeating: "eyJ-", count: 500))
        expectAgreement(String(repeating: "eyJ-", count: 500) + ".abcdefgh.abcdefgh")
    }

    @Test func aHugeUnterminatedQuotedValueIsMaskedWhereTheExpressionGaveUp() {
        // ICU stops (its backtracking limit) on 200 KB of an unterminated quoted value and masked nothing; the
        // rule as written masks it like a short one (`token="•••" value`).
        let input = "token=\"" + String(repeating: "a", count: 200_000)
        #expect(RedactionReference.secrets(in: input) == input)
        #expect(Redaction.secrets(in: input) == "token=\"•••\"")
    }
}
