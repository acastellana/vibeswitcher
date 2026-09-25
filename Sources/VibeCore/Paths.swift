import Foundation

/// Everything VibeSwitcher writes lives under `~/.vibeswitcher`, so it is easy to inspect or delete.
public enum VibePaths {
    public static var root: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".vibeswitcher")
    }
    /// One `<tty>.json` per terminal, written by the hook binary.
    public static var stateDir: URL { root.appendingPathComponent("state") }
    public static var binDir: URL { root.appendingPathComponent("bin") }
    /// Stable location referenced from the Claude/Codex hook configs (independent of where the .app lives).
    public static var hookBinary: URL { binDir.appendingPathComponent("vibeswitcher-hook") }

    /// Creates `~/.vibeswitcher` and its state folder private to you (0700), fixing older installs too.
    public static func ensurePrivateDirectories() {
        let fm = FileManager.default
        for dir in [root, stateDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }

    public static func stateFile(tty: String) -> URL {
        stateDir.appendingPathComponent("\(tty).json")
    }
}
