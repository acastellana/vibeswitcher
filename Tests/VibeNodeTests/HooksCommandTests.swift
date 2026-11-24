import Foundation
import Testing
@testable import VibeCore
import VibeNode
@testable import VibePlatform

/// `vibeswitcher hooks install|remove` through a scratch node's server (the start plan's S6, ST-D17): the server writes
/// in its own home (the scratch home), as the app, so the change is sealed; the command line writes nothing and its
/// `CLAUDE_CONFIG_DIR` plays no part. Never the user's own ~/.claude, ~/.codex or ~/.vibeswitcher.
///
/// `ScratchNode` links its build's `bin/` to the built products; the server opens the programs it installs without
/// following a link, so each case first puts a copy of the two in place of their links (`ownPrograms`). The built
/// products themselves are never written.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(10)))
struct HooksCommandTests {
    private let scratch = Scratch()

    /// Claude Code's events the hook listens to (`HookInstaller.claudeEvents`).
    static let claudeEvents: Set<String> = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                                            "PermissionRequest", "Notification", "Stop", "PreCompact"]

    static let programs = ["vibeswitcher-hook", "vibeswitcher-mcp"]

    // MARK: Helpers

    /// The node's build's `bin/<name>` for each of the two programs: a copy of the built product in place of the link.
    private func ownPrograms(_ node: ScratchNode) throws {
        for name in Self.programs { try replace(node.nodeRoot.appendingPathComponent("bin/" + name), withCopyOf: builtProducts.appendingPathComponent(name)) }
    }

    /// `target` replaced (renamed over) with a closed copy of `source`.
    private func replace(_ target: URL, withCopyOf source: URL) throws {
        let copy = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).copy")
        try copyClosedOnExec(source.path, to: copy.path)
        guard rename(copy.path, target.path) == 0 else { throw Platform.Errno(code: errno) }
    }

    private func settings(_ node: ScratchNode) -> URL { node.home.appendingPathComponent(".claude/settings.json") }
    private func codexHooks(_ node: ScratchNode) -> URL { node.home.appendingPathComponent(".codex/hooks.json") }
    /// `<home>/.vibeswitcher/bin`, as the seal spells it (a link to the root's `bin` on a scratch node).
    private func bin(_ node: ScratchNode) -> URL { node.home.appendingPathComponent(".vibeswitcher/bin") }
    /// The hook as the configs name it.
    private func hook(_ node: ScratchNode) -> String { bin(node).appendingPathComponent("vibeswitcher-hook").path }

    private func object(_ url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// Every handler's command in `config`'s hooks, by event.
    private func commands(_ config: [String: Any]) -> [String: [String]] {
        var found: [String: [String]] = [:]
        for (event, groups) in config["hooks"] as? [String: Any] ?? [:] {
            for group in groups as? [[String: Any]] ?? [] {
                for handler in group["hooks"] as? [[String: Any]] ?? [] {
                    found[event, default: []].append(handler["command"] as? String ?? "")
                }
            }
        }
        return found
    }

    private func names(_ folder: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }

    /// The server's accepted requests, as `status` gives them.
    private func accepted(_ node: ScratchNode) throws -> [String] {
        let status = try #require(WireClient.reply(try WireClient(node).request("status", action: nil))?.result)
        return (status["accepted"]?.array ?? []).compactMap { $0["kind"]?.string }
    }

    /// A node holding its first look (as the user's does), its scratch repository's config accepted.
    private func acceptedNode() async throws -> (node: ScratchNode, repo: URL) {
        let node = try await ScratchNode(scratch, holdFirstLook: true)
        let repo = node.root.appendingPathComponent("repo")
        try await scratchRepository(repo)
        try EngineEndToEndTests.workflow(repo)
        try ownPrograms(node)
        return (node, repo)
    }

    /// What the app's look (`config held`) holds now, by name.
    private func held(_ node: ScratchNode, _ repo: URL) async throws -> [String] {
        let held = try await node.run(["config", "held", repo.path])
        try #require(held.status == 0, "\(held.output)\(held.errors)\n\(node.said)")
        return held.output.components(separatedBy: "\n").filter { $0.hasPrefix("    ~/") }
            .map { String($0.dropFirst(4).prefix { $0 != "," && $0 != " " }) }
    }

    // MARK: The five, restated

    @Test func installWritesOurHandlersIntoTheNodesHome() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        try ownPrograms(node)
        // A config folder the command line is given: it plays no part.
        let given = node.root.appendingPathComponent("claude-config")
        try FileManager.default.createDirectory(at: given, withIntermediateDirectories: true)
        let ran = try await ScratchNodes.onTerminal(commandLine.path, ["hooks", "install", "--agent", "claude"],
                                                    environment: node.environment(["CLAUDE_CONFIG_DIR": given.path]), answer: { $0 })
        #expect(ran.status == 0, "\(ran.output)\n\(node.said)")
        #expect(ran.output.contains("CLAUDE_CONFIG_DIR plays no part"), "\(ran.output)")

        let found = commands(try object(settings(node)))
        #expect(Set(found.keys) == Self.claudeEvents)
        for event in Self.claudeEvents { #expect(found[event] == ["\(hook(node)) claude"], "\(event)") }
        #expect(names(given).isEmpty, "\(names(given))")
        #expect(!FileManager.default.fileExists(atPath: node.home.appendingPathComponent(".codex").path))
        #expect(ran.output.contains("Claude: hooks installed in \(settings(node).path)"), "\(ran.output)")
    }

    @Test func installCopiesBothBinariesExecutable() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        try ownPrograms(node)
        let ran = try await node.runOnTerminal(["hooks", "install", "--agent", "claude"])
        #expect(ran.status == 0, "\(ran.output)\n\(node.said)")

        for name in Self.programs {
            let installed = bin(node).appendingPathComponent(name)
            var info = stat()
            try #require(lstat(installed.path, &info) == 0, "\(name)")
            #expect(info.st_mode & S_IFMT == S_IFREG, "\(name): a file, not a link")
            #expect(info.st_mode & 0o777 == 0o755, "\(name): \(String(info.st_mode & 0o777, radix: 8))")
            // Byte-equal to the node's build's.
            #expect(try Data(contentsOf: installed) == Data(contentsOf: node.nodeRoot.appendingPathComponent("bin/" + name)), "\(name)")
        }
        // Nothing half-written left beside them, nor in the folder above.
        #expect(names(bin(node)) == Self.programs)
        #expect(!names(node.home.appendingPathComponent(".vibeswitcher")).contains { $0.contains(".tmp") })
    }

    @Test func removeLeavesTheUsersOwnHandlers() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        try ownPrograms(node)
        let own = "/usr/local/bin/notify-me done"
        try FileManager.default.createDirectory(at: settings(node).deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        {
          "model": "sonnet",
          "hooks": {
            "Stop": [{"hooks": [{"type": "command", "command": "\(own)"}]}]
          }
        }
        """.write(to: settings(node), atomically: true, encoding: .utf8)

        let install = try await node.runOnTerminal(["hooks", "install", "--agent", "claude"])
        #expect(install.status == 0, "\(install.output)\n\(node.said)")
        #expect(commands(try object(settings(node)))["Stop"]?.count == 2)
        let remove = try await node.runOnTerminal(["hooks", "remove", "--agent", "claude"])
        #expect(remove.status == 0, "\(remove.output)\n\(node.said)")

        let config = try object(settings(node))
        #expect(commands(config) == ["Stop": [own]])
        #expect(config["model"] as? String == "sonnet")
    }

    /// With no `--agent`, both agents' hooks go in, in one request under one code, Codex's into the home's
    /// `.codex/hooks.json`.
    @Test func withNoAgentBothAreInstalledEachInItsOwnFolder() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        try ownPrograms(node)
        let ran = try await node.runOnTerminal(["hooks", "install"])
        #expect(ran.status == 0, "\(ran.output)\n\(node.said)")
        #expect(ran.output.components(separatedBy: "and Enter to go on").count == 2, "one code: \(ran.output)")
        #expect(try accepted(node) == ["hooks.install"])

        #expect(commands(try object(settings(node)))["Stop"] == ["\(hook(node)) claude"])
        #expect(commands(try object(codexHooks(node)))["Stop"] == ["\(hook(node)) codex"])

        let removed = try await node.runOnTerminal(["hooks", "remove"])
        #expect(removed.status == 0, "\(removed.output)\n\(node.said)")
        #expect(commands(try object(settings(node))).isEmpty)
        #expect(commands(try object(codexHooks(node))).isEmpty)
        #expect(try accepted(node) == ["hooks.install", "hooks.remove"])
    }

    @Test func aWrongCommandSaysHowAndChangesNothing() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        for arguments in [["hooks"], ["hooks", "add"], ["hooks", "install", "--agent", "gemini"], ["hooks", "install", "--agent"]] {
            let ran = try await node.run(arguments)
            #expect(ran.status == 64, "\(arguments)")
            #expect(ran.errors.contains("usage: vibeswitcher hooks install|remove"), "\(arguments): \(ran.errors)")
        }
        #expect(!FileManager.default.fileExists(atPath: settings(node).path))
        #expect(!FileManager.default.fileExists(atPath: bin(node).path))
        #expect(try accepted(node).isEmpty)
    }

    // MARK: The voice and the code

    @Test func aSessionsProcessCannotInstallHooks() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        try ownPrograms(node)
        let out = node.root.appendingPathComponent("hooks.out").path
        let command = "VIBESWITCHER_HOME='\(node.root.path)' '\(commandLine.path)' hooks install --agent claude >'\(out)' 2>&1; echo \"exit $?\" >>'\(out)'"
        let session = try await node.spawn(command)
        // The code is typed on the session's terminal, so the server judges the request.
        var code = ""
        let asked = await eventually(timeout: 60) {
            guard let screen = HostCall.styledScreen(session.id, socket: node.socket, appKey: nil)?.text,
                  let range = screen.range(of: #"Type ([A-Z]{4}) and Enter"#, options: .regularExpression) else { return false }
            code = String(screen[range].dropFirst(5).prefix(4))
            return true
        }
        try #require(asked, "the command line never asked: \(String(describing: HostCall.styledScreen(session.id, socket: node.socket, appKey: nil)?.text))")
        try HostCall.send(.input(id: session.id, bytes: Data((code + "\r").utf8), reply: false), socket: node.socket, appKey: nil)
        let ended = await eventually(timeout: 60) { ((try? String(contentsOfFile: out, encoding: .utf8)) ?? "").contains("exit ") }
        let said = (try? String(contentsOfFile: out, encoding: .utf8)) ?? ""
        #expect(ended, "\(said)")
        #expect(said.contains("exit 77"), "\(said)")
        #expect(said.contains("voice: not the user's voice"), "\(said)")
        // Nothing written, nothing accepted.
        #expect(!FileManager.default.fileExists(atPath: settings(node).path))
        #expect(!FileManager.default.fileExists(atPath: bin(node).path))
        #expect(try accepted(node).isEmpty)
    }

    @Test func aHooksInstallWithNoTerminalIsRefused() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        try ownPrograms(node)
        // stdin from /dev/null, in a session of its own: no /dev/tty.
        let ran = try await run(URL(fileURLWithPath: "/usr/bin/setsid"), ["--wait", commandLine.path, "hooks", "install"], environment: node.environment())
        #expect(ran.status == 77, "\(ran.output)\(ran.errors)")
        #expect(ran.errors.contains(TypedOutcome.noTerminal.refusal), "\(ran.errors)")
        #expect(try accepted(node).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: settings(node).path))
        #expect(!FileManager.default.fileExists(atPath: bin(node).path))

        // The start plan's Review Focus 4: a remove with no terminal is refused too, and changes nothing.
        let install = try await node.runOnTerminal(["hooks", "install"])
        #expect(install.status == 0, "\(install.output)\n\(node.said)")
        let remove = try await run(URL(fileURLWithPath: "/usr/bin/setsid"), ["--wait", commandLine.path, "hooks", "remove"], environment: node.environment())
        #expect(remove.status == 77, "\(remove.output)\(remove.errors)")
        #expect(remove.errors.contains(TypedOutcome.noTerminal.refusal), "\(remove.errors)")
        #expect(try accepted(node) == ["hooks.install"])
        #expect(HookInstaller.isInstalled(in: try object(settings(node))))
        #expect(HookInstaller.isInstalled(in: try object(codexHooks(node))))
    }

    // MARK: Sealed as the app's

    @Test func hooksInstallWritesAsTheAppAndSealsIt() async throws {
        let (node, repo) = try await acceptedNode()
        defer { node.stop() }
        try await node.acceptConfig(repo)
        #expect(try await held(node, repo).isEmpty)

        let ran = try await node.runOnTerminal(["hooks", "install"])
        #expect(ran.status == 0, "\(ran.output)\n\(node.said)")
        #expect(ran.output.components(separatedBy: "and Enter to go on").count == 2, "one code: \(ran.output)")
        #expect(commands(try object(settings(node)))["Stop"] == ["\(hook(node)) claude"])
        #expect(commands(try object(codexHooks(node)))["Stop"] == ["\(hook(node)) codex"])
        for name in Self.programs {
            #expect(try Data(contentsOf: bin(node).appendingPathComponent(name)) == Data(contentsOf: node.nodeRoot.appendingPathComponent("bin/" + name)), "\(name)")
        }
        // Sealed as the app's write: the next look holds nothing.
        #expect(try await held(node, repo).isEmpty)

        // The same edit made here, not through the server, is held.
        let removed = try await node.runOnTerminal(["hooks", "remove", "--agent", "claude"])
        #expect(removed.status == 0, "\(removed.output)\n\(node.said)")
        #expect(try await held(node, repo).isEmpty)
        try HookInstaller.install(agent: .claude, at: settings(node), hookBinary: hook(node))
        #expect(try await held(node, repo) == ["~/.claude/settings.json"])
    }

    /// S9's card order is accept first; this pins the other. Before the vault's first look nothing is recorded, so the
    /// app's seal has nothing to chain from (`sealAppWrites` seals only what was sealed as the write found it): the
    /// install isn't sealed as the app's write. The first look's card shows what it wrote, and the first accept seals
    /// it with the rest (the S6 review).
    @Test func aHooksInstallBeforeTheFirstLookIsShownByTheFirstAccept() async throws {
        let (node, repo) = try await acceptedNode()
        defer { node.stop() }
        let ran = try await node.runOnTerminal(["hooks", "install"])
        #expect(ran.status == 0, "\(ran.output)\n\(node.said)")
        #expect(commands(try object(settings(node)))["Stop"] == ["\(hook(node)) claude"])
        #expect(commands(try object(codexHooks(node)))["Stop"] == ["\(hook(node)) codex"])
        for name in Self.programs {
            #expect(try Data(contentsOf: bin(node).appendingPathComponent(name)) == Data(contentsOf: node.nodeRoot.appendingPathComponent("bin/" + name)), "\(name)")
        }
        // On the first look's card, with everything else the vault has nothing recorded for.
        let shown = try await held(node, repo)
        for name in ["~/.claude/settings.json", "~/.codex/hooks.json", "~/.vibeswitcher/bin"] { #expect(shown.contains(name), "\(name): \(shown)") }
        try await node.acceptConfig(repo)
        #expect(try await held(node, repo).isEmpty)
        // Sealed from then on: a change made here is held.
        try HookInstaller.uninstall(agent: .codex, at: codexHooks(node))
        #expect(try await held(node, repo) == ["~/.codex/hooks.json"])
    }

    /// ST-D17's note of the review of S5: the host's `binaries` hold against a rewrite after its start only, so an
    /// install waits while the builds folder has a change the user hasn't accepted.
    @Test func aChangeInTheBuildsFolderNotAcceptedRefusesTheInstall() async throws {
        let (node, repo) = try await acceptedNode()
        defer { node.stop() }
        try await node.acceptConfig(repo)
        let builds = node.home.appendingPathComponent(".vibeswitcher/v2/builds")
        try FileManager.default.createDirectory(at: builds, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: builds.appendingPathComponent("installs"))
        let refused = try await node.runOnTerminal(["hooks", "install"])
        #expect(refused.status == 77, "\(refused.output)\n\(node.said)")
        #expect(refused.output.contains("~/.vibeswitcher/v2/builds") && refused.output.contains("config held"), "\(refused.output)")
        #expect(!FileManager.default.fileExists(atPath: settings(node).path))
        #expect(!FileManager.default.fileExists(atPath: bin(node).path))

        try await node.acceptConfig(repo)
        let ran = try await node.runOnTerminal(["hooks", "install"])
        #expect(ran.status == 0, "\(ran.output)\n\(node.said)")
    }

    // MARK: Only the build's bytes

    @Test func aNodeRootProgramThatDiffersFromBuildInfoIsNotInstalled() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        try ownPrograms(node)
        let program = node.nodeRoot.appendingPathComponent("bin/vibeswitcher-hook")
        // One byte appended to the copy (the built product is never written).
        let handle = try FileHandle(forWritingTo: program)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        let ran = try await node.runOnTerminal(["hooks", "install"])
        #expect(ran.status == 77, "\(ran.output)\n\(node.said)")
        #expect(ran.output.contains("vibeswitcher-hook") && ran.output.contains("SHA-256 differs"), "\(ran.output)")
        #expect(!FileManager.default.fileExists(atPath: bin(node).path))
        #expect(!FileManager.default.fileExists(atPath: settings(node).path))
        #expect(!FileManager.default.fileExists(atPath: codexHooks(node).path))

        // A link in its place, to the very bytes the build-info names: refused, not followed.
        try FileManager.default.removeItem(at: program)
        try FileManager.default.createSymbolicLink(atPath: program.path, withDestinationPath: builtProducts.appendingPathComponent("vibeswitcher-hook").path)
        let linked = try await node.runOnTerminal(["hooks", "install"])
        #expect(linked.status == 77, "\(linked.output)\n\(node.said)")
        #expect(linked.output.contains("vibeswitcher-hook") && linked.output.contains("is a link"), "\(linked.output)")
        #expect(!FileManager.default.fileExists(atPath: bin(node).path))
        #expect(!FileManager.default.fileExists(atPath: settings(node).path))
    }

    @Test func noTemporaryIsLeftInTheWatchedFolder() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        try ownPrograms(node)
        // Watched while the install runs: every name made in the folder or renamed into it, as inotify tells it (a
        // temporary made and renamed away between two listings would not be seen by a poll). The folder is made first,
        // as the install leaves it (0700; the install takes one that is there), so the watch is on it before the
        // install writes anything: a temporary made in it and renamed away at once is seen too (the step 8 sweep's
        // review: one made in a folder the install had just made could come and go before the watch was added).
        let folder = bin(node)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let watch = try NameWatch(folder)
        // Stopped on every path out, and its thread waited for.
        defer { watch.stop() }
        let ran = try await node.runOnTerminal(["hooks", "install"])
        let seen = watch.stop()
        #expect(ran.status == 0, "\(ran.output)\n\(node.said)")
        // Each program renamed in, and nothing else: the watch saw the folder fill.
        #expect(seen == Set(Self.programs), "\(seen)")
        #expect(names(folder) == Self.programs)
        #expect(!names(node.home.appendingPathComponent(".vibeswitcher")).contains { $0.contains(".tmp") })
    }

    // MARK: Trusted in Codex

    /// A stand-in Codex where the node's Codex link is read (`<root>/v2/test/codex` on a scratch node,
    /// `NodeCodexTrustTests.standIn`): it lists the hook the install wrote untrusted, then trusted once written.
    private func standInCodex(_ node: ScratchNode, script: String? = nil, before: String = "") throws -> (program: String, folder: URL) {
        let home = NodeCodexTrustTests.Home(home: node.home)
        let key = "\(codexHooks(node).path):stop:0:0"
        let listed = [NodeCodexTrustTests.hook(key, "\(hook(node)) codex", hash: "sha256:ours")]
        var after = listed
        after[0]["trustStatus"] = "trusted"
        let folder = node.root.appendingPathComponent("stand-in")
        let program = try NodeCodexTrustTests.standIn(
            in: folder, config: home.config, first: NodeCodexTrustTests.listing(2, listed, cwd: node.home.path),
            second: NodeCodexTrustTests.listing(4, after, cwd: node.home.path),
            append: before + "\n[hooks.state]\n" + NodeCodexTrustTests.trustTable(key, "sha256:ours"), script: script)
        let link = node.root.appendingPathComponent("v2/test/codex")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: program.path)
        let resolved = try #require(realpath(program.path, nil))
        defer { free(resolved) }
        return (String(cString: resolved), folder)
    }

    /// The install trusts our Codex hook by running the Codex it named before the code, and the trust it wrote in
    /// `~/.codex/config.toml` is sealed as the app's: the next look holds nothing.
    @Test func hooksInstallTrustsTheCodexHooksAndTheSealHoldsNothingAfter() async throws {
        let (node, repo) = try await acceptedNode()
        defer { node.stop() }
        try await node.acceptConfig(repo)
        let codex = try standInCodex(node)

        let ran = try await node.runOnTerminal(["hooks", "install"])
        #expect(ran.status == 0, "\(ran.output)\n\(node.said)")
        #expect(ran.output.contains("trusts VibeSwitcher's Codex hooks in Codex by running \(codex.program) app-server"), "\(ran.output)")
        #expect(ran.output.components(separatedBy: "and Enter to go on").count == 2, "one code: \(ran.output)")
        #expect(ran.output.contains("Codex trusts them (1 hook)."), "\(ran.output)")
        #expect(!ran.output.contains("run /hooks"), "\(ran.output)")
        let config = try String(contentsOf: node.home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        #expect(config.contains("trusted_hash = \"sha256:ours\""), "\(config)")
        #expect(try await held(node, repo).isEmpty)
    }

    /// `--agent claude` alone doesn't touch Codex: nothing said of it, the stand-in never run.
    @Test func aClaudeOnlyInstallDoesNotRunCodex() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        try ownPrograms(node)
        let codex = try standInCodex(node)
        let ran = try await node.runOnTerminal(["hooks", "install", "--agent", "claude"])
        #expect(ran.status == 0, "\(ran.output)\n\(node.said)")
        #expect(!ran.output.contains("Codex"), "\(ran.output)")
        #expect(!FileManager.default.fileExists(atPath: codex.folder.appendingPathComponent("pid").path))
        #expect(!FileManager.default.fileExists(atPath: node.home.appendingPathComponent(".codex").path))
    }

    /// No Codex where its link is read: said before the code, and the install still succeeds with today's line.
    @Test func withNoCodexTheInstallSucceedsAndSaysToRunHooks() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        try ownPrograms(node)
        // No codex on the command line's PATH either.
        let ran = try await ScratchNodes.onTerminal(commandLine.path, ["hooks", "install", "--agent", "codex"],
                                                    environment: node.environment(["PATH": "/usr/bin:/bin"]), answer: { $0 })
        #expect(ran.status == 0, "\(ran.output)\n\(node.said)")
        #expect(ran.output.contains("Codex isn't asked to trust the hooks (codex: "), "\(ran.output)")
        #expect(ran.output.contains("Not trusted in Codex: no Codex was named to trust them with."), "\(ran.output)")
        #expect(ran.output.contains("run /hooks in Codex and trust the vibeswitcher-hook entries"), "\(ran.output)")
        #expect(HookInstaller.isInstalled(in: try object(codexHooks(node))))
    }

    /// No link but a `codex` on the command line's PATH: the confirmation and the result say the line that makes the
    /// link; that codex is never run.
    @Test func aCodexOnThePathIsShownAsTheLinkToMake() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        try ownPrograms(node)
        let folder = node.root.appendingPathComponent("path-bin")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let marker = node.root.appendingPathComponent("path-codex-ran")
        let found = folder.appendingPathComponent("codex")
        try writeClosedOnExec("#!/bin/sh\ntouch \(HookInstaller.shellQuoted(marker.path))\n", to: found)
        let link = node.root.appendingPathComponent("v2/test/codex").path
        let ran = try await ScratchNodes.onTerminal(commandLine.path, ["hooks", "install", "--agent", "codex"],
                                                    environment: node.environment(["PATH": "\(folder.path):/usr/bin:/bin"]), answer: { $0 })
        #expect(ran.status == 0, "\(ran.output)\n\(node.said)")
        let line = "Codex isn't linked for this node: `ln -s \(HookInstaller.shellQuoted(found.path)) \(HookInstaller.shellQuoted(link))`, "
            + "then run hooks install again (the node holds the new link until you accept it)"
        #expect(ran.output.components(separatedBy: line).count == 3, "in the confirmation and the result: \(ran.output)")
        #expect(!ran.output.contains("run /hooks"), "\(ran.output)")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(HookInstaller.isInstalled(in: try object(codexHooks(node))))
    }

    /// `config.toml` changed outside Codex's part while the trust ran (a hand edit): left as it is, nothing of it
    /// sealed, so the next look holds it; the result says so.
    @Test func aHandEditWhileTheTrustRanIsHeldNotDropped() async throws {
        let (node, repo) = try await acceptedNode()
        defer { node.stop() }
        try await node.acceptConfig(repo)
        _ = try standInCodex(node, before: "\n[profiles.mine]\nmodel = \"y\"\n")
        let ran = try await node.runOnTerminal(["hooks", "install"])
        #expect(ran.status == 0, "\(ran.output)\n\(node.said)")
        #expect(ran.output.contains("~/.codex/config.toml changed while this ran (by Codex or something else): nothing of it was sealed; `vibeswitcher config held` shows it"), "\(ran.output)")
        #expect(ran.output.contains("run /hooks in Codex and trust the vibeswitcher-hook entries"), "\(ran.output)")
        let config = try String(contentsOf: node.home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        #expect(config.contains("[profiles.mine]") && config.contains("trusted_hash = \"sha256:ours\""), "left as it is: \(config)")
        #expect(try await held(node, repo) == ["~/.codex/config.toml"])
    }

    /// A Codex that quits mid-way: the install still succeeds, says why and today's line, and the seal holds nothing.
    @Test func aCodexThatQuitsLeavesTheInstallDoneAndNothingHeld() async throws {
        let (node, repo) = try await acceptedNode()
        defer { node.stop() }
        try await node.acceptConfig(repo)
        _ = try standInCodex(node, script: "read -r line; exit 0")
        let ran = try await node.runOnTerminal(["hooks", "install"])
        #expect(ran.status == 0, "\(ran.output)\n\(node.said)")
        #expect(ran.output.contains("Not trusted in Codex: codex app-server quit before it was done."), "\(ran.output)")
        #expect(ran.output.contains("run /hooks in Codex and trust the vibeswitcher-hook entries"), "\(ran.output)")
        #expect(HookInstaller.isInstalled(in: try object(codexHooks(node))))
        #expect(try await held(node, repo).isEmpty)
    }

    @Test func hooksRemoveTakesThemOut() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        try ownPrograms(node)
        let install = try await node.runOnTerminal(["hooks", "install"])
        #expect(install.status == 0, "\(install.output)\n\(node.said)")
        #expect(HookInstaller.isInstalled(in: try object(settings(node))))
        #expect(HookInstaller.isInstalled(in: try object(codexHooks(node))))
        let remove = try await node.runOnTerminal(["hooks", "remove"])
        #expect(remove.status == 0, "\(remove.output)\n\(node.said)")
        #expect(remove.output.contains("Claude: hooks removed from \(settings(node).path)"), "\(remove.output)")
        #expect(!HookInstaller.isInstalled(in: try object(settings(node))))
        #expect(!HookInstaller.isInstalled(in: try object(codexHooks(node))))
        // The programs stay.
        #expect(names(bin(node)) == Self.programs)
    }
}

/// The names made in a folder or renamed into it, from now until `stop()`: a client of the process's inotify instance
/// that keeps its events' names (`InotifyHub`), so the test makes no instance of its own (the user's 128 are shared by
/// every scratch node a loaded run starts).
private struct Unwatched: Error, CustomStringConvertible { let description: String }

private final class NameWatch: @unchecked Sendable {
    private let lock = NSLock()
    #if os(Linux)
    private let client: InotifyClient
    #endif
    private var seen: Set<String>?

    init(_ folder: URL) throws {
        #if os(Linux)
        guard let client = InotifyHub.shared.watch(folder.path, mask: UInt32(IN_CREATE) | UInt32(IN_MOVED_TO), folder: true, names: true) else {
            // Said, not a bare CancellationError (which read as a time limit): the hub's instance or watch unmade, with
            // this user's counts against their limits (the inotify instances among them).
            throw Unwatched(description: "the hub made no watch of \(folder.path) (\(Platform.Watches.unmade) unmade in this process); \(ScratchNodes.limits())")
        }
        self.client = client
        #else
        throw CancellationError()
        #endif
    }

    /// Ends the watch once; the names seen in the folder (every event the kernel queued by now included).
    @discardableResult func stop() -> Set<String> {
        lock.withLock {
            if let seen { return seen }
            #if os(Linux)
            let names = Set(client.takeNames())
            client.stop()
            #else
            let names = Set<String>()
            #endif
            seen = names
            return names
        }
    }
}
