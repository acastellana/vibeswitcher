import Foundation

/// Strings shaped like a vendor's credential: a Slack or Discord webhook, a Slack, Stripe, AWS, Google, GitHub,
/// GitLab, SendGrid, npm, PyPI, Hugging Face, age, Anthropic or OpenAI key, or a PEM/OpenSSH/PGP private key. One list for every check that looks for
/// them: `SecretShapeLintTests` (no file in the repository holds one: GitHub push protection refuses a push that
/// does) and `tell_lead` (no lead sends one to another project's lead; see `LeadMail`).
public enum SecretShapes {
    /// Close to the shapes GitHub's supported patterns list, and looser where that costs nothing (shorter minimum
    /// lengths, no checksums), so a string fails here before it reaches a push. No shape crosses a line but the private
    /// key's, which is its header and the first line of its body (a real newline or a `\n` in a string literal).
    public static let shapes: [(name: String, pattern: NSRegularExpression)] = [
        ("Slack webhook", #"hooks\.slack\.com/(?:services|workflows|triggers)/[A-Za-z0-9_-]+/[A-Za-z0-9_/-]+"#),
        ("Slack token", #"xox[abposr]-[A-Za-z0-9-]{10,}"#),
        ("Discord webhook", #"discord(?:app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+"#),
        ("Stripe key", #"[spr]k_(?:live|test)_[A-Za-z0-9]{10,}"#),
        ("AWS access key ID", #"(?:AKIA|ASIA)[0-9A-Z]{16}"#),
        // 40 characters of base64 with a lower case letter, a capital and a digit, standing alone: not a commit hash
        // (hex, one case) nor part of a longer run.
        ("AWS secret access key",
         #"(?<![A-Za-z0-9/+])(?=[A-Za-z0-9/+]{0,39}[a-z])(?=[A-Za-z0-9/+]{0,39}[A-Z])(?=[A-Za-z0-9/+]{0,39}[0-9])[A-Za-z0-9/+]{40}(?![A-Za-z0-9/+=])"#),
        ("Google API key", #"AIza[0-9A-Za-z_-]{30,}"#),
        ("GitHub token", #"gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}"#),
        ("GitLab token", #"glpat-[A-Za-z0-9_-]{20,}"#),
        ("SendGrid key", #"\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"#),
        ("npm token", #"npm_[A-Za-z0-9]{30,}"#),
        ("PyPI token", #"pypi-AgE[A-Za-z0-9_-]{16,}"#),
        ("Hugging Face token", #"hf_[A-Za-z0-9]{30,}"#),
        ("age secret key", #"AGE-SECRET-KEY-1[0-9A-Z]{20,}"#),
        ("Anthropic key", #"sk-ant-(?:api|admin)[0-9]{2}-[A-Za-z0-9_-]{80,}"#),
        ("OpenAI key", #"sk-[A-Za-z0-9_-]{16,}T3BlbkFJ[A-Za-z0-9_-]{16,}"#),
        // The header alone is no key (redaction fixtures quote it, with a body of a few characters): a header followed
        // by a whole body line, 64 characters of base64 as PEM writes them (OpenSSH's are 70), is.
        ("Private key", #"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----(?:\\n|\r?\n){1,2}[A-Za-z0-9+/]{64}"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    /// The names of the shapes found in `text`, in the list's order (empty: none).
    public static func found(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return shapes.filter { $0.pattern.firstMatch(in: text, range: range) != nil }.map(\.name)
    }

    /// `text` with every match of a shape replaced by `mask`.
    public static func masked(_ text: String, mask: String = "•••") -> String {
        shapes.reduce(text) { text, shape in
            shape.pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                   withTemplate: NSRegularExpression.escapedTemplate(for: mask))
        }
    }
}
