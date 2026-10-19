import Foundation

/// Where debug aids (`--capture-window`) may write: scratch places only. Any process of the user's can
/// ask the running app for them, so a path elsewhere could overwrite the user's files.
public enum DebugOutput {
    public static func allowed(_ path: String, home: String = VibePaths.home) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let standard = (path as NSString).standardizingPath
        // Through any symlinked folder to where it really lands.
        let folder = URL(fileURLWithPath: (standard as NSString).deletingLastPathComponent).resolvingSymlinksInPath().path
        let places = ["/tmp", "/private/tmp", "/private/var/folders",
                      URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path,
                      (home as NSString).appendingPathComponent(".vibeswitcher")]
        return places.contains { folder == $0 || folder.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
}
