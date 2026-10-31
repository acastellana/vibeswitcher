import Foundation

/// How Passage's command line is run: a program and the arguments that come before the command. Passage is one
/// binary, Passage.app/Contents/MacOS/Passage, that runs as its CLI only when `argv[0]` is named `passage` (the symlink
/// its README suggests) or its first argument is `cli` (Passage's CLI.swift, `invocation`); run any other way it opens
/// its window. So the app's binary is run as `<binary> cli <command…>`, and a `passage` symlink or another CLI as is.
public struct PassageCommand: Equatable, Sendable {
    /// An absolute path.
    public let executable: String
    /// What comes before the command: `["cli"]` for the app's binary, else nothing.
    public let leading: [String]

    public init(executable: String, leading: [String] = []) {
        self.executable = executable
        self.leading = leading
    }

    /// The program's arguments for `command` (`["send", …]`).
    public func arguments(_ command: [String]) -> [String] { leading + command }

    /// Where Passage.app is looked for when no path is set and `passage` isn't on the PATH, in this order.
    public static var appLocations: [URL] {
        [URL(fileURLWithPath: "/Applications/Passage.app", isDirectory: true),
         URL(fileURLWithPath: VibePaths.home).appendingPathComponent("Applications/Passage.app", isDirectory: true)]
    }

    /// The binary inside an app bundle.
    static func binary(ofApp bundle: String) -> String {
        URL(fileURLWithPath: bundle, isDirectory: true).appendingPathComponent("Contents/MacOS/Passage").path
    }

    /// The command for a path set in Settings: an app bundle (`….app`) runs its `Contents/MacOS/Passage` with `cli`; a
    /// file named `passage` runs as is (Passage takes that name as its CLI); any other file runs with `cli` when it is,
    /// or links to, a binary inside an app bundle (`….app/Contents/MacOS/…`), else as is. Nil unless absolute.
    public static func forPath(_ setting: String) -> PassageCommand? {
        var path = setting.trimmingCharacters(in: .whitespaces)
        guard path.hasPrefix("/") else { return nil }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".app") { return PassageCommand(executable: binary(ofApp: path), leading: ["cli"]) }
        if (path as NSString).lastPathComponent == "passage" { return PassageCommand(executable: path) }
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let inApp = [path, real].contains { $0.range(of: ".app/Contents/MacOS/") != nil }
        return PassageCommand(executable: path, leading: inApp ? ["cli"] : [])
    }

    /// The command for Settings › Wallet's path: the path set (see `forPath`), or when it's empty `passage` on the
    /// PATH (`onPath`, an absolute path), else the first of `apps` whose binary is executable, run with `cli`. Nil when
    /// none is found, or the path set isn't absolute. `onPath` may run a shell: call this off the main thread.
    public static func resolve(setting: String, onPath: () -> String?, apps: [URL] = appLocations) -> PassageCommand? {
        if !setting.trimmingCharacters(in: .whitespaces).isEmpty { return forPath(setting) }
        if let found = onPath(), found.hasPrefix("/") { return forPath(found) }
        for app in apps {
            let binary = binary(ofApp: app.path)
            if FileManager.default.isExecutableFile(atPath: binary) { return PassageCommand(executable: binary, leading: ["cli"]) }
        }
        return nil
    }

    /// How Settings names it: the app bundle for a binary inside one (`/Applications/Passage.app`), else the path.
    public var shown: String {
        guard let range = executable.range(of: ".app/Contents/MacOS/", options: .backwards) else { return executable }
        return String(executable[..<executable.index(range.lowerBound, offsetBy: 4)])
    }
}
