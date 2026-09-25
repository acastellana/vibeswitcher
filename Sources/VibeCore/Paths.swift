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

    public static func stateFile(tty: String) -> URL {
        stateDir.appendingPathComponent("\(tty).json")
    }
}
