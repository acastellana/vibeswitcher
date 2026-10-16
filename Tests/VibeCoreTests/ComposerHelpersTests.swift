import Foundation
import Testing
@testable import VibeCore

struct ComposerHelpersTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("composer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func tokensAtTheCaret() {
        #expect(ComposerToken.at("/comp", caret: 5) == ComposerToken(kind: .slash, query: "comp", range: NSRange(location: 0, length: 5)))
        #expect(ComposerToken.at("look at @src/Ap and", caret: 15) == ComposerToken(kind: .mention, query: "src/Ap", range: NSRange(location: 8, length: 7)))
        #expect(ComposerToken.at("say /comp", caret: 9) == nil)        // a slash command only starts the message
        #expect(ComposerToken.at("mail a@b", caret: 8) == nil)         // @ inside a word
        #expect(ComposerToken.at("/clear now", caret: 10) == nil)      // past the command
        #expect(ComposerToken.at("@", caret: 1)?.query == "")
    }

    @Test func slashCatalogReadsCommandsAndSkills() throws {
        let home = try folder()
        try write("---\ndescription: Ship the thing\n---\nDo it", home.appendingPathComponent("commands/ship.md"))
        try write("# Review the diff\nbody", home.appendingPathComponent("commands/git/review.md"))
        try write("---\nname: deploy-site\ndescription: Deploy to prod\n---\n", home.appendingPathComponent("skills/deploy/SKILL.md"))
        let found = SlashCatalog.scan(commandDirs: [home.appendingPathComponent("commands")],
                                      skillDirs: [home.appendingPathComponent("skills")])
        #expect(found == [SlashCommand(name: "deploy-site", description: "Deploy to prod"),
                          SlashCommand(name: "git:review", description: "Review the diff"),
                          SlashCommand(name: "ship", description: "Ship the thing")])
    }

    @Test func slashMatchesPreferPrefixes() {
        let commands = [SlashCommand(name: "clear", description: ""), SlashCommand(name: "compact", description: ""),
                        SlashCommand(name: "context", description: "")]
        #expect(SlashCatalog.match("co", in: commands).map(\.name) == ["compact", "context"])
        #expect(SlashCatalog.match("", in: commands).count == 3)
        #expect(SlashCatalog.builtins(.claude).contains { $0.name == "compact" })
        #expect(SlashCatalog.builtins(.codex).contains { $0.name == "approvals" })
    }

    @Test func fileIndexSkipsBuildFoldersAndRanksFileNames() throws {
        let root = try folder()
        for path in ["Sources/App/AppDelegate.swift", "Sources/App/Model.swift", "README.md", "node_modules/x/index.js",
                     ".git/HEAD", ".build/debug/App", "docs/app-notes.md"] {
            try write("x", root.appendingPathComponent(path))
        }
        let files = FileIndex.files(in: root.path, limit: 100)
        #expect(files.sorted() == ["README.md", "Sources/App/AppDelegate.swift", "Sources/App/Model.swift", "docs/app-notes.md"])
        #expect(FileIndex.match("appdel", in: files).first == "Sources/App/AppDelegate.swift")
        #expect(FileIndex.files(in: root.path, limit: 2).count == 2)
    }
}
