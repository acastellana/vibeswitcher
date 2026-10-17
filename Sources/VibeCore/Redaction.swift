import Foundation

/// Masks credentials in text we store or show (commands awaiting approval, tool details, messages):
/// they would otherwise land in notification banners, Notification Center's history and the state files.
///
/// It must stay fast on any input (hooks have a 5 s budget; screens are masked many times a second). Every
/// rule starts at a fixed word or character, never at `^`, `\b` or a lookbehind, which are tried at every
/// position; every repeat that could be retried is bounded or possessive; a rule whose words aren't in the
/// text doesn't run; and replacements refer to one group at most (each reference costs per match). 200 KB of
/// the worst input found takes a few milliseconds (`RedactionSpeedTests`).
public enum Redaction {
    static let mask = "•••"

    struct Rule {
        enum Gate {
            /// The lowercased text contains one of these.
            case words([String])
            /// The text has a run of exactly 40 base64 characters.
            case base64Run
        }

        let regex: NSRegularExpression
        let template: String
        let gate: Gate

        init(_ pattern: String, _ template: String = mask, words: [String]) {
            self.init(pattern, template, gate: .words(words))
        }

        init(_ pattern: String, _ template: String = mask, gate: Gate) {
            regex = try! NSRegularExpression(pattern: pattern)
            self.template = template
            self.gate = gate
        }
    }

    private static let keyLabel = #"[A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----"#

