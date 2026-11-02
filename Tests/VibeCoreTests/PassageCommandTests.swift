import Foundation
import Testing
@testable import VibeCore

/// Which Passage wallet requests go through and how it's run: Passage.app's binary only as `<binary> cli <command…>`
/// (run any other way it opens its window), a `passage` link or another CLI as is. Paths are scratch ones: the
/// real Passage never runs here.
struct PassageCommandTests {
    let scratch = Scratch()

    /// An executable file at `path` (folders made).
    func file(_ path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: path, atomically: true, encoding: .utf8)
        chmod(path.path, 0o755)
    }

    @Test func aPathSetInSettingsIsRunAsWhatItPointsAt() throws {
        let app = "/Applications/Passage.app"
        let binary = app + "/Contents/MacOS/Passage"
        #expect(PassageCommand.forPath(app) == PassageCommand(executable: binary, leading: ["cli"]))
        #expect(PassageCommand.forPath(app + "/") == PassageCommand(executable: binary, leading: ["cli"]))
        #expect(PassageCommand.forPath(binary) == PassageCommand(executable: binary, leading: ["cli"]))
        #expect(PassageCommand.forPath("/opt/example/bin/passage") == PassageCommand(executable: "/opt/example/bin/passage"))
        #expect(PassageCommand.forPath("/opt/example/bin/other-passage-cli") == PassageCommand(executable: "/opt/example/bin/other-passage-cli"))
        // The file system ignores case, so neither does this.
        #expect(PassageCommand.forPath("/Applications/passage.APP") == PassageCommand(executable: "/Applications/passage.APP/Contents/MacOS/Passage", leading: ["cli"]))
        #expect(PassageCommand.forPath(app + "/contents/macos/Passage")?.leading == ["cli"])
        #expect(PassageCommand(executable: app + "/contents/macos/Passage").shown == app)
        #expect(PassageCommand.forPath("relative/passage") == nil)
        #expect(PassageCommand.forPath("Passage.app") == nil)
        #expect(PassageCommand.forPath(binary)?.arguments(["peers", "--json"]) == ["cli", "peers", "--json"])
        #expect(PassageCommand.forPath("/opt/example/bin/passage")?.arguments(["peers", "--json"]) == ["peers", "--json"])
    }

    /// A link named `passage` runs as is (Passage takes that name as its CLI); a link by another name to the app's
    /// binary gets `cli`.
    @Test func linksAreRunByTheirNameOrWhatTheyPointAt() throws {
        let folder = scratch.url("links")
        let binary = folder.appendingPathComponent("Passage.app/Contents/MacOS/Passage")
        try file(binary)
        let named = folder.appendingPathComponent("bin/passage")
        // Another folder: the file system ignores case, so `Passage` beside `passage` would be the same name.
        let other = folder.appendingPathComponent("other/Passage")
        try FileManager.default.createDirectory(at: named.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: named, withDestinationURL: binary)
        try FileManager.default.createSymbolicLink(at: other, withDestinationURL: binary)
        #expect(PassageCommand.forPath(named.path) == PassageCommand(executable: named.path))
        #expect(PassageCommand.forPath(other.path) == PassageCommand(executable: other.path, leading: ["cli"]))
    }

    /// A path set runs only once it names something that can run: a half-typed one, a folder (its x bit set), a file
    /// that isn't executable, or an app bundle without its binary is nil, so a prefix is never run as a program.
    @Test func aPathSetRunsOnlyWhenItNamesSomethingThatCanRun() throws {
        let folder = scratch.url("runnable")
        let binary = folder.appendingPathComponent("Passage.app/Contents/MacOS/Passage")
        let cli = folder.appendingPathComponent("bin/passage")
        try file(binary)
        try file(cli)
        let plain = folder.appendingPathComponent("bin/notes.txt")
        try "text\n".write(to: plain, atomically: true, encoding: .utf8)
        let empty = folder.appendingPathComponent("Empty.app", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(PassageCommand.runnable(cli.path) == PassageCommand(executable: cli.path))
        #expect(PassageCommand.runnable(folder.appendingPathComponent("Passage.app").path) == PassageCommand(executable: binary.path, leading: ["cli"]))
        #expect(PassageCommand.runnable(binary.path) == PassageCommand(executable: binary.path, leading: ["cli"]))
        for half in [String(cli.path.dropLast(2)), folder.appendingPathComponent("Passage.ap").path, folder.appendingPathComponent("bin").path,
                     folder.appendingPathComponent("Passage.app/Contents").path, plain.path, empty.path, "relative/passage", ""] {
            #expect(PassageCommand.runnable(half) == nil, "\(half)")
            #expect(PassageCommand.resolve(setting: half.isEmpty ? " x" : half, onPath: { Issue.record("looked on the PATH"); return nil }, apps: []) == nil)
        }
    }

    @Test func withNoPathSetPassageOnThePathComesFirstThenTheApps() throws {
        let folder = scratch.url("apps")
        let system = folder.appendingPathComponent("Applications/Passage.app", isDirectory: true)
        let own = folder.appendingPathComponent("home/Applications/Passage.app", isDirectory: true)
        let systemBinary = system.appendingPathComponent("Contents/MacOS/Passage").path
        let ownBinary = own.appendingPathComponent("Contents/MacOS/Passage").path
        // Nothing anywhere: nil.
        #expect(PassageCommand.resolve(setting: "", onPath: { nil }, apps: [system, own]) == nil)
        // Only in ~/Applications: that one.
        try file(URL(fileURLWithPath: ownBinary))
        #expect(PassageCommand.resolve(setting: "", onPath: { nil }, apps: [system, own]) == PassageCommand(executable: ownBinary, leading: ["cli"]))
        // In /Applications too: that one first.
        try file(URL(fileURLWithPath: systemBinary))
        #expect(PassageCommand.resolve(setting: "", onPath: { nil }, apps: [system, own]) == PassageCommand(executable: systemBinary, leading: ["cli"]))
        // `passage` on the PATH before either.
        #expect(PassageCommand.resolve(setting: "", onPath: { "/opt/example/bin/passage" }, apps: [system, own])
                == PassageCommand(executable: "/opt/example/bin/passage"))
        // A path set: that, and nothing is looked for.
        #expect(PassageCommand.resolve(setting: own.path, onPath: { Issue.record("looked on the PATH"); return nil }, apps: [system])
                == PassageCommand(executable: ownBinary, leading: ["cli"]))
        #expect(PassageCommand.resolve(setting: "relative", onPath: { nil }, apps: [system]) == nil)
        // An app bundle without its binary isn't found.
        let empty = folder.appendingPathComponent("Empty/Passage.app", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(PassageCommand.resolve(setting: "", onPath: { nil }, apps: [empty]) == nil)
    }

    @Test func theDefaultPlacesAreApplicationsThenTheHomesApplications() {
        #expect(PassageCommand.appLocations.map(\.path) == ["/Applications/Passage.app", VibePaths.home + "/Applications/Passage.app"])
    }

    @Test func settingsNamesTheAppForItsBinary() {
        #expect(PassageCommand(executable: "/Applications/Passage.app/Contents/MacOS/Passage", leading: ["cli"]).shown == "/Applications/Passage.app")
        #expect(PassageCommand(executable: "/opt/example/bin/passage").shown == "/opt/example/bin/passage")
    }
}
