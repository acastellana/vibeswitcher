import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// Editing the node's launch presets (`PresetEditRequest.swift`, `vibeswitcher preset`, the page-actions lane of
/// 2026-11-20): a preset added, changed or removed in `presets.json` in the user's voice, under the rules the node
/// starts presets by, the rest of the file kept as it was, and the file then held by the seal until the user accepts
/// it. Only scratch sessions start (AGENTS.md).
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct PresetEditTests {
    private let scratch = Scratch()

    private static let project = "/home/u/acme"

    /// A request's args from plain values (strings, booleans, lists and maps of them, or wire values).
    private static func wire(_ args: [String: Any]) -> [String: NodeWire.Value] { args.mapValues(value) }

    private static func value(_ any: Any) -> NodeWire.Value {
        switch any {
        case let value as NodeWire.Value: return value
        case let text as String: return .string(text)
        case let flag as Bool: return .bool(flag)
        case let number as Int: return .int(number)
        case let list as [Any]: return .array(list.map(value))
        case let map as [String: Any]: return .object(map.mapValues(value))
        default: return .null
        }
    }

    private func asked(_ args: [String: Any]) throws -> PresetEdit.Asked {
        switch PresetEdit.asked(Self.wire(args)) {
        case .success(let asked): return asked
        case .failure(let refusal): throw refusal
        }
    }

    private func applied(_ args: [String: Any], to data: Data?) throws -> Result<PresetEdit.Done, SessionPresets.Refusal> {
        PresetEdit.apply(try asked(args), to: data)
    }

    private func data(_ result: Result<PresetEdit.Done, SessionPresets.Refusal>) throws -> Data {
        switch result {
        case .success(let done): return done.data
        case .failure(let refusal): Issue.record("refused: \(refusal.message)"); throw refusal
        }
    }

    private func refusal(_ result: Result<PresetEdit.Done, SessionPresets.Refusal>) -> String? {
        if case .failure(let refusal) = result { return refusal.message }
        return nil
    }

    // MARK: The edit

    /// A first preset makes the file as the app writes it (the built-ins first), and the folder's default.
    @Test func aFirstPresetMakesTheFileWithTheBuiltIns() throws {
        let made = try data(applied(["op": "add", "name": "Opus", "folder": NodeWire.Value.string(Self.project + "/"), "args": "--model opus",
                                     "env": ["MAX_THINKING_TOKENS": "16000"], "keepShell": true, "default": true], to: nil))
        let presets = SessionPresets.decode(made).presets
        #expect(presets.global == LaunchPresets.builtIns().global)
        let opus = try #require(presets.byProject[Self.project]?.first)
        #expect(opus.name == "Opus" && opus.kind == .claude && opus.command == "claude --model opus" && opus.env == ["MAX_THINKING_TOKENS": "16000"] && opus.keepShell)
        #expect(presets.defaults[Self.project] == opus.id)
        let listed = SessionPresets.list(presets, folder: Self.project + "/src")
        #expect(listed.first?.preset.name == "Opus" && listed.first?.isDefault == true && listed.first?.refusal == nil)
        // A shell, every folder's.
        let shell = try data(applied(["op": "add", "name": "Tests shell", "kind": "shell"], to: made))
        #expect(SessionPresets.decode(shell).presets.global.map(\.name) == ["Claude", "Codex", "Shell", "Tests shell"])
    }

    /// What the node wouldn't start it doesn't write: a variable outside the reviewed few, a built-in's name, Codex,
    /// arguments that aren't plain words, a name taken, a bad name; nor does it edit a built-in, a preset changed since
    /// it was shown, one that isn't there, or a file it can't read.
    @Test func whatTheNodeWouldntStartIsntWritten() throws {
        let base = try data(applied(["op": "add", "name": "Fast", "folder": NodeWire.Value.string(Self.project), "args": "--model sonnet"], to: nil))
        let add = { (extra: [String: Any]) in try self.applied(["op": "add", "name": "New", "folder": NodeWire.Value.string(Self.project)].merging(extra) { $1 }, to: base) }
        #expect(refusal(try add(["env": ["PATH": "/tmp/evil"]]))?.contains("which a preset may not set") == true)
        #expect(refusal(try add(["env": ["NODE_OPTIONS": "--require x"]]))?.contains("which a preset may not set") == true)
        #expect(refusal(try add(["name": "shell"]))?.contains("built-in preset's name") == true)
        #expect(refusal(try add(["args": "--model $(id)"]))?.contains("plain words") == true)
        #expect(refusal(try add(["name": "fast"]))?.contains("already") == true, "a name taken, ignoring case")
        #expect(refusal(try add(["name": "-x"]))?.contains("doesn't start with -") == true)
        #expect(refusal(try add(["name": "a\u{7}b"]))?.contains("control") == true)
        if case .success = PresetEdit.asked(Self.wire(["op": "add", "name": "C", "kind": "codex"])) { Issue.record("Codex taken") }
        if case .success = PresetEdit.asked(Self.wire(["op": "edit", "name": "Fast"])) { Issue.record("an edit with no digest taken") }
        if case .success = PresetEdit.asked(Self.wire(["op": "add", "name": "D", "default": true])) { Issue.record("a default with no folder taken") }
        if case .success = PresetEdit.asked(Self.wire(["op": "add", "name": "D", "folder": "relative/path"])) { Issue.record("a relative folder taken") }

        let fast = try #require(SessionPresets.decode(base).presets.byProject[Self.project]?.first)
        let claude = try #require(LaunchPresets.builtIns().global.first)
        #expect(refusal(try applied(["op": "edit", "name": "Claude", "digest": NodeWire.Value.string(SessionPresets.digest(claude)), "args": "--x"], to: base))?
            .contains("built-in preset") == true)
        #expect(refusal(try applied(["op": "remove", "name": "Fast", "folder": NodeWire.Value.string(Self.project), "digest": NodeWire.Value.string(String(repeating: "0", count: 64))], to: base))?
            .contains("changed since it was shown") == true)
        #expect(refusal(try applied(["op": "remove", "name": "Nope", "folder": NodeWire.Value.string(Self.project), "digest": NodeWire.Value.string(SessionPresets.digest(fast))], to: base))?
            .contains("no preset Nope") == true)
        #expect(refusal(try applied(["op": "remove", "name": "Fast", "digest": NodeWire.Value.string(SessionPresets.digest(fast))], to: base))?
            .contains("no preset Fast of yours for every folder") == true, "a folder's preset is named with its folder")
        #expect(refusal(try applied(["op": "add", "name": "New"], to: Data("{ not json".utf8)))?.contains("isn't readable JSON") == true)
        #expect(refusal(try applied(["op": "edit", "name": "New", "digest": "x", "args": ""], to: nil))?.contains("no presets of yours") == true)
    }

    /// An edit changes what it names and keeps the preset's id (a folder's default stays it); a remove takes the
    /// default with it. Everything else in the file, a field or an entry this build doesn't know, stays as it was.
    @Test func anEditChangesOnlyWhatItNames() throws {
        let other: [String: Any] = ["name": "Other", "kind": "claude", "command": "claude", "env": [String: String](), "keepShell": false,
                                    "id": UUID().uuidString, "place": "window", "colour": "teal"]
        let file: [String: Any] = ["global": LaunchPresets.builtIns().global.compactMap(PresetEdit.json) + [other, ["kind": "nameless"]],
                                   "byProject": [String: Any](), "defaults": [String: Any](), "futureSetting": ["a": 1]]
        let start = try JSONSerialization.data(withJSONObject: file)
        let added = try data(applied(["op": "add", "name": "Fast", "folder": NodeWire.Value.string(Self.project), "args": "--model sonnet",
                                      "env": ["ANTHROPIC_MODEL": "sonnet", "DISABLE_TELEMETRY": "1"], "default": true], to: start))
        let fast = try #require(SessionPresets.decode(added).presets.byProject[Self.project]?.first)

        let edited = try data(applied(["op": "edit", "name": "Fast", "folder": NodeWire.Value.string(Self.project + "/sub"), "digest": NodeWire.Value.string(SessionPresets.digest(fast)),
                                       "rename": "Faster", "args": "--model opus", "unset": ["DISABLE_TELEMETRY"], "env": ["MAX_THINKING_TOKENS": "9000"],
                                       "keepShell": true], to: added))
        let presets = SessionPresets.decode(edited).presets
        let faster = try #require(presets.byProject[Self.project]?.first)
        #expect(faster.id == fast.id && faster.name == "Faster" && faster.command == "claude --model opus" && faster.keepShell)
        #expect(faster.env == ["ANTHROPIC_MODEL": "sonnet", "MAX_THINKING_TOKENS": "9000"])
        #expect(presets.defaults[Self.project] == fast.id)
        let raw = try #require(try JSONSerialization.jsonObject(with: edited) as? [String: Any])
        #expect((raw["futureSetting"] as? [String: Int]) == ["a": 1])
        let global = try #require(raw["global"] as? [[String: Any]])
        #expect(global.contains { $0["name"] as? String == "Other" && $0["colour"] as? String == "teal" })
        #expect(global.contains { $0["kind"] as? String == "nameless" }, "an entry this build can't read stays")

        // Kind: a shell has no command.
        let shell = try data(applied(["op": "edit", "name": "Faster", "folder": NodeWire.Value.string(Self.project), "digest": NodeWire.Value.string(SessionPresets.digest(faster)), "kind": "shell"], to: edited))
        #expect(SessionPresets.decode(shell).presets.byProject[Self.project]?.first.map { $0.kind == .shell && $0.command.isEmpty } == true)

        let removed = try data(applied(["op": "remove", "name": "faster", "folder": NodeWire.Value.string(Self.project), "digest": NodeWire.Value.string(SessionPresets.digest(faster))], to: edited))
        let after = SessionPresets.decode(removed).presets
        #expect(after.byProject[Self.project] == [] && after.defaults[Self.project] == nil)
    }

    /// The file is replaced, never written through a link, and not over a change made since it was read.
    @Test func theFileIsReplacedNeverThroughALink() throws {
        let root = scratch.url("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("presets.json")
        #expect(PresetEdit.write(Data("{}".utf8), root: root, was: nil) == nil)
        #expect(try Data(contentsOf: file) == Data("{}".utf8))
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(PresetEdit.write(Data("[1]".utf8), root: root, was: Data("{ other }".utf8))?.message.contains("changed while") == true)
        #expect(try Data(contentsOf: file) == Data("{}".utf8))
        // A link where the file is: refused (it is read with O_NOFOLLOW), and the file it points at untouched.
        let target = scratch.url("elsewhere.json")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        if case .success = SessionPresets.bytes(root: root) { Issue.record("a link read") }
        #expect(try Data(contentsOf: target) == Data("keep".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["presets.json"], "no file left beside it")
    }

    // MARK: On the node

    /// Through the server: the user's edit is recorded and written; the seal then holds the file, so the preset starts
    /// only after the user's accept; a page may not edit; an edit bound to what was shown.
    @Test func anEditIsTheUsersAndTheSealHoldsIt() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let file = world.host.root.appendingPathComponent("presets.json")
        let fromPage = try #require(await world.ask("presets.edit", Self.wire(["op": "add", "name": "Tests shell", "kind": "shell"]), from: NodeLive.webPeer))
        #expect(!fromPage.ok && !FileManager.default.fileExists(atPath: file.path), "\(fromPage)")

        let action = UUID().uuidString.lowercased()
        let added = try #require(await world.ask("presets.edit", Self.wire(["op": "add", "name": "Tests shell", "folder": world.repo, "kind": "shell",
                                                                              "env": ["DISABLE_TELEMETRY": "1"]]), action: action))
        #expect(added.ok && added.result?["held"]?.bool == true && added.result?["folder"]?.string == world.repo, "\(added)")
        #expect(await world.actions().filter { $0.action == action }.map(\.kind) == ["presets.edit"])
        #expect(SessionPresets.load(root: world.host.root).presets.byProject[world.repo]?.map(\.name) == ["Tests shell"])

        func listed() async throws -> NodeWire.Value {
            let list = try #require(await world.ask("session.presets", ["folder": NodeWire.Value.string(world.repo)], action: nil))
            return try #require(list.result?["presets"]?.array?.first { $0["name"]?.string == "Tests shell" })
        }
        func start() async throws -> NodeWire.Reply {
            try #require(await world.ask("session.new", ["folder": NodeWire.Value.string(world.repo), "preset": NodeWire.Value.string("Tests shell"), "digest": try await listed()["digest"] ?? .null]))
        }
        let held = try await start()
        #expect(held.error?.message.contains("accept the presets first") == true, "\(held)")
        let card = try #require(await world.ask("config.held", ["folder": NodeWire.Value.string(world.repo)])?.result?["card"]?["id"]?.string)
        #expect(try #require(await world.ask("config.accept", ["card": NodeWire.Value.string(card), "code": NodeWire.Value.string(NodeIds.code(card: card))])).ok)
        #expect(try await start().ok)

        // Edited as shown; the same edit again, from what was shown before it, is refused.
        let digest = try await listed()["digest"] ?? .null
        let edit = Self.wire(["op": "edit", "name": "Tests shell", "folder": world.repo, "digest": digest, "keepShell": true])
        #expect(try #require(await world.ask("presets.edit", edit)).ok)
        let stale = try #require(await world.ask("presets.edit", edit))
        #expect(stale.error?.code == NodeWire.Code.refused.rawValue && stale.error?.message.contains("changed since it was shown") == true, "\(stale)")
        // Changed again: held until accepted again.
        #expect(try await start().error?.message.contains("accept the presets first") == true)
    }

    /// Through the command line on a scratch node: `preset add` shows the change (a secret-looking value masked) before
    /// the code; a variable outside the reviewed few is refused before any code; `edit` and `remove` act on what
    /// `presets` lists.
    @Test func theCommandLineAddsEditsAndRemovesAPreset() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let folder = node.root.appendingPathComponent("work").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let file = node.root.appendingPathComponent("presets.json")

        let added = try await node.runOnTerminal(["preset", "add", "Fast", "--folder", folder, "--args", "--model sonnet", "--env", "ANTHROPIC_MODEL=sonnet-x", "--default"])
        #expect(added.status == 0 && added.output.contains("added: preset Fast for \(folder)") && added.output.contains("config held"), "\(added.output)\(added.errors)")
        #expect(added.output.contains("This adds preset Fast for \(folder): runs `claude --model sonnet`; sets ANTHROPIC_MODEL=sonnet-x; the folder's default."),
                "\(added.output)")
        let presets = SessionPresets.load(root: node.root).presets
        #expect(presets.byProject[folder]?.first?.command == "claude --model sonnet" && presets.defaults[folder] == presets.byProject[folder]?.first?.id)

        let refused = try await node.runOnTerminal(["preset", "add", "Evil", "--env", "LD_PRELOAD=/x.so"])
        #expect(refused.status == 77 && (refused.output + refused.errors).contains("LD_PRELOAD") && !refused.output.contains("Type "), "\(refused.output)\(refused.errors)")

        let edited = try await node.runOnTerminal(["preset", "edit", "fast", "--folder", folder, "--rename", "Faster", "--keep-shell"])
        #expect(edited.status == 0 && edited.output.contains("changed: preset Faster"), "\(edited.output)\(edited.errors)")
        #expect(SessionPresets.load(root: node.root).presets.byProject[folder]?.first.map { $0.name == "Faster" && $0.keepShell } == true)
        let builtIn = try await node.runOnTerminal(["preset", "edit", "Shell", "--keep-shell"])
        #expect(builtIn.status == 77 && (builtIn.output + builtIn.errors).contains("built-in"), "\(builtIn.output)\(builtIn.errors)")
        let removed = try await node.runOnTerminal(["preset", "remove", "Faster", "--folder", folder])
        #expect(removed.status == 0 && removed.output.contains("removed: preset Faster"), "\(removed.output)\(removed.errors)")
        #expect(SessionPresets.load(root: node.root).presets.byProject[folder] == [])
        #expect(try String(contentsOf: file, encoding: .utf8).contains("\"Claude\""), "the built-ins kept in the file")

        for words in [["preset"], ["preset", "add"], ["preset", "add", "--x"], ["preset", "edit", "A"], ["preset", "remove", "A", "--shell"],
                      ["preset", "add", "A", "--default"], ["preset", "add", "A", "--shell", "--args", "x"], ["preset", "add", "A", "--env", "NOEQUALS"]] {
            let usage = try await node.run(words)
            #expect(usage.status == 64, "\(words): \(usage.output)\(usage.errors)")
        }
    }
}