    private static let keys: [Rule] = [
        // Private keys (PEM, PGP), whole: through their END line, or to the end of the text when it's cut off
        // (a key taller than the screen, a truncated tool output)…
        Rule("-----BEGIN " + keyLabel + #"(?:[\s\S]*?-----END "# + keyLabel + #"|[\s\S]*\z)"#, words: ["-----begin "]),
        // …and the rest of one whose start scrolled off the top (after the leading newline, see `secrets`).
        Rule(#"(\A\n)(?:(?!-----BEGIN )[\s\S])*?-----END "# + keyLabel, "$1\(mask)", words: ["-----end "]),
    ]

    /// Token shapes recognisable on their own, wherever they appear. Also looked for across a soft-wrapped
    /// line end (see `maskWrapped`). A lookbehind right after the prefix keeps `task-…` from passing for `sk-…`.
    private static let shapes: [Rule] = [
        // OpenAI, Anthropic, … (sk-…), Stripe (sk_live_…).
        Rule(#"[spr]k(?<![A-Za-z0-9_][spr]k)(?:-[A-Za-z0-9_-]{16,}|_(?:live|test)_[A-Za-z0-9]{10,})"#,
             words: ["sk-", "pk-", "rk-", "_live_", "_test_"]),
        // AWS access key, Google API key, age.
        Rule(#"A(?:KIA[0-9A-Z]{16}\b|Iza[0-9A-Za-z_-]{30,}|GE-SECRET-KEY-1[0-9A-Z]{20,})"#,
             words: ["akia", "aiza", "age-secret-key-1"]),
        // GitHub, GitLab.
        Rule(#"g(?:h[pousr]_[A-Za-z0-9]{20,}|ithub_pat_[A-Za-z0-9_]{20,}|lpat-[A-Za-z0-9_-]{20,})"#,
             words: ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "glpat-"]),
        // Hugging Face; a Slack webhook (whoever has one can post).
        Rule(#"h(?:f_[A-Za-z0-9]{30,}|ooks\.slack\.com/(?:services|workflows|triggers)/[A-Za-z0-9/_-]+)"#,
             words: ["hf_", "hooks.slack.com/"]),
        Rule(#"xox[abposr]-[A-Za-z0-9-]{10,}"#, words: ["xox"]),                                   // Slack
        Rule(#"npm_[A-Za-z0-9]{30,}"#, words: ["npm_"]),
        Rule(#"pypi-AgE[A-Za-z0-9_-]{16,}"#, words: ["pypi-age"]),
        Rule(#"SG\.(?<![A-Za-z0-9_]SG\.)[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"#, words: ["sg."]),  // SendGrid
        Rule(#"eyJ(?<![A-Za-z0-9_]eyJ)[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, words: ["eyj"]),  // JWT
        Rule(#"discord(?:app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+"#, words: ["/api/webhooks/"]),
    ]

    /// NAME=value, NAME: value, "api_key": "value" for names with a secret word in them (GITHUB_TOKEN,
    /// client-key-data, …): a quoted value up to its closing quote (spaces and escaped quotes included), else
    /// up to a space or separator. A scheme word (`Bearer …`) is left to the bearer rule. Matching starts at
    /// the secret word, whatever comes before it: starting at every name character made this quadratic (40 KB
    /// took minutes).
    private static func named(_ word: String, _ pattern: String) -> Rule {
        Rule("(?i)(" + pattern + #"(?![a-z0-9_-])["']?\s{0,4}+[=:]\s*+)(["']?)"#
             + #"(?:(?<=["'])(?:(?!\2)[^\\\n]|\\.)*+\2|(?!(?:bearer|basic|token)\s)[^\s"'&,;]+)"#,
             "$1$2\(mask)$2", words: [word])
    }

    private static let rules: [Rule] = [
        // Cookie headers, whole (`Cookie: session=…; csrf=…`, `Set-Cookie: …`).
        Rule(#"(?i)(cookie:[ \t]*+)[^"'\r\n]+"#, "$1\(mask)", words: ["cookie:"]),
        // Authorization headers: keep the scheme, hide the credential.
        Rule(#"(?i)(authorization:\s*(?:bearer|basic|token)?\s*)[^\s"']+"#, "$1\(mask)", words: ["authorization:"]),
        // A bearer token in any header (`X-Auth: Bearer …`). One that's a plain word is prose ("Bearer tokens").
        Rule(#"(?i)(bearer\s{1,4}+)(?=[A-Za-z]{0,200}+[0-9._~+/=-]|[A-Za-z]{20})[A-Za-z0-9._~+/=-]{8,}"#, "$1\(mask)",
             words: ["bearer"]),
    ]
        // The rest of the name after the secret word: up to 16 more name characters, no hyphen.
        + [
        named("token", #"token[a-z0-9_]{0,16}+"#), named("secret", #"secret[a-z0-9_]{0,16}+"#),
        named("pass", #"pass(?:w(?:or)?d|wd|phrase)[a-z0-9_]{0,16}+"#), named("api", #"api[_-]?key[a-z0-9_]{0,16}+"#),
        named("access", #"access[_-]?key[a-z0-9_]{0,16}+"#), named("private", #"private[_-]?key[a-z0-9_]{0,16}+"#),
        named("credential", #"credentials?[a-z0-9_]{0,16}+"#), named("cookie", #"cookie[a-z0-9_]{0,16}+"#),
        named("key", #"key[_-]data[a-z0-9_]{0,16}+"#),
        // `auth` and `pwd` only at the end of the name (ANTHROPIC_AUTH, MYSQL_PWD; not author or OLDPWD).
        named("auth", #"auth(?:_[a-z0-9_]{0,16}+)?"#), named("pwd", #"(?-i:pwd|Pwd|_(?i:pwd))"#),
        // --password value, --api-key=value, --pass value (flags only: in prose "the token expired" is fine; the
        // secret word starts one of the flag's first five words).
        Rule(#"(?i)(\s--?(?:[a-z0-9]{1,30}+-){0,4}(?:token|secret|passw(?:or)?d|passwd|passphrase|api-?key|cookie|pass(?![a-z]))[a-z0-9-]{0,40}+(?:=|\s++)["']?)[^\s"'<>|&;][^\s"']*"#,
             "$1\(mask)", words: ["token", "secret", "pass", "api", "cookie"]),
        // curl -u user:pass, --user user:pass: keep the user.
        Rule(#"(\s(?:-u\s*+|--user(?:\s++|=))["']?[^\s:"'@/-][^\s:"'@/]*+:)[^\s"']+"#, "$1\(mask)", words: ["-u", "--user"]),
        // mysql -ppassword (attached: `-p name` is a prompt and a database), sshpass -p password: among the
        // command's next eight words (up to the next mysql/sshpass, so floods of them stay linear).
        Rule(#"((?:mysql(?:dump|admin)?|mariadb)\b(?:[ \t]++(?!-p|mysql|mariadb)[^\s|;&]++){0,8}+[ \t]++-p["']?)[^\s"']+"#,
             "$1\(mask)", words: ["mysql", "mariadb"]),
        Rule(#"(sshpass\b(?:[ \t]++(?!-p|sshpass)[^\s|;&]++){0,8}+[ \t]++-p[ \t]*+["']?)[^\s"']+"#, "$1\(mask)",
             words: ["sshpass"]),
        // Credentials inside URLs: scheme://user:pass@host
        Rule(#"(://[^/\s:@]++:)[^@\s/]++@"#, "$1\(mask)@", words: ["://"]),
        // A bare AWS secret key: exactly 40 of base64's characters with upper, lower and a digit (a hex hash
        // has one case only).
        Rule(#"([^A-Za-z0-9/+=])(?=[A-Za-z0-9/+]{40}(?![A-Za-z0-9/+=]))(?=[a-z0-9/+]{0,39}[A-Z])(?=[A-Z0-9/+]{0,39}[a-z])(?=[A-Za-z/+]{0,39}[0-9])[A-Za-z0-9/+]{40}"#,
             "$1\(mask)", gate: .base64Run),
    ] + shapes

    public static func secrets(in text: String) -> String {
        // A leading newline lets rules start at the character before a word instead of at `^`. NSString all the
        // way: no UTF-8/UTF-16 conversion per rule (and replacing in an NSMutableString would move the rest of
        // the text for every match: quadratic).
        var text = NSString(string: "\n" + text)
        let folded = Folded(text)
        for rule in keys where folded.allows(rule.gate) { text = replace(rule, in: text) }
        text = maskWrapped(text)
        for rule in rules where folded.allows(rule.gate) { text = replace(rule, in: text) }
        return text.substring(from: 1)
    }

    private static func replace(_ rule: Rule, in text: NSString) -> NSString {
        rule.regex.stringByReplacingMatches(in: text as String, range: NSRange(location: 0, length: text.length),
                                            withTemplate: rule.template) as NSString
    }

    /// The text lowercased, as UTF-8, to check quickly which rules can match. Masking only takes text away,
    /// so what the original lacks no step can add.
    private struct Folded {
        let bytes: Data

        init(_ text: NSString) { bytes = text.lowercased.data(using: .utf8) ?? Data() }

        func allows(_ gate: Rule.Gate) -> Bool {
            switch gate {
            case .words(let words): words.contains(where: contains)
            case .base64Run: hasBase64Run
            }
        }

        private func contains(_ word: String) -> Bool {
            var word = word
            return bytes.withUnsafeBytes { haystack in
                word.withUTF8 { memmem(haystack.baseAddress, haystack.count, $0.baseAddress, $0.count) != nil }
            }
        }

        private var hasBase64Run: Bool {
            bytes.withUnsafeBytes { buffer in
                var run = 0
                for byte in buffer {
                    switch byte {
                    case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "/"), UInt8(ascii: "+"):
                        run += 1
                    case UInt8(ascii: "="):
                        run = 41
                    default:
                        if run == 40 { return true }
                        run = 0
                    }
                }
                return run == 40
            }
        }
    }

    /// A token the terminal soft-wrapped onto the next row (`ghp_AbCd…⏎QrSt…`): neither half looks like a token
    /// on its own. A row as wide as the widest row is taken to continue on the next one; a token shape found
    /// across that line end is masked in both rows.
    static func maskWrapped(_ text: NSString) -> NSString {
        let length = text.length
        guard text.range(of: "\n").location != NSNotFound else { return text }
        var units = [UInt16](repeating: 0, count: length)
        text.getCharacters(&units, range: NSRange(location: 0, length: length))
        // Where each row starts, and the widest row.
        var starts = [0]
        var width = 0
        var index = 0
        while index < length {
            if units[index] == 10 {
                width = max(width, index - starts[starts.count - 1])
                starts.append(index + 1)
            }
            index += 1
        }
        width = max(width, length - starts[starts.count - 1])
        guard width >= 16 else { return text }
        func rowLength(_ row: Int) -> Int { (row + 1 < starts.count ? starts[row + 1] - 1 : length) - starts[row] }

        // Runs of rows where every row but the last is full: one line the terminal wrapped.
        var pieces: [NSRange] = []
        var first = 0
        while first < starts.count {
            var last = first
            while last + 1 < starts.count, rowLength(last) == width { last += 1 }
            if last > first {
                let rows = last - first + 1
                let span = NSRange(location: starts[first], length: starts[last] + rowLength(last) - starts[first])
                let joined = text.substring(with: span).replacingOccurrences(of: "\n", with: "")
                let row = { (offset: Int) in min(offset / width, rows - 1) }
                for shape in shapes {
                    for match in shape.regex.matches(in: joined, range: NSRange(location: 0, length: (joined as NSString).length)) {
                        let range = match.range
                        guard row(range.location) != row(NSMaxRange(range) - 1) else { continue }
                        // Its part in each row, in the text's offsets.
                        for wrapped in row(range.location)...row(NSMaxRange(range) - 1) {
                            let from = max(range.location, wrapped * width)
                            let to = wrapped == rows - 1 ? NSMaxRange(range) : min(NSMaxRange(range), (wrapped + 1) * width)
                            pieces.append(NSRange(location: starts[first + wrapped] + from - wrapped * width, length: to - from))
                        }
                    }
                }
            }
            first = last + 1
        }
        guard !pieces.isEmpty else { return text }
        // Built front to back (replacing in place would move the rest of the text for every piece).
        let out = NSMutableString(capacity: length)
        var at = 0
        for piece in pieces.sorted(by: { $0.location < $1.location }) where NSMaxRange(piece) > at {
            let from = max(piece.location, at)
            if from > at { out.append(text.substring(with: NSRange(location: at, length: from - at))) }
            out.append(mask)
            at = NSMaxRange(piece)
        }
        out.append(text.substring(from: at))
        return out
    }
}
