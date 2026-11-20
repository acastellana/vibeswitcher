import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// Launch presets on the node (the parity table's row, 2026-11-20): read where the app keeps them (`presets.json` in the
/// node's root), listed for a folder as the app's New Session lists them, and started by `session.new` with `preset`,
/// bound to what was shown by its digest. Only scratch sessions are started (AGENTS.md).
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct SessionPresetsTests {
    private let scratch = Scratch()

    private static let project = "/home/u/acme"

    /// A project's own Opus (its default) and a shell with a variable that stays open, and the built-ins.
    private static let presets: LaunchPresets = {
        var presets = LaunchPresets.builtIns()
        let opus = LaunchPreset(name: "Opus", kind: .claude, command: "claude --model opus --add-dir ../shared", env: ["MAX_THINKING_TOKENS": "16000"])
        let shell = LaunchPreset(name: "Tests shell", kind: .shell, command: "", env: ["RUN_SLOW": "1"], keepShell: true)
        presets.byProject[project] = [shell, opus]
        presets.defaults[project] = opus.id
        return presets
    }()

    // MARK: The list

    @Test func aFoldersDefaultComesFirstThenItsOwnThenTheGlobalOnes() {
        let listed = SessionPresets.list(Self.presets, folder: Self.project + "/Sources/App")
        #expect(listed.map(\.preset.name) == ["Opus", "Tests shell", "Claude", "Codex", "Shell"])
        #expect(listed.map(\.isDefault) == [true, false, false, false, false])
        #expect(listed.map(\.project) == [true, true, false, false, false])
        // Codex isn't on the node; the rest can start.
        #expect(listed.map { $0.refusal == nil } == [true, true, true, false, true])
        // Another folder (one whose name only begins the same) has the global ones alone.
        #expect(SessionPresets.list(Self.presets, folder: Self.project + "-old").map(\.preset.name) == ["Claude", "Codex", "Shell"])
        #expect(SessionPresets.named("opus", in: listed)?.preset.name == "Opus")
        #expect(SessionPresets.named("Nope", in: listed) == nil)
    }

    @Test func whatTheNodeCantStartSaysWhy() {
        let cases: [(LaunchPreset, String)] = [
            (LaunchPreset(name: "Codex", kind: .codex, command: "codex"), "Codex"),
            (LaunchPreset(name: "Lead · acme", kind: .claude, command: "claude"), "a lead's"),
            (LaunchPreset(name: "Mine", kind: .claude, command: "/opt/claude --model opus"), "starts /opt/claude"),
            (LaunchPreset(name: "Mine", kind: .claude, command: "claude; rm -rf ~"), "starts claude;"),
            (LaunchPreset(name: "Mine", kind: .claude, command: "claude --x ; rm -rf ~"), "plain words"),
            (LaunchPreset(name: "Mine", kind: .claude, command: "claude --append-system-prompt \"be brief\""), "plain words"),
            (LaunchPreset(name: "Mine", kind: .claude, command: "claude $(id)"), "plain words"),
            (LaunchPreset(name: "Mine", kind: .shell, command: "", env: ["LD_PRELOAD": "/x.so"]), "LD_PRELOAD"),
            (LaunchPreset(name: "Mine", kind: .shell, command: "", env: ["VIBESWITCHER_HOME": "/elsewhere"]), "VIBESWITCHER_HOME"),
            (LaunchPreset(name: "Mine", kind: .shell, command: "", env: ["1BAD": "x"]), "isn't a variable's name"),
        ]
        for (preset, says) in cases {
            let why = SessionPresets.refusal(preset)
            #expect(why?.contains(says) == true, "\(preset.command) \(preset.env): \(String(describing: why))")
        }
        let fine = LaunchPreset(name: "Opus", kind: .claude, command: "claude --model opus  --add-dir ../shared")
        #expect(SessionPresets.refusal(fine) == nil)
        #expect(SessionPresets.command(fine, program: "/home/u/.local/share/claude/versions/2.1.330")
                == "'/home/u/.local/share/claude/versions/2.1.330' '--model' 'opus' '--add-dir' '../shared'")
        #expect(SessionPresets.command(LaunchPreset(name: "Claude", kind: .claude, command: ""), program: "/c") == "'/c'")
        #expect(SessionPresets.command(LaunchPreset(name: "Shell", kind: .shell, command: ""), program: "/c") == nil)
    }

    @Test func theDigestChangesWithWhatTheUserIsShown() {
        let opus = LaunchPreset(name: "Opus", kind: .claude, command: "claude --model opus", env: ["A": "1"])
        let digest = SessionPresets.digest(opus)
        var changed = opus
        changed.env["A"] = "2"
        #expect(SessionPresets.digest(changed) != digest)
        changed = opus
        changed.command = "claude --model sonnet"
        #expect(SessionPresets.digest(changed) != digest)
        changed = opus
        changed.keepShell = true
        #expect(SessionPresets.digest(changed) != digest)
        // The id isn't shown, so it isn't bound.
        changed = opus
        changed.id = UUID()
        #expect(SessionPresets.digest(changed) == digest)
        // The wire carries a variable's name, never its value.
        let value = SessionPresets.value(.init(preset: opus, project: false, isDefault: false, refusal: nil))
        #expect(value["env"] == .array([.string("A")]))
        #expect(!String(decoding: NodeWire.line(value), as: UTF8.self).contains("\"1\""))
    }

    @Test func theFileIsReadAsTheAppWritesItAndNeverWritten() throws {
        let root = scratch.url("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(SessionPresets.load(root: root).presets == LaunchPresets.builtIns())
        let file = root.appendingPathComponent("presets.json")
        try Self.presets.save(to: file)
        #expect(SessionPresets.load(root: root).presets == Self.presets)
        try Data("{ not json".utf8).write(to: file)
        let broken = SessionPresets.load(root: root)
        #expect(broken.presets == LaunchPresets.builtIns() && broken.problems.first?.contains("isn't readable JSON") == true, "\(broken.problems)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["presets.json"])
    }

    // MARK: Starting one

    /// The node's `claude` (`NodePreflight.claudeLink` on a scratch root) linked to the world's fake.
    private func linkClaude(_ world: CardWorld) throws {
        let link = world.host.root.appendingPathComponent("v2/test/claude")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: world.world.fake.launcher.path)
    }

    private func hosted(_ world: CardWorld, _ reply: NodeWire.Reply) -> HostSession? {
        guard let id = reply.result?["session"]?.string.flatMap({ UUID(uuidString: String($0.dropFirst(NodeIds.node.count + 1))) }) else { return nil }
        return world.queue.sync { world.world.link.sessions.first { $0.id == id } }
    }

    /// The variables the session's first process started with.
    private func environment(of session: HostSession) -> [String: String] {
        let data = (try? Data(contentsOf: URL(fileURLWithPath: "/proc/\(session.childPID)/environ"))) ?? Data()
        var found: [String: String] = [:]
        for entry in data.split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let equals = text.firstIndex(of: "=") else { continue }
            found[String(text[..<equals])] = String(text[text.index(after: equals)...])
        }
        return found
    }

    @Test func aPresetStartsAsShownAndOneChangedSinceDoesnt() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        try linkClaude(world)
        var presets = LaunchPresets.builtIns()
        let opus = LaunchPreset(name: "Opus", kind: .claude, command: "claude --model opus", env: ["MAX_THINKING_TOKENS": "16000"])
        let shell = LaunchPreset(name: "Tests shell", kind: .shell, command: "", env: ["RUN_SLOW": "1"], keepShell: true)
        presets.byProject[world.repo] = [opus, shell]
        try presets.save(to: world.host.root.appendingPathComponent("presets.json"))

        let list = try #require(await world.ask("session.presets", ["folder": .string(world.repo)], action: nil))
        let names = list.result?["presets"]?.array?.compactMap { $0["name"]?.string }
        #expect(names == ["Opus", "Tests shell", "Claude", "Codex", "Shell"], "\(list)")
        let shown = try #require(list.result?["presets"]?.array?.first)
        #expect(WireSchema.check(try #require(list.result), as: "session.presets.result", strict: true) == nil)

        let action = UUID().uuidString.lowercased()
        let reply = try #require(await world.ask("session.new", ["folder": .string(world.repo), "preset": .string("opus"),
                                                                 "digest": shown["digest"] ?? .null], action: action))
        #expect(reply.ok && reply.result?["preset"]?.string == "Opus" && reply.result?["agent"]?.string == "claude", "\(reply)")
        let session = try #require(hosted(world, reply))
        #expect(session.label == "Opus" && session.agent == "claude", "\(session)")
        #expect(session.command?.hasSuffix("'--model' 'opus'") == true, "\(String(describing: session.command))")
        #expect(environment(of: session)["MAX_THINKING_TOKENS"] == "16000")
        #expect(await world.actions().filter { $0.action == action }.map(\.kind) == ["session.new"])

        // The shell preset, as listed: its variable and the shell that stays.
        let shellDigest = SessionPresets.digest(shell)
        let started = try #require(await world.ask("session.new", ["folder": .string(world.repo), "preset": .string("Tests shell"),
                                                                   "digest": .string(shellDigest)]))
        let shellSession = try #require(hosted(world, started))
        #expect(shellSession.label == "Tests shell" && shellSession.agent == nil && environment(of: shellSession)["RUN_SLOW"] == "1", "\(started)")

        // Changed since it was shown: nothing starts.
        var changed = presets
        changed.byProject[world.repo]?[0].env["MAX_THINKING_TOKENS"] = "64000"
        try changed.save(to: world.host.root.appendingPathComponent("presets.json"))
        let live = world.queue.sync { world.world.link.sessions.filter(\.isLive).count }
        let stale = try #require(await world.ask("session.new", ["folder": .string(world.repo), "preset": .string("Opus"), "digest": shown["digest"] ?? .null]))
        #expect(stale.error?.code == NodeWire.Code.refused.rawValue && stale.error?.message.contains("changed since it was shown") == true, "\(stale)")
        let cases: [([String: NodeWire.Value], NodeWire.Code, String)] = [
            (["folder": .string(world.repo), "preset": .string("Codex"), "digest": .string("x")], .refused, "Codex"),
            (["folder": .string(world.repo), "preset": .string("Nope"), "digest": .string("x")], .refused, "no preset"),
            (["folder": .string(world.repo), "preset": .string("Opus")], .badArgs, "digest"),
            (["folder": .string(world.repo), "preset": .string("Opus"), "agent": .string("shell"), "digest": .string("x")], .badArgs, "not both"),
            (["folder": .string(world.repo), "preset": .string("Tests shell"), "model": .string("opus"), "digest": .string(shellDigest)], .refused, "no model"),
        ]
        for (args, code, says) in cases {
            let refused = try #require(await world.ask("session.new", args))
            #expect(refused.error?.code == code.rawValue && refused.error?.message.contains(says) == true, "\(args): \(refused)")
        }
        #expect(world.queue.sync { world.world.link.sessions.filter(\.isLive).count } == live)
    }

    /// Through the command line on a scratch node: `presets` lists them, and `new --preset` shows what it runs (a
    /// variable by name, never its value) before the code, then starts it.
    @Test func theCommandLineListsAndStartsAPreset() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let folder = node.root.appendingPathComponent("work").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        var presets = LaunchPresets.builtIns()
        presets.byProject[folder] = [LaunchPreset(name: "Tests shell", kind: .shell, command: "", env: ["RUN_SLOW": "yes-slow"], keepShell: true)]
        try presets.save(to: node.root.appendingPathComponent("presets.json"))

        let listed = try await node.run(["presets", folder])
        #expect(listed.status == 0, "\(listed.output)\(listed.errors)")
        #expect(listed.output.hasPrefix("Tests shell (a shell; this project's; sets RUN_SLOW; a shell stays when it ends)"), "\(listed.output)")
        #expect(listed.output.contains("Codex (codex: `codex`)\n    can't start here: Codex doesn't run on this node yet"), "\(listed.output)")

        let started = try await node.runOnTerminal(["new", folder, "--preset", "tests shell"])
        #expect(started.status == 0, "\(started.output)\(started.errors)\n\(node.said)")
        #expect(started.output.contains("This starts preset Tests shell (a shell; this project's; sets RUN_SLOW"), "\(started.output)")
        #expect(!started.output.contains("yes-slow"), "\(started.output)")
        #expect(started.output.contains("started: session "), "\(started.output)")

        for words in [["new", folder, "--preset", "Nope"]] {
            let refused = try await node.runOnTerminal(words)
            #expect(refused.status != 0 && refused.output.contains("no preset Nope"), "\(words): \(refused.output)\(refused.errors)")
        }
        for words in [["new", folder, "--preset"], ["new", folder, "--preset", "A", "--agent", "shell"], ["presets", "a", "b"]] {
            let usage = try await node.run(words)
            #expect(usage.status == 64, "\(words): \(usage.output)\(usage.errors)")
        }
    }
}
