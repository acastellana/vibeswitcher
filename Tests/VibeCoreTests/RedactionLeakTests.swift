import Foundation
import Testing
@testable import VibeCore

/// F-R1: every credential shape that leaked in the security review (docs/eval/security.md, the Redaction
/// table), and the masking staying fast on hostile input. Fake tokens are assembled at runtime so secret
/// scanners don't flag this file.
struct RedactionLeakTests {
    let letters = "AbCdEfGhIjKlMnOpQrStUvWxYz"
    func fake(_ prefix: String, _ count: Int) -> String {
        prefix + String(String(repeating: letters + "0123456789", count: 3).prefix(count))
    }

    func expectMasked(_ input: String, hiding secret: String, as expected: String? = nil,
                      sourceLocation: SourceLocation = #_sourceLocation) {
        let masked = Redaction.secrets(in: input)
        #expect(!masked.contains(secret), "\(input) → \(masked)", sourceLocation: sourceLocation)
        if let expected { #expect(masked == expected, sourceLocation: sourceLocation) }
    }

    @Test func tokenShapesAreMaskedWhereverTheyAppear() {
        let stripe = fake("sk" + "_live_", 24)
        expectMasked("STRIPE=\(stripe)", hiding: stripe)
        expectMasked("key \(stripe) here", hiding: stripe, as: "key ••• here")
        let restricted = fake("rk" + "_live_", 24)
        expectMasked("use \(restricted)", hiding: restricted, as: "use •••")
        let gitlab = "glpat-" + "AbCdEfGhIjKlMnOpQrSt"
        expectMasked("git push https://oauth2@gitlab.com # \(gitlab)", hiding: gitlab)
        let google = "AIza" + "SyA-EXAMPLE-0123456789abcdefghijkl"
        expectMasked("maps?key=\(google)&q=x", hiding: google)
        let npm = fake("npm" + "_", 36)
        expectMasked("echo \(npm)", hiding: npm, as: "echo •••")
        let pypi = "pypi-" + "AgEIcHlwaS5vcmcCJGFiY2RlZmdoLWlqa2wtbW5vcC1xcnN0"
        expectMasked("twine upload -p \(pypi)", hiding: pypi)
        let huggingFace = fake("hf" + "_", 34)
        expectMasked("HF said \(huggingFace).", hiding: huggingFace, as: "HF said •••.")
        let sendGrid = "SG" + ".AbCdEfGhIjKlMnOpQr.StUvWxYz0123456789abcd"
        expectMasked("mail \(sendGrid)", hiding: "StUvWxYz0123456789abcd", as: "mail •••")
        let age = "AGE-SECRET-KEY-" + "1QQPQZRG3Y5Z4P8VVAA2KV4Y3D9X5Z7C6M0N2WQ8E"
        expectMasked("identity: \(age)", hiding: age)
    }

    @Test func webhookURLsAreMasked() {
        let slack = "https://hooks.slack.com/services/" + "T0123ABCD/B0456EFGH/" + "AbCdEfGhIjKlMnOpQrStUvWx"
        expectMasked("curl -X POST \(slack)", hiding: "AbCdEfGhIjKlMnOpQrStUvWx", as: "curl -X POST https://•••")
        let discord = "https://discord.com/api/webhooks/" + "123456789012345678/" + "AbCdEf-GhIjKl_MnOpQrStUvWxYz0123456789"
        expectMasked("hook: \(discord)", hiding: "AbCdEf-GhIjKl_MnOpQrStUvWxYz0123456789")
    }

    @Test func aBareAWSSecretKeyIsMaskedButHashesAreNot() {
        let secret = "wJalrXUtnFEMI/K7MDENG/" + "bPxRfiCYEXAMPLEKEY"
        expectMasked("aws_secret = x\n\(secret)\n", hiding: secret)
        expectMasked("secret is \(secret).", hiding: secret, as: "secret is •••.")
        // A commit hash (one case only) and a longer base64 run are not secrets.
        let hash = "3f786850e387550fdab836ed7e6dc881de23001b"
        #expect(Redaction.secrets(in: "commit \(hash)") == "commit \(hash)")
        let longer = secret + "A"
        #expect(Redaction.secrets(in: "blob \(longer)") == "blob \(longer)")
    }

    @Test func headersAreMasked() {
        expectMasked("Cookie: session=s3cr3tvalue; csrf=abc", hiding: "s3cr3tvalue", as: "Cookie: •••")
        expectMasked(#"curl -H "Cookie: session=s3cr3tvalue" https://x"#, hiding: "s3cr3tvalue",
                     as: #"curl -H "Cookie: •••" https://x"#)
        expectMasked("Set-Cookie: sid=s3cr3tvalue; HttpOnly", hiding: "s3cr3tvalue", as: "Set-Cookie: •••")
        expectMasked("X-Auth: Bearer abc123def456", hiding: "abc123def456", as: "X-Auth: Bearer •••")
        expectMasked(#"{"authorization": "Bearer abc123def456"}"#, hiding: "abc123def456")
    }

    @Test func passwordsInCommandLinesAreMasked() {
        expectMasked("curl -u admin:hunter2 https://api.example.com", hiding: "hunter2",
                     as: "curl -u admin:••• https://api.example.com")
        expectMasked("curl --user admin:hunter2 https://x", hiding: "hunter2", as: "curl --user admin:••• https://x")
        expectMasked("mysql -u root -phunter2 shop", hiding: "hunter2", as: "mysql -u root -p••• shop")
        expectMasked("sshpass -p hunter2 ssh me@host", hiding: "hunter2", as: "sshpass -p ••• ssh me@host")
        expectMasked("tool --pass hunter2 --verbose", hiding: "hunter2", as: "tool --pass ••• --verbose")
        // `mysql -p name` asks for the password and opens database `name`: nothing to hide.
        #expect(Redaction.secrets(in: "mysql -u root -p shop") == "mysql -u root -p shop")
    }

    @Test func moreSecretNamesAreMasked() {
        expectMasked("MYSQL_PWD=hunter2 mysql", hiding: "hunter2", as: "MYSQL_PWD=••• mysql")
        expectMasked("Server=db;Uid=sa;pwd=hunter2;", hiding: "hunter2")
        expectMasked("passphrase=correct-horse", hiding: "correct-horse", as: "passphrase=•••")
        expectMasked("ANTHROPIC_AUTH=abc123xyz claude", hiding: "abc123xyz", as: "ANTHROPIC_AUTH=••• claude")
        expectMasked(#"{"auth": "dXNlcjpwYXNz"}"#, hiding: "dXNlcjpwYXNz", as: #"{"auth": "•••"}"#)
        expectMasked("    client-key-data: LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQo=", hiding: "LS0tLS1CRUdJTiBSU0Eg",
                     as: "    client-key-data: •••")
        expectMasked("token=\"unterminated value", hiding: "unterminated", as: "token=\"•••\" value")
    }

    @Test func aTokenSoftWrappedAcrossTwoRowsIsMasked() {
        // The terminal wrapped it at the screen's width: neither half looks like a token on its own.
        let token = fake("ghp" + "_", 36)
        let screen = "ghp_AbCdEfGhIjKlMnOp\nQrStUvWxYz01"
        expectMasked(screen, hiding: "AbCdEfGhIjKlMnOp", as: "•••\n•••")
        let width = 40
        let line = "$ export TOKEN_FOR_CI=" + token
        let rows = stride(from: 0, to: line.count, by: width).map {
            String(line.dropFirst($0).prefix(width))
        }
        let wrapped = (["$ ls", "README.md"] + rows + ["$ "]).joined(separator: "\n")
        let masked = Redaction.secrets(in: wrapped)
        for piece in [String(token.dropFirst(4).prefix(14)), String(token.suffix(14))] {
            #expect(!masked.contains(piece), "\(masked)")
        }
        #expect(masked.hasPrefix("$ ls\nREADME.md\n$ export TOKEN_FOR_CI="))
        #expect(masked.hasSuffix("\n$ "))
    }

    @Test func ordinaryTextStaysAsItIs() {
        for text in ["Bearer tokens expire after an hour", "author: Me", "PWD=/Users/me/dev", "OLDPWD=/tmp",
                     "the my-token value", "task-abcdefghijklmnopqrstuvwxyz", "mkdir -p build && cd build",
                     "MSG.someLongVariableName.anotherLongerName", "git log --oneline -n 3",
                     "docker run -it --rm alpine", "curl -s https://example.com/path", "an authority: none"] {
            #expect(Redaction.secrets(in: text) == text)
        }
    }
}

/// 200 KB of input built to make the rules work hardest (long runs, repeated prefixes, unterminated quotes and
/// keys, floods of each rule's trigger, a letter and every word starting with it) is masked in at most 10 times what
/// the same size of ordinary output takes in the same run (about 1.2 times at worst, and about 12 ms, unoptimised).
/// A rule gone quadratic on 200 KB takes thousands of times as long.
@Suite(.serialized) struct RedactionSpeedTests {
    static let size = 200_000

    static func flood(_ unit: String) -> String {
        String(String(repeating: unit, count: size / unit.count + 1).prefix(size))
    }

    static let inputs: [String] = [
        "a", "A", " ", "\n", "a\n", "a-", "--", "=", ":", "\"", "hello world ", " -a-a-a-a-a", " -",
        "token", "token=", "token=a ", "token_", " --token", "--password ", " -pass ", "password", "passphrase",
        "api_key=", "access_key ", "auth_", "_pwd", "pwd=a ", "key-data:", "credentials", "cookie", "Cookie: ",
        "token: '", "token=\"a\\\"", "secret", "authorization: ", "bearer ", "Bearer aaaaaaaaaaaaaaaaaaaa1 ",
        " -u a", " -u a:b", "--user=", "mysql ", "mysql -pa ", "sshpass ", "sshpass -p a ", "://a:", "://a:b@",
        "-----BEGIN ", "-----END ", "-----BEGIN RSA PRIVATE KEY-----", "sk-", "sk_live_", "ghp_", "github_pat_",
        "glpat-", "xoxb-", "AKIA", "AIza", "AGE-SECRET-KEY-1", "npm_", "pypi-AgE", "hf_", "SG.", "eyJ",
        "eyJaaaaaaaa.", "hooks.slack.com/services/", "discord.com/api/webhooks/1/", "Aa1/",
        String(repeating: "a", count: 39) + "A1 ", "ghp_" + String(repeating: "a", count: 36) + "\n",
        String(repeating: "a", count: 40) + "\n", "ppasswordprivatepwdpk-pypi-", "eyJ-", "SG.a", "AKIAAKIAAKIAAKIAAKIA",
        "p password private pwd pk- pypi- ", "s secret sk- sshpass ", "a api auth access age- aiza akia ",
    ].map(flood) + [
        "token=\"" + flood("a"), "--" + flood("a"), "-----BEGIN RSA PRIVATE KEY-----\n" + flood("A"),
        flood("a-") + " token=abc", "Cookie: " + flood("a"), flood(allWords),
    ] + letterFloods

    /// One letter, and every secret word starting with it: 200 KB of `p` around password, private_key, pwd, pk-
    /// and pypi-, and so on (each rule starting with that letter has its word, and a flood of its first letter).
    static let letterFloods: [String] = [
        ("p", "password private_key pwd pk- pypi-AgE passphrase"), ("a", "api_key access_key auth authorization: AKIA AIza AGE-SECRET-KEY-1"),
        ("s", "secret sk- sshpass SG. sk_live_"), ("t", "token token="), ("c", "cookie cookie: credential"),
        ("k", "key-data k- k_live_"), ("m", "mysql mariadb"), ("g", "ghp_ github_pat_ glpat-"), ("h", "hf_ hooks.slack.com/"),
    ].flatMap { letter, words in
        let fill = String(repeating: letter, count: size - words.count - 1)
        return [fill + " " + words, words + " " + fill, words + fill]
    } + [allWords + String(repeating: "a", count: size - allWords.count)]

    static let allWords = "password private_key pwd pk- pypi-AgE api_key access_key auth authorization: AKIA AIza secret sk- "
        + "sshpass SG. token cookie: credential key-data mysql mariadb -u --user :// -----BEGIN -----END bearer ghp_ "
        + "github_pat_ glpat- hf_ hooks.slack.com/ xoxb- npm_ eyJ discord.com/api/webhooks/ "

    /// The same size of ordinary terminal output (a listing, a build, prose): what masking costs when nothing in it
    /// needs it, measured beside each hostile input so a busy machine slows both alike.
    static let benign = flood("drwxr-xr-x  12 me  staff   384 Oct 17 21:27 Sources\nCompiling VibeCore Redaction.swift\n"
        + "Build complete! The quick brown fox jumps over the lazy dog.\n")

    /// What masking `benign` and `hostile` costs: the CPU time of this thread, which a busy machine keeping it
    /// waiting doesn't add to, and the best of five runs taken in turns, so a slower core or a stall hits both alike.
    static func costs(benign: String, hostile: String) -> (benign: TimeInterval, hostile: TimeInterval) {
        func cost(_ input: String) -> TimeInterval {
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            _ = Redaction.secrets(in: input)
            return TimeInterval(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e9
        }
        var best = (benign: TimeInterval.infinity, hostile: TimeInterval.infinity)
        for _ in 0..<5 {
            best.benign = min(best.benign, cost(benign))
            best.hostile = min(best.hostile, cost(hostile))
        }
        return best
    }

    @Test(arguments: inputs.indices) func hostileInputIsMaskedQuickly(_ index: Int) {
        let input = Self.inputs[index]
        let (benign, hostile) = Self.costs(benign: Self.benign, hostile: input)
        // One line per case, to compare runs.
        print("RedactionSpeed #\(index) \(input.prefix(24).debugDescription) \(String(format: "%.1f", hostile * 1000)) ms, "
            + "benign \(String(format: "%.1f", benign * 1000)) ms, \(String(format: "%.1f", hostile / benign))x")
        #expect(hostile <= benign * 10, "\(input.prefix(24).debugDescription): \(Int(hostile * 1000)) ms, benign \(Int(benign * 1000)) ms")
    }
}
