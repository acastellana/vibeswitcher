import Foundation

/// Claude Code's "do you trust this folder?" question, which a new folder (a worker's worktree) gets at start.
/// Starting a project lead in a repository is the user's consent to work there, so its sessions answer yes —
/// only for the exact folder they were started in.
public enum TrustPrompt {
    public static func isAsking(_ screen: String, about folder: String) -> Bool {
        let flat = screen.replacingOccurrences(of: "\u{0}", with: " ")
        guard flat.contains("Yes, I trust this folder") || flat.contains("trust this folder") else { return false }
        let wanted = canonical(folder)
        return flat.components(separatedBy: "\n").contains { canonical($0.trimmingCharacters(in: .whitespaces)) == wanted }
    }

    /// Down to "Yes, I trust this folder", then Enter.
    public static let yesKeys = [HostInput.Write(bytes: [27, 91, 66], delay: 0), HostInput.Write(bytes: [13], delay: 0.15)]

    /// The same folder however it's written: `/tmp/x` and `/private/tmp/x` are one place on macOS.
    private static func canonical(_ path: String) -> String {
        var standard = (path as NSString).standardizingPath
        for top in ["/private/tmp", "/private/var", "/private/etc"] where standard == top || standard.hasPrefix(top + "/") {
            standard = String(standard.dropFirst("/private".count))
        }
        return standard
    }
}

extension TrustPrompt {
    /// Watches a new session's screen for a while; answers yes if it asks about `folder`. Returns whether it did.
    /// `readScreen` and `send` are synchronous (the tool server's host calls).
    @discardableResult
    public static func answer(folder: String, timeout: TimeInterval = 15, readScreen: () -> String?,
                              send: ([HostInput.Write]) -> Void) -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if let screen = readScreen() {
                if isAsking(screen, about: folder) {
                    send(yesKeys)
                    return true
                }
                // Claude is up and not asking: nothing to answer.
                if Date().timeIntervalSince(start) > 3, screen.contains("Claude Code"), !screen.contains("trust") { return false }
            }
            usleep(400_000)
        }
        return false
    }
}
