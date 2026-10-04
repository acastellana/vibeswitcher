import Foundation

/// Masks credentials in text we store or show (commands awaiting approval, tool details, messages):
/// they would otherwise land in notification banners, Notification Center's history and the state files.
public enum Redaction {
    static let mask = "•••"

    /// A secret-sounding name. Matching starts only where a run of name characters starts (not at every
    /// `\b` inside a long `a-b-c-…` run, which made each rule quadratic: 40 KB took minutes).
    private static let secretName =
        #"(?<![a-z0-9_-])[a-z0-9_-]*(?:token|secret|passw(?:or)?d|passwd|api[_-]?key|access[_-]?key|private[_-]?key|credentials?)[a-z0-9_]*"#
    private static let keyLabel = #"[A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----"#

    private static let rules: [(NSRegularExpression, String)] = [
        // Private keys (PEM, PGP), whole: through their END line, or to the end of the text when it's cut off
        // (a key taller than the screen, a truncated tool output)…
        ("-----BEGIN " + keyLabel + #"(?:[\s\S]*?-----END "# + keyLabel + #"|[\s\S]*\z)"#, mask),
        // …and the rest of one whose start scrolled off the top.
        (#"\A(?:(?!-----BEGIN )[\s\S])*?-----END "# + keyLabel, mask),
        // Quoted values of secret-sounding names, up to the closing quote (spaces and escaped quotes included).
        ("(?i)(" + secretName + #"["']?\s*[=:]\s*)"(?:[^"\\\n]|\\.)*""#, "$1\"\(mask)\""),
        ("(?i)(" + secretName + #"["']?\s*[=:]\s*)'(?:[^'\\\n]|\\.)*'"#, "$1'\(mask)'"),
        // Authorization headers: keep the scheme, hide the credential.
        (#"(?i)(authorization:\s*(?:bearer|basic|token)?\s*)[^\s"']+"#, "$1\(mask)"),
        // NAME=value, NAME: value, "api_key": "value" for secret-sounding names.
        ("(?i)(" + secretName + #"["']?\s*[=:]\s*["']?)[^\s"'&,;]+"#, "$1\(mask)"),
        // --password value, --api-key=value (flags only: in prose "the token expired" is fine).
        (#"(?i)((?:^|\s)--?[a-z0-9-]*(?:token|secret|passw(?:or)?d|passwd|api-?key)[a-z0-9-]*(?:=|\s+)["']?)[^\s"'<>|&;][^\s"']*"#,
         "$1\(mask)"),
        // Credentials inside URLs: scheme://user:pass@host
        (#"(://[^/\s:@]+:)[^@\s/]+@"#, "$1\(mask)@"),
        // Well-known token shapes, wherever they appear.
        (#"\b(?:sk|pk|rk)-[A-Za-z0-9_-]{16,}"#, mask),
        (#"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}"#, mask),
        (#"\bxox[abposr]-[A-Za-z0-9-]{10,}"#, mask),
        (#"\bAKIA[0-9A-Z]{16}\b"#, mask),
        (#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, mask),   // JWT
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    public static func secrets(in text: String) -> String {
        rules.reduce(text) { text, rule in
            rule.0.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: rule.1)
        }
    }
}
