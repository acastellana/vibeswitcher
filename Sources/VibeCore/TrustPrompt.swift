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
    /// The menu's cursor (❯) is on "Yes, I trust this folder".
    public static func cursorOnYes(_ screen: String) -> Bool {
        screen.components(separatedBy: "\n").contains { line in
            let trimmed = line.replacingOccurrences(of: "\u{0}", with: " ").trimmingCharacters(in: .whitespaces)
            return (trimmed.hasPrefix("❯") || trimmed.hasPrefix("›") || trimmed.hasPrefix(">")) && trimmed.contains("Yes, I trust")
        }
    }

    /// Watches a new session's screen; when it asks about `folder`, moves to "Yes" and presses Enter only once the
    /// screen shows the cursor there (keys sent before the menu takes input are lost, and Enter on the default
    /// "No, exit" would end the session). Never presses Enter otherwise. Returns whether it answered.
    @discardableResult
    public static func answer(folder: String, timeout: TimeInterval = 15, pause: TimeInterval = 0.5,
                              readScreen: () -> String?, send: ([HostInput.Write]) -> Void) -> Bool {
        let down = HostInput.Write(bytes: [27, 91, 66], delay: 0)
        let start = Date()
        var asked = false
        while Date().timeIntervalSince(start) < timeout {
            if let screen = readScreen() {
                if asked || isAsking(screen, about: folder) {
                    if !asked {
                        asked = true
                        // Let the menu start taking keys.
                        if pause > 0 { usleep(useconds_t(pause * 1_000_000)) }
                        send([down])
                    } else if cursorOnYes(screen) {
                        send([HostInput.Write(bytes: [13], delay: 0)])
                        return true
                    } else if isAsking(screen, about: folder) {
                        send([down])
                    } else {
                        return false
                    }
                } else if Date().timeIntervalSince(start) > 3, screen.contains("Claude Code"), !screen.contains("trust") {
                    // Up and not asking: nothing to answer.
                    return false
                }
            }
            if pause > 0 { usleep(useconds_t(min(pause, 0.4) * 1_000_000)) }
        }
        return false
    }
}
