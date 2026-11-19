import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// `hooks install`'s staged programs (the security follow-ups' item 29), in process: a book on a scratch home as the
/// app's vault, a node root whose `bin/` holds two small programs, and `HooksRequest.install` with its test hook
/// (`beforeRenames`) standing for another process of the user's that finds a staged file between its write and its
/// rename. A staged file swapped is refused before anything is renamed, and nothing is sealed; one rewritten in place
/// is taken out again after its rename. Never the user's own home or vault.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct HooksStagingTests {
    private let scratch = Scratch()

    private struct Setup {
        let home: String
        let root: String
        let app: LeadVault
        let request: HooksRequest
        var bin: String { home + "/.vibeswitcher/bin" }
        var settings: String { home + "/.claude/settings.json" }
    }

    /// The scratch home with its `~/.vibeswitcher/bin` made and the config looked at once (recorded), the app's vault,
    /// and the request for a node root holding the two programs, `binaries` their hashes.
    private func setUp() throws -> Setup {
        let home = scratch.url("home").resolvingSymlinksInPath().path
        let folder = scratch.url("vault")
        let root = home + "/repo"
        for path in [home + "/.vibeswitcher/bin", folder.path, root] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let book = LeadVault.Book()
        book.configHome = home
        let app = book.vault(folder: folder, as: { .app })
        try app.bind(try app.startLead(root: root, branch: "main"), root: root, session: "lead-session")
        _ = try app.checkConfig(root: root)
        let nodeRoot = scratch.url("node")
        try FileManager.default.createDirectory(at: nodeRoot.appendingPathComponent("bin"), withIntermediateDirectories: true)
        var binaries: [String: String] = [:]
        for name in HooksRequest.programs {
            let bytes = Data("#!/bin/sh\necho \(name)\n".utf8)
            try bytes.write(to: nodeRoot.appendingPathComponent("bin/" + name))
            binaries[name] = BuildInfo.sha256(of: bytes)
        }
        let request = HooksRequest(nodeRoot: nodeRoot.path, home: home, binaries: binaries, vault: app)
        return Setup(home: home, root: root, app: app, request: request)
    }

    private func names(_ folder: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted() }

    /// The control: with nothing done to the staged files, both programs go in and the write is sealed (the record
    /// changes), so the refusal below is the checks', not the fixture's.
    @Test func anUntouchedInstallGoesInAndIsSealed() throws {
        let setup = try setUp()
        let before = try setup.app.guardedRecord(root: setup.root)
        var request = setup.request
        var seen: [String: String] = [:]
        request.beforeRenames = { seen = $0 }
        let installed = request.install(agents: [.claude])
        #expect((try? installed.get()) != nil, "\(installed)")
        #expect(Set(seen.keys) == Set(HooksRequest.programs), "\(seen)")
        #expect(names(setup.bin) == HooksRequest.programs)
        #expect(FileManager.default.fileExists(atPath: setup.settings))
        #expect(try setup.app.guardedRecord(root: setup.root) != before, "the install wasn't sealed")
        #expect(!names(setup.home + "/.vibeswitcher").contains { $0.contains(".tmp") }, "\(names(setup.home + "/.vibeswitcher"))")
    }

    /// A staged program swapped (another file renamed over its name) between its write and its rename: refused before
    /// anything is renamed or any config written, and nothing is sealed.
    @Test func aStagedProgramSwappedBeforeItsRenameIsRefusedAndNothingSealed() throws {
        let setup = try setUp()
        let before = try setup.app.guardedRecord(root: setup.root)
        var request = setup.request
        request.beforeRenames = { staged in
            guard let path = staged["vibeswitcher-mcp"] else { return }
            let swap = path + ".swap"
            // As long as the staged file, so only its inode tells them apart.
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            _ = FileManager.default.createFile(atPath: swap, contents: Data(repeating: 0x23, count: size), attributes: [.posixPermissions: 0o755])
            _ = rename(swap, path)
        }
        let refused = request.install(agents: [.claude])
        guard case .failure(let refusal) = refused else {
            Issue.record("a swapped staged program was installed: \(names(setup.bin))")
            return
        }
        #expect(refusal.text.contains("isn't the file written there any more"), "\(refusal.text)")
        #expect(names(setup.bin).isEmpty, "\(names(setup.bin))")
        #expect(!FileManager.default.fileExists(atPath: setup.settings))
        #expect(try setup.app.guardedRecord(root: setup.root) == before, "something was sealed")
        #expect(!names(setup.home + "/.vibeswitcher").contains { $0.contains(".tmp") }, "\(names(setup.home + "/.vibeswitcher"))")
    }

    /// A staged program rewritten in place (same file, same size, other bytes) before its rename: its rename is undone
    /// once the program in place is hashed again, the configs aren't written, and the rewritten bytes aren't left there.
    @Test func aStagedProgramRewrittenInPlaceIsTakenOutAfterItsRename() throws {
        let setup = try setUp()
        var request = setup.request
        request.beforeRenames = { staged in
            guard let path = staged["vibeswitcher-hook"], let handle = FileHandle(forWritingAtPath: path) else { return }
            try? handle.seek(toOffset: 0)
            try? handle.write(contentsOf: Data("#!/bin/sh\n#".utf8))
            try? handle.close()
        }
        let refused = request.install(agents: [.claude])
        guard case .failure(let refusal) = refused else {
            Issue.record("a rewritten staged program was installed: \(names(setup.bin))")
            return
        }
        #expect(refusal.text.contains("wasn't the bytes written after its rename"), "\(refusal.text)")
        #expect(!FileManager.default.fileExists(atPath: setup.bin + "/vibeswitcher-hook"))
        #expect(!FileManager.default.fileExists(atPath: setup.settings))
    }

    // MARK: The configs

    private func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    private func text(_ path: String) -> String? { (try? Data(contentsOf: URL(fileURLWithPath: path))).map { String(decoding: $0, as: UTF8.self) } }

    /// The repro, from the first Linux node (2026-11-19): a settings.json with a hook of the user's own and a `true`
    /// among its settings got the two programs and then "the hooks weren't all installed: The operation could not be
    /// completed. (NSCocoaErrorDomain error 512.)", with no hook written.
    @Test func aSettingsFileWithTheUsersOwnHookAndATrueTakesOurs() throws {
        let setup = try setUp()
        let head = "{\n  \"$schema\": \"https://json.schemastore.org/claude-code-settings.json\",\n  \"model\": \"fable\",\n  \"hooks\": "
        let users = """
        {"Stop": [{"hooks": [{"type": "command", "command": "\\"$HOME/bin/say\\" \\"✓ turn finished\\" || true", "async": true}]}]}
        """
        let tail = ",\n  \"alwaysThinkingEnabled\": true,\n  \"feedbackSurveyState\": {\"lastShownTime\": 1754063019868}\n}\n"
        try write(head + users + tail, to: setup.settings)

        let installed = setup.request.install(agents: [.claude])
        #expect((try? installed.get()) != nil, "\(installed)")
        let after = try #require(text(setup.settings))
        #expect(after.hasPrefix(head + "{") && after.hasSuffix("}" + tail), "\(after)")
        let config = try #require(try JSONSerialization.jsonObject(with: Data(after.utf8)) as? [String: Any])
        #expect(HookInstaller.isComplete(in: config, agent: .claude))
        let stop = (config["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]] ?? []
        let handler = try #require((stop.first?["hooks"] as? [[String: Any]])?.first, "\(after)")
        #expect(handler["command"] as? String == "\"$HOME/bin/say\" \"✓ turn finished\" || true")
        #expect((handler["async"] as? NSNumber).map(Platform.isBoolean) == true && handler["async"] as? Bool == true, "\(handler)")
        #expect(names(setup.bin) == HooksRequest.programs)

        // Taken out again, the user's hook and every other byte stay.
        let removed = setup.request.remove(agents: [.claude])
        #expect((try? removed.get()) != nil, "\(removed)")
        let left = try #require(text(setup.settings))
        #expect(left.hasPrefix(head + "{") && left.hasSuffix("}" + tail), "\(left)")
        let leftConfig = try #require(try JSONSerialization.jsonObject(with: Data(left.utf8)) as? [String: Any])
        #expect(!HookInstaller.isInstalled(in: leftConfig))
        #expect(left.filter { !$0.isWhitespace }.contains("\"async\":true"), "\(left)")
    }

    /// A config that can't take the hooks is found before a program is staged: the refusal names the file and why on
    /// one line, and nothing is installed, written or sealed (the first Linux node was left with the programs and no
    /// hooks).
    @Test func aConfigThatCannotTakeTheHooksRefusesTheInstallWithNothingDone() throws {
        let cases = [("{\"model\": ", "it isn't valid JSON"), ("[\"not an object\"]\n", "it isn't a JSON object")]
        for (broken, why) in cases {
            let setup = try setUp()
            try write(broken, to: setup.settings)
            let before = try setup.app.guardedRecord(root: setup.root)
            var request = setup.request
            var staged = false
            request.beforeRenames = { _ in staged = true }
            guard case .failure(let refusal) = request.install(agents: [.codex, .claude]) else {
                Issue.record("installed into \(broken)")
                continue
            }
            #expect(refusal.text.hasPrefix("\(setup.settings) can't take the hooks: \(why)"), "\(refusal.text)")
            #expect(refusal.text.hasSuffix(": nothing was installed") && !refusal.text.contains("\n"), "\(refusal.text)")
            #expect(!refusal.text.contains("NSCocoaErrorDomain") && !refusal.text.contains("could not be completed"), "\(refusal.text)")
            #expect(!staged && names(setup.bin).isEmpty, "\(names(setup.bin))")
            #expect(text(setup.settings) == broken)
            // Codex's config, asked first and able to take them, wasn't written either.
            #expect(!FileManager.default.fileExists(atPath: setup.home + "/.codex/hooks.json"))
            #expect(names(setup.home + "/.claude") == ["settings.json"], "\(names(setup.home + "/.claude"))")
            #expect(try setup.app.guardedRecord(root: setup.root) == before, "something was sealed")
            #expect(!names(setup.home + "/.vibeswitcher").contains { $0.contains(".tmp") }, "\(names(setup.home + "/.vibeswitcher"))")
        }
    }

    /// A config that fails after the check passed (here: rewritten between the check and its edit, as another
    /// process of the user's could) is named with the reason and with what was done before it.
    @Test func aConfigThatFailsAfterTheProgramsAreInIsNamedWithWhatWasDone() throws {
        let setup = try setUp()
        let codex = setup.home + "/.codex/hooks.json"
        var request = setup.request
        request.beforeRenames = { _ in try? write("[1]\n", to: codex) }
        guard case .failure(let refusal) = request.install(agents: [.claude, .codex]) else {
            Issue.record("installed into a config that isn't an object")
            return
        }
        #expect(refusal.text == "\(codex) wasn't changed: it isn't a JSON object: the hooks' programs are in \(setup.bin), and \(setup.settings) has its hooks",
                "\(refusal.text)")
        #expect(names(setup.bin) == HooksRequest.programs)
        #expect(text(codex) == "[1]\n")
        let settings = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: setup.settings))) as? [String: Any])
        #expect(HookInstaller.isComplete(in: settings, agent: .claude))

        // The same for a remove: the file named, the reason, and the config already done.
        guard case .failure(let kept) = request.remove(agents: [.claude, .codex]) else {
            Issue.record("removed from a config that isn't an object")
            return
        }
        #expect(kept.text == "\(codex) wasn't changed: it isn't a JSON object: the hooks are out of \(setup.settings)", "\(kept.text)")
        #expect(!HookInstaller.isInstalled(in: try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: setup.settings))) as? [String: Any])))
    }
}
