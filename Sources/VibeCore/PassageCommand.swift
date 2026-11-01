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
        // The file system ignores case: `…/passage.APP` is the bundle and `…/contents/macos/Passage` its binary.
        if path.lowercased().hasSuffix(".app") { return PassageCommand(executable: binary(ofApp: path), leading: ["cli"]) }
        if (path as NSString).lastPathComponent == "passage" { return PassageCommand(executable: path) }
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let inApp = [path, real].contains { $0.range(of: ".app/Contents/MacOS/", options: .caseInsensitive) != nil }
        return PassageCommand(executable: path, leading: inApp ? ["cli"] : [])
    }

    /// The command for a path set in Settings, only once it names something that can run (`forPath`, then checked): an
    /// existing regular file that's executable (a link followed), or an app bundle whose `Contents/MacOS/Passage` is
    /// one. Nil for a path half typed (`/usr/local/bin/pa`), a folder, a missing file or one that can't run, so a
    /// prefix of the path is never run as a program. Reads the file system only.
    public static func runnable(_ setting: String) -> PassageCommand? {
        guard let command = forPath(setting), isExecutableFile(command.executable) else { return nil }
        return command
    }

    /// A regular file (following a link) the user may execute: a folder, which has its x bit too, isn't one.
    static func isExecutableFile(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }

    /// The command for Settings › Wallet's path: the path set (see `runnable`), or when it's empty `passage` on the
    /// PATH (`onPath`, an absolute path), else the first of `apps` whose binary is executable, run with `cli`. Nil when
    /// none is found, or the path set isn't absolute or isn't something that can run. `onPath` may run a shell: call this off the main thread.
    public static func resolve(setting: String, onPath: () -> String?, apps: [URL] = appLocations) -> PassageCommand? {
        if !setting.trimmingCharacters(in: .whitespaces).isEmpty { return runnable(setting) }
        if let found = onPath(), found.hasPrefix("/") { return forPath(found) }
        for app in apps {
            let binary = binary(ofApp: app.path)
            if isExecutableFile(binary) { return PassageCommand(executable: binary, leading: ["cli"]) }
        }
        return nil
    }

    /// How Settings names it: the app bundle for a binary inside one (`/Applications/Passage.app`), else the path.
    public var shown: String {
        guard let range = executable.range(of: ".app/Contents/MacOS/", options: [.backwards, .caseInsensitive]) else { return executable }
        return String(executable[..<executable.index(range.lowerBound, offsetBy: 4)])
    }
}
