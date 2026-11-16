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
}
