import Foundation
import Testing
@testable import VibeCore

/// `HookInstaller.checkInstall` and `whyNot` (`Sources/VibeCore/V2/HookInstallCheck.swift`): what the node's
/// `hooks install` asks before it puts the hooks' programs in place, and the words of its refusal.
struct HookInstallCheckTests {
    private static let binary = "/h/vibeswitcher-hook"
    private let scratch = Scratch()

    private func folder() throws -> URL {
        let url = scratch.url("check")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The check and the install give the same answer for a config neither can edit, and neither writes: no file, no
    /// backup, nothing left beside it.
    @Test func aConfigTheInstallWouldRefuseIsRefusedByTheCheckAndNothingIsWritten() throws {
        let folder = try folder()
        let broken: [(name: String, text: String, why: String?)] = [
            ("cut short", "{\"model\": ", "it isn't valid JSON"),
            ("not JSON", "model = \"opus\"\n", "it isn't valid JSON"),
            ("an array", "[{\"hooks\": {}}]\n", "it isn't a JSON object"),
            ("a string", "\"hooks\"", nil),
            ("two hooks keys", "{\"hooks\": {}, \"model\": \"opus\", \"hooks\": {\"Stop\": []}}\n", nil),
        ]
        for agent in Agent.allCases {
            for (index, (name, text, why)) in broken.enumerated() {
                let url = folder.appendingPathComponent("\(agent.rawValue)-\(index)/config.json")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
                var said: [String] = []
                do {
                    try HookInstaller.checkInstall(agent: agent, at: url, hookBinary: Self.binary)
                    Issue.record("\(agent), \(name): the check passed")
                } catch {
                    said.append(HookInstaller.whyNot(error))
                }
                do {
                    try HookInstaller.install(agent: agent, at: url, hookBinary: Self.binary)
                    Issue.record("\(agent), \(name): the install went in")
                } catch {
                    said.append(HookInstaller.whyNot(error))
                }
                #expect(said.count == 2 && said.first == said.last, "\(agent), \(name): \(said)")
                for line in said {
                    #expect(!line.isEmpty && !line.contains("\n") && !line.contains("could not be completed"), "\(agent), \(name): \(line)")
                    if let why { #expect(line.hasPrefix(why), "\(agent), \(name): \(line)") }
                }
                #expect(try Data(contentsOf: url) == Data(text.utf8), "\(agent), \(name)")
                #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["config.json"],
                        "\(agent), \(name)")
            }
            // A folder where the file should be: neither reads it.
            let taken = folder.appendingPathComponent("\(agent.rawValue)-folder/config.json")
            try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)
            #expect(throws: (any Error).self) { try HookInstaller.checkInstall(agent: agent, at: taken, hookBinary: Self.binary) }
            #expect(throws: (any Error).self) { try HookInstaller.install(agent: agent, at: taken, hookBinary: Self.binary) }
        }
    }

    /// A config the install can edit passes the check, which writes nothing: a missing file isn't made, an empty one
    /// stays empty, and one with the user's own hooks and booleans keeps its bytes and its date.
    @Test func aConfigTheInstallCanEditPassesTheCheckUnwritten() throws {
        let folder = try folder()
        let fine = [
            nil, "", "  \n", "{}", "{\"model\": \"opus\"}\n",
            "{\n  \"alwaysThinkingEnabled\": true,\n  \"hooks\": {\"Stop\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"/usr/bin/true\", \"async\": true}]}]}\n}\n",
        ]
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        for agent in Agent.allCases {
            for (index, text) in fine.enumerated() {
                let url = folder.appendingPathComponent("\(agent.rawValue)-fine-\(index)/config.json")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let text {
                    try Data(text.utf8).write(to: url)
                    try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
                }
                #expect(throws: Never.self, "\(agent), \(text ?? "no file")") {
                    try HookInstaller.checkInstall(agent: agent, at: url, hookBinary: Self.binary)
                }
                if let text {
                    #expect(try Data(contentsOf: url) == Data(text.utf8))
                    #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == past)
                    #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["config.json"])
                } else {
                    #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).isEmpty)
                }
                // And the install it stood for goes in; checked again over it, there is nothing to do.
                #expect(throws: Never.self, "\(agent), \(text ?? "no file")") {
                    try HookInstaller.install(agent: agent, at: url, hookBinary: Self.binary)
                    try HookInstaller.checkInstall(agent: agent, at: url, hookBinary: Self.binary)
                }
                #expect(HookInstaller.isComplete(in: try HookInstaller.readConfigThrowing(url), agent: agent))
            }
        }
    }

    /// Each error an edit throws, as the refusal's words: never Foundation's "The operation could not be completed.
    /// (NSCocoaErrorDomain error 512.)", which is what the first Linux node's install said.
    @Test func eachErrorOfAnEditHasWordsOfItsOwn() {
        #expect(HookInstaller.whyNot(HookInstaller.EditError.changed("/h/.claude/settings.json"))
            == "it kept changing while VibeSwitcher was editing it; try again")
        #expect(HookInstaller.whyNot(CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: "/h/.claude/settings.json"]))
            .hasPrefix("VibeSwitcher's edit didn't read back as the config it meant, so it wasn't written"))
        #expect(HookInstaller.whyNot(CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: "/h/.claude/settings.json"]))
            == "it isn't a JSON object")
        #expect(HookInstaller.whyNot(CocoaError(.fileReadCorruptFile)) == "its text couldn't be followed to one top-level \"hooks\" key")
        #expect(HookInstaller.whyNot(Platform.Errno(code: EACCES)) == String(cString: strerror(EACCES)))
        #expect(HookInstaller.whyNot(POSIXError(.ELOOP)) == String(cString: strerror(ELOOP)))
        let other = HookInstaller.whyNot(CocoaError(.fileReadNoPermission))
        #expect(!other.isEmpty && !other.hasPrefix("The operation could not be completed. "), "\(other)")
    }
}
