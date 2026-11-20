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
        let shell = LaunchPreset(name: "Tests shell", kind: .shell, command: "", env: ["DISABLE_TELEMETRY": "1"], keepShell: true)
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

    /// The digest is keyed by a secret only the server run holds (the security review of 2026-11-20): a page that may
    /// only read can't test guesses of a variable's value (an API key) by hashing them itself.
    @Test func withNoVaultOrAnotherFileNothingStarts() throws {
        let home = scratch.url("home")
        let root = home.appendingPathComponent(".vibeswitcher")
        let read = SessionPresets.decode(Data("{}".utf8))
        #expect(Requests.presetsBaselineRefusal(vault: nil, home: home.path, nodeRoot: root, file: read, folder: "/w")?.contains("no vault") == true)
        #expect(Requests.presetsBaselineRefusal(vault: nil, home: home.path, nodeRoot: scratch.url("elsewhere"), file: read, folder: "/w")?
            .contains("isn't the one the config seal watches") == true)
    }

    /// The file is read once, with O_NOFOLLOW: a link is refused, the hash is the seal's own of the bytes read, and the
    /// presets are decoded from those same bytes, so a change made after the open can't come between.
    @Test func thePresetsFileIsReadOnceAndNeverThroughALink() throws {
        let home = scratch.url("home")
        let root = home.appendingPathComponent(".vibeswitcher")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("presets.json")
        try Self.presets.save(to: file)
        let bytes = try Data(contentsOf: file)
        // The hash is the config seal's own for that file.
        let watched = try #require(ConfigSeal.homeWatched(home: home.path).first { $0.name == SessionPresets.sealName })
        #expect(SessionPresets.read(root: root).fingerprint == ConfigSeal.fingerprint(watched))
        // Changed once it is open: what was read is what is hashed and decoded, and it was opened once.
        var opens = 0
        let changed = LaunchPresets(global: [LaunchPreset(name: "Planted", kind: .shell, command: "", env: ["MAX_THINKING_TOKENS": "1"])])
        let read = SessionPresets.read(root: root) { path in
            opens += 1
            let fd = Sys.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            try? changed.save(to: URL(fileURLWithPath: path))
            return fd
        }
        #expect(opens == 1)
        #expect(read.presets == Self.presets && read.fingerprint == SessionPresets.sealFingerprint(of: bytes))
        #expect(SessionPresets.read(root: root).presets == changed)
        // A link is never followed: the built-ins alone, no hash, said.
        try FileManager.default.removeItem(at: file)
        let target = scratch.url("planted.json")
        try changed.save(to: target)
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: target.path)
        let linked = SessionPresets.read(root: root)
        #expect(linked.fingerprint == nil && linked.presets == LaunchPresets.builtIns() && linked.problems.first?.contains("is a link") == true, "\(linked.problems)")
        #expect(Requests.presetsBaselineRefusal(vault: nil, home: home.path, nodeRoot: root, file: linked, folder: "/w")?.contains("is a link") == true)
    }

    @Test func aVariablesValueCantBeGuessedFromTheDigest() {
        let secret = "value-to-guess-41"
        let real = LaunchPreset(name: "Keyed", kind: .claude, command: "claude", env: ["SOME_TOKEN": secret])
        var guess = real
        guess.env["SOME_TOKEN"] = "value-to-guess-42"
        let shown = SessionPresets.digest(real)
        // Recomputed without the key, by any unkeyed hash of what it covers, the guess and the real value read alike:
        // neither gives the digest shown.
        for unkeyed in [real, guess].flatMap({ preset -> [String] in
            let parts = [preset.name, preset.kind.rawValue, preset.command, "-"] + preset.env.map { "\($0.key)=\($0.value)" }
            return [LeadVaultV2.digest(parts.joined(separator: "\u{0}")), LeadVaultV2.digest((["vibeswitcher-preset"] + parts).joined(separator: "\u{0}"))]
        }) { #expect(unkeyed != shown) }
        // Under another key (another server run, or a page's guess at one) neither matches either.
        let other = SymmetricKey(size: .bits256)
        #expect(SessionPresets.digest(real, key: other) != shown)
        #expect(!SessionPresets.matches(real, digest: SessionPresets.digest(real, key: other)))
        // Under the server's own key it binds: the preset shown matches, one with another value doesn't.
        #expect(SessionPresets.matches(real, digest: shown))
        #expect(!SessionPresets.matches(guess, digest: shown))
        #expect(!SessionPresets.matches(real, digest: "not hex") && !SessionPresets.matches(real, digest: nil))
        // The value reaches neither the wire nor what the command line lists.
        let wire = String(decoding: NodeWire.line(SessionPresets.value(.init(preset: real, project: true, isDefault: true, refusal: nil))), as: UTF8.self)
        #expect(!wire.contains(secret) && wire.contains("SOME_TOKEN"), "\(wire)")
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

    /// A preset may not set a variable that changes what a session runs, where it reads its config, whom it talks to
    /// or what its shell does first (the security review of 2026-11-20: any process of the uid can write the file).
    @Test func aPresetMayNotSetAVariableThatChangesWhatRuns() {
        for name in ["NODE_OPTIONS", "PATH", "HOME", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "ANTHROPIC_BASE_URL", "OPENAI_BASE_URL", "HTTPS_PROXY",
                     "https_proxy", "ALL_PROXY", "PS0", "PS4", "BASH_ENV", "ENV", "PROMPT_COMMAND", "LD_PRELOAD", "DYLD_INSERT_LIBRARIES",
                     "XDG_CONFIG_HOME", "GIT_SSH_COMMAND", "SSL_CERT_FILE", "PYTHONPATH", "BASH_FUNC_x%%", "VIBESWITCHER_HOME", "TMPDIR",
                     "AWS_ENDPOINT_URL", "SHELL", "EDITOR", "NPM_CONFIG_PREFIX", "JAVA_TOOL_OPTIONS",
                     // The allowlist's families: an agent's own, interpreters, pagers, resolvers, any lower-case name.
                     "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_SHELL_PREFIX", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_PLUGIN_ROOT",
                     "NODE_ENV", "PYTHONWARNINGS", "LESSOPEN", "LESSCLOSE", "HOSTALIASES", "RESOLV_HOST_CONF", "PS9", "BASH_COMPAT",
                     "GIT_DIR", "LD_AUDIT", "DYLD_LIBRARY_PATH", "MY_PROXY", "my_var", "A" + String(repeating: "B", count: 41)] {
            #expect(SessionPresets.envRefusal(name) != nil, "\(name)")
        }
        // Only the reviewed few: no user namespace (the final round of 2026-11-20).
        for name in ["RUN_SLOW", "DEBUG", "MY_FLAG", "A" + String(repeating: "B", count: 40)] {
            #expect(SessionPresets.envRefusal(name)?.contains("only Claude Code's reviewed variables") == true, "\(name)")
        }
        #expect(SessionPresets.allowedVariables.count == 20)
        for name in SessionPresets.allowedVariables { #expect(SessionPresets.envRefusal(name) == nil, "\(name)") }
        let planted = LaunchPreset(name: "Opus", kind: .claude, command: "claude", env: ["NODE_OPTIONS": "--require /home/u/x.js", "RUN_SLOW": "1"])
        let why = SessionPresets.refusal(planted)
        #expect(why?.contains("NODE_OPTIONS (a preset sets only Claude Code's reviewed variables") == true, "\(String(describing: why))")
    }

    /// A project's preset named as a built-in one never stands in for it: it can't start, and the name finds the built-in.
    @Test func aPresetCantShadowABuiltInsName() {
        var presets = LaunchPresets.builtIns()
        presets.byProject[Self.project] = [LaunchPreset(name: "Claude", kind: .claude, command: "claude --model opus"),
                                           LaunchPreset(name: "shell", kind: .shell, command: "")]
        presets.defaults[Self.project] = presets.byProject[Self.project]?.first?.id
        let listed = SessionPresets.list(presets, folder: Self.project)
        #expect(listed.first?.refusal?.contains("a built-in preset's") == true, "\(listed)")
        #expect(listed[1].refusal?.contains("a built-in preset's") == true)
        let claude = SessionPresets.named("Claude", in: listed)
        #expect(claude?.refusal == nil && claude?.project == false && claude?.preset.command == "claude")
        #expect(SessionPresets.named("Shell", in: listed)?.project == false)
        // The built-ins come from this build: the file's exact copies are left out, and a file's preset that took a
        // built-in's id (its command edited) is refused, never the built-in; the build's own still starts.
        var edited = LaunchPresets.builtIns()
        edited.global[0].command = "claude --model opus"
        let fromFile = SessionPresets.list(edited, folder: nil)
        #expect(fromFile.map(\.preset.name) == ["Claude", "Claude", "Codex", "Shell"], "\(fromFile)")
        #expect(fromFile[0].refusal?.contains("name or id") == true && !fromFile[0].builtIn)
        #expect(fromFile[1].builtIn && fromFile[1].refusal == nil && fromFile[1].preset.command == "claude")
        let plain = SessionPresets.list(LaunchPresets.builtIns(), folder: nil)
        #expect(plain.allSatisfy { $0.builtIn })
        var renamed = LaunchPresets(global: [LaunchPreset(id: LaunchPresets.builtIns().global[2].id, name: "My shell", kind: .shell, command: "")])
        renamed.byProject = [:]
        #expect(SessionPresets.list(renamed, folder: nil).first?.refusal?.contains("name or id") == true, "an id taken alone")
    }

    /// The confirmation shows each value but a secret-looking one's; a page never gets values.
    @Test func valuesAreShownToATerminalMaskedWhereTheyLookSecret() async throws {
        let preset = LaunchPreset(name: "Mine", kind: .claude, command: "claude",
                                  env: ["RUN_SLOW": "1", "SOME_TOKEN": "abc", "API_PASSWORD": "x", "DEBUG_LEVEL": "sk-" + "abcdef"])
        #expect(SessionPresets.shownValues(preset) == ["RUN_SLOW": "1", "SOME_TOKEN": "<set>", "API_PASSWORD": "<set>", "DEBUG_LEVEL": "<set>"])
        let listed = SessionPresets.Listed(preset: preset, project: false, isDefault: false, refusal: nil)
        #expect(SessionPresets.value(listed)["values"] == nil)
        #expect(SessionPresets.value(listed, values: true)["values"]?["SOME_TOKEN"]?.string == "<set>")

        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        var presets = LaunchPresets.builtIns()
        presets.byProject[world.repo] = [preset]
        try presets.save(to: world.host.root.appendingPathComponent("presets.json"))
        let args: [String: NodeWire.Value] = ["folder": .string(world.repo), "values": .bool(true)]
        let terminal = try #require(await world.ask("session.presets", args, action: nil))
        #expect(terminal.result?["presets"]?.array?.first?["values"]?["RUN_SLOW"]?.string == "1", "\(terminal)")
        #expect(WireSchema.check(try #require(terminal.result), as: "session.presets.result", strict: true) == nil)
        let page = try #require(await world.ask("session.presets", args, action: nil, from: NodeLive.webPeer))
        #expect(page.ok && page.result?["presets"]?.array?.allSatisfy { $0["values"] == nil } == true, "\(page)")
    }

    /// Fail closed: a preset of the file starts only from a file the user's accept sealed (the home's config, once for
    /// every project), and not once it changed since; a built-in needs no accept.
    @Test func aPresetOfTheFileStartsOnlyFromAnAcceptedFile() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let file = world.host.root.appendingPathComponent("presets.json")
        var presets = LaunchPresets.builtIns()
        presets.byProject[world.repo] = [LaunchPreset(name: "Tests shell", kind: .shell, command: "", env: ["DISABLE_TELEMETRY": "1"])]
        try presets.save(to: file)
        func accept() async throws {
            let held = try #require(await world.ask("config.held", ["folder": .string(world.repo)]))
            let card = try #require(held.result?["card"]?["id"]?.string, "\(held)")
            let accepted = try #require(await world.ask("config.accept", ["card": .string(card), "code": .string(NodeIds.code(card: card))]))
            #expect(accepted.ok, "\(accepted)")
        }
        func start() async throws -> NodeWire.Reply {
            let list = try #require(await world.ask("session.presets", ["folder": .string(world.repo)], action: nil))
            let digest = try #require(list.result?["presets"]?.array?.first?["digest"])
            return try #require(await world.ask("session.new", ["folder": .string(world.repo), "preset": .string("Tests shell"), "digest": digest]))
        }
        let unaccepted = try await start()
        #expect(unaccepted.error?.code == NodeWire.Code.refused.rawValue
                && unaccepted.error?.message.contains("the vault holds no accepted presets: accept the presets first (`vibeswitcher config held") == true,
                "\(unaccepted)")
        // A built-in starts all the same.
        let builtIn = try #require(await world.ask("session.presets", ["folder": .string(world.repo)], action: nil))?.result?["presets"]?.array?
            .first { $0["name"]?.string == "Shell" }
        #expect(builtIn?["builtIn"]?.bool == true)
        #expect(try #require(await world.ask("session.new", ["folder": .string(world.repo), "preset": .string("Shell"),
                                                             "digest": builtIn?["digest"] ?? .null])).ok)
        try await accept()
        #expect(try await start().ok)

        presets.byProject[world.repo]?[0].env["DISABLE_TELEMETRY"] = "2"
        try presets.save(to: file)
        let refused = try await start()
        #expect(refused.error?.code == NodeWire.Code.refused.rawValue && refused.error?.message.contains("accept the presets first") == true, "\(refused)")
        try await accept()
        #expect(try await start().ok)
    }

    // MARK: Starting one

    /// A seal the vault made without the user's explicit accept of the presets file (an app's look with no card seals
    /// what didn't move) starts nothing; the user's accept of it, once it shows as held, does.
    @Test func aPresetsFileSealedByALookAloneStartsNothing() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let file = world.host.root.appendingPathComponent("presets.json")
        var presets = LaunchPresets.builtIns()
        presets.byProject[world.repo] = [LaunchPreset(name: "Tests shell", kind: .shell, command: "", env: ["DISABLE_TELEMETRY": "1"])]
        try presets.save(to: file)
        try await acceptConfig(world)
        // Changed, then sealed by a look with no card: the vault's record matches the file, but no accept of the user's.
        presets.byProject[world.repo]?[0].env["DISABLE_TELEMETRY"] = "0"
        try presets.save(to: file)
        let vault = world.host.vault
        _ = try await offPool { try vault.checkConfig(root: world.repo, shown: [:]) }
        _ = try await offPool { try vault.checkConfig(root: world.repo) }
        let record = try #require(try await offPool { try vault.guardedRecord(root: SessionPresets.acceptRoot(nodeRoot: world.host.root)) })
        #expect(record[ConfigSeal.keyPrefix + SessionPresets.sealName] == SessionPresets.read(root: world.host.root).fingerprint, "sealed by the look")
        func start() async throws -> NodeWire.Reply {
            let list = try #require(await world.ask("session.presets", ["folder": .string(world.repo)], action: nil))
            let digest = try #require(list.result?["presets"]?.array?.first?["digest"])
            return try #require(await world.ask("session.new", ["folder": .string(world.repo), "preset": .string("Tests shell"), "digest": digest]))
        }
        let refused = try await start()
        #expect(refused.error?.message.contains("never accepted by you") == true, "\(refused)")
        // Changed again, held, and accepted by the user: it starts.
        presets.byProject[world.repo]?[0].env["DISABLE_TELEMETRY"] = "1"
        try presets.save(to: file)
        try await acceptConfig(world)
        #expect(try await start().ok)
    }

    /// The user's `config held` and `config accept` for the world's repository: the home's config, the presets file
    /// among it, sealed as it is now.
    private func acceptConfig(_ world: CardWorld) async throws {
        let held = try #require(await world.ask("config.held", ["folder": .string(world.repo)]))
        let card = try #require(held.result?["card"]?["id"]?.string, "\(held)")
        let accepted = try #require(await world.ask("config.accept", ["card": .string(card), "code": .string(NodeIds.code(card: card))]))
        #expect(accepted.ok, "\(accepted)")
    }

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
        let shell = LaunchPreset(name: "Tests shell", kind: .shell, command: "", env: ["DISABLE_TELEMETRY": "1"], keepShell: true)
        presets.byProject[world.repo] = [opus, shell]
        try presets.save(to: world.host.root.appendingPathComponent("presets.json"))
        try await acceptConfig(world)

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
        // The program's environment is the launcher's until it has exec'd it: waited for, not read at once.
        #expect(await eventually { environment(of: session)["MAX_THINKING_TOKENS"] == "16000" })
        #expect(await world.actions().filter { $0.action == action }.map(\.kind) == ["session.new"])

        // The shell preset, as listed: its variable and the shell that stays.
        let shellDigest = SessionPresets.digest(shell)
        let started = try #require(await world.ask("session.new", ["folder": .string(world.repo), "preset": .string("Tests shell"),
                                                                   "digest": .string(shellDigest)]))
        let shellSession = try #require(hosted(world, started))
        #expect(shellSession.label == "Tests shell" && shellSession.agent == nil, "\(started)")
        #expect(await eventually { environment(of: shellSession)["DISABLE_TELEMETRY"] == "1" }, "\(started)")

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
        presets.byProject[folder] = [LaunchPreset(name: "Tests shell", kind: .shell, command: "", env: ["DISABLE_TELEMETRY": "yes-quiet"], keepShell: true),
                                     LaunchPreset(name: "Keyed", kind: .shell, command: "", env: ["SOME_TOKEN": "value-to-hide-7"])]
        try presets.save(to: node.root.appendingPathComponent("presets.json"))

        let listed = try await node.run(["presets", folder])
        #expect(listed.status == 0, "\(listed.output)\(listed.errors)")
        #expect(listed.output.hasPrefix("Tests shell (a shell; this project's; sets DISABLE_TELEMETRY=yes-quiet; a shell stays when it ends)"),
                "\(listed.output)")
        // A variable outside the reviewed few: listed with its value masked, and refused.
        #expect(listed.output.contains("Keyed (a shell; this project's; sets SOME_TOKEN=<set>)\n    can't start here: its environment sets SOME_TOKEN"),
                "\(listed.output)")
        #expect(listed.output.contains("Codex (codex: `codex`)\n    can't start here: Codex doesn't run on this node yet"), "\(listed.output)")

        // A scratch node's presets file isn't the one its home's seal watches, so no accept covers it: refused, failing
        // closed, after the confirmation showed it.
        let started = try await node.runOnTerminal(["new", folder, "--preset", "tests shell"])
        #expect(started.status == 77 && started.output.contains("isn't the one the config seal watches"), "\(started.output)\(started.errors)\n\(node.said)")
        // The confirmation shows each value (the security review of 2026-11-20).
        #expect(started.output.contains("This starts preset Tests shell (a shell; this project's; sets DISABLE_TELEMETRY=yes-quiet"), "\(started.output)")
        #expect(!listed.output.contains("value-to-hide-7"), "\(listed.output)")
        // Nor the server's log, either value.
        #expect(!node.said.contains("value-to-hide-7") && !node.said.contains("yes-quiet"))
        let builtIn = try await node.runOnTerminal(["new", folder, "--preset", "shell"])
        #expect(builtIn.status == 0 && builtIn.output.contains("started: session "), "\(builtIn.output)\(builtIn.errors)")

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
