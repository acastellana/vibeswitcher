import CryptoKit
import Foundation
import Testing
import VibeCore
@testable import VibeHost
@testable import VibeSwitcher

/// 2026-10-18: the 18:10 install replaced all three leads; the old ones kept answering the user for four hours with no
/// tools, and genswap's "split the GenLayer layer out" and films' "do what we need to do" never reached a board. Here a
/// scratch host (its own socket, lock and key; never the user's) runs a lead, the app replaces it, and what's typed
/// into the old one goes to the new one.
@MainActor
struct ReplacedLeadRoutingTests {
    let temp = Scratch()

    struct World {
        let server: HostServer
        let socket: String
        let key: SymmetricKey
        let root: String
        let vault: LeadVault
        let inbox: URL
        let home: String
        let host: HostClient
        let controller: LeadController

        var project: String { (root as NSString).lastPathComponent }

        func stop() {
            server.stop(terminateSessions: true)
            unlink(socket + ".lock")
        }
    }

    func world() throws -> World {
        AppStatus.enabled = false
        let url = temp.url("replaced")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)

        let launcher = Bundle(for: ReplacedAnchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("vibeswitcher-host").path
        let socket = "/tmp/vsh-rl-\(UUID().uuidString.prefix(8)).sock"
        let key = SymmetricKey(size: .bits256)
        let home = temp.url("home").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var config = HostServer.Config(socketPath: socket, lockPath: socket + ".lock", shell: "/bin/sh", launcher: launcher,
                                       baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": home.path],
                                       hostBuild: HostBuild.id(ofExecutableAt: HostClient.hostExecutable.path))
        config.idleExit = nil
        config.appKey = key
        config.appExecutable = HostServer.executable(of: getpid())
        let server = HostServer(config: config)
        try server.start()
        let vault = LeadVault.Book().vault(folder: temp.url("vault"), as: { .app })
        let inbox = temp.url("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let stateDir = temp.url("state")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        let host = HostClient(socketPath: socket, appKey: { key })
        let store = SessionStore(scanner: SessionScanner(processes: { [:] }, stateDir: { stateDir }, cwd: { _ in nil }, arguments: { _ in [] }))
        // The new lead's Claude is a sleep: what follows `#` (its prompt, tools and rules) is only read, never run.
        let controller = LeadController(host: host, store: store, vault: vault, inbox: inbox, home: home.path) { _ in "exec /bin/sleep 600 #" }
        controller.answersTrust = false
        controller.leadRuns = { _ in true }
        return World(server: server, socket: socket, key: key, root: root, vault: vault, inbox: inbox, home: home.path,
                     host: host, controller: controller)
    }

    /// The old lead: a session the app started, named on the board as its tool server would. It runs `cat`, so
    /// anything typed into it shows on its screen.
    func oldLead(in world: World) async throws -> HostSession {
        world.host.connectIfRunning()
        #expect(await until { world.host.state == .connected })
        var result: Result<HostSession, HostClientError>?
        world.host.spawn(SpawnRequest(cwd: world.root, command: "exec /bin/cat", env: [:], cols: 80, rows: 24, keepShell: false,
                                      label: "Lead · \(world.project)", agent: "claude")) { result = $0 }
        #expect(await until { result != nil })
        let session = try #require(result).get()
        try BoardStore(root: world.root).prepare()
        try BoardStore(root: world.root).update { board in
            board.leadSession = session.id.uuidString
            board.leadPid = session.childPID
            board.leadTTY = session.tty
        }
        return session
    }

    /// The old lead's conversation, where Claude keeps it (in the scratch home): one answered prompt, one not.
    func transcript(of old: HostSession, in world: World) throws {
        let folder = URL(fileURLWithPath: world.home).appendingPathComponent(".claude/projects/\(RecentProjects.claudeSlug(for: world.root))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "lead-\(Slug.make(world.project, taken: []))"
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"make the films page"},"uuid":"u1","timestamp":"2026-10-18T18:20:00.000Z"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I'll add a task for the films page."}]},"uuid":"a1","timestamp":"2026-10-18T18:21:00.000Z"}"#,
            #"{"type":"user","message":{"role":"user","content":"split the GenLayer layer out"},"uuid":"u2","timestamp":"2026-10-18T19:02:00.000Z"}"#,
            #"{"type":"custom-title","customTitle":"\#(name)","agentName":"\#(name)"}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("old.jsonl"), atomically: true, encoding: .utf8)
    }

    /// You ask for a new lead (the old one's role gone, as after the install): its session holds the role, and the
    /// board names it once its tool server says where its agent runs.
    func replace(in world: World, old: HostSession) async throws -> HostSession {
        var asked: [String] = []
        world.controller.confirm = { title, _, buttons in asked.append(title); return buttons.count - 1 }
        world.controller.startLead(in: world.root)
        #expect(await until { asked.count == 1 && world.host.sessions.count == 2 })
        let new = try #require(world.host.sessions.first { $0.id != old.id })
        #expect(await until { world.vault.current(.lead, root: world.root, task: nil)?.session == new.id.uuidString })
        #expect(await until { BoardStore(root: world.root).load().leadSession == new.id.uuidString })
        try BoardStore(root: world.root).update { board in
            board.leadPid = new.childPID
            board.leadTTY = new.tty
        }
        return new
    }

    func screen(_ id: UUID, _ host: HostClient) async -> String? {
        var text: String??
        host.screen(id) { text = .some($0) }
        _ = await until { text != nil }
        return text ?? nil
    }

    @Test func whatsTypedIntoAReplacedLeadGoesToTheLiveLeadAsTheUsers() async throws {
        let world = try world()
        defer { world.stop() }
        let old = try await oldLead(in: world)
        try transcript(of: old, in: world)
        let new = try await replace(in: world, old: old)

        // Marked in the window: replaced, naming the live lead.
        #expect(await until { world.controller.replacedLeads[old.id]?.live == new.id })
        let replaced = try #require(world.controller.replacedLeads[old.id])
        #expect(replaced.label == "replaced — continue in Lead · \(world.project)")
        #expect(replaced.tty == old.tty)
        #expect(world.controller.replacedLeads[new.id] == nil)
        let model = WindowModel()
        model.replacedLeads = world.controller.replacedLeads
        let row = WindowRow(content: .hosted(old), project: world.project)
        #expect(model.state(of: row, now: Date()).text == replaced.label)
        #expect(model.state(of: WindowRow(content: .hosted(new), project: world.project), now: Date()).text != replaced.label)

        // Typed into its terminal (keys, then Enter): the live lead's inbox gets it, sealed as yours, saying where it
        // was typed; the old session gets nothing.
        for key in Array("split the GenLayer layer out".utf8) { world.host.send(old.id, bytes: Data([key]), reply: false) }
        #expect(world.controller.replacedLeads[old.id]?.draft == "split the GenLayer layer out")
        world.host.send(old.id, bytes: Data([13]), reply: false)
        // From the phone (its text, then Enter) and from the composer.
        for write in HostInput.writes(text: "do what we need to do", submit: true, key: nil) {
            world.host.send(old.id, bytes: Data(write.bytes), reply: false)
        }
        #expect(world.controller.route("and the films page", typedInto: old.id))

        let pending = SteerInbox.pending(tty: new.tty, root: world.inbox).filter { $0.agentPid == new.childPID }
        #expect(pending.count == 3)
        #expect(pending.allSatisfy { $0.from == .user && $0.seal != nil })
        #expect(SteerSeal.for(world.inbox).verify(pending) == [true, true, true])
        let typedThere = "typed into the replaced lead's session on \(old.tty)"
        #expect(pending.map(\.text) == ["split the GenLayer layer out", "do what we need to do", "and the films page"].map { "(\(typedThere), which has no tools; VibeSwitcher sent it on to you) \($0)" })
        #expect(SteerInbox.pending(tty: old.tty, root: world.inbox).isEmpty)
        // The replaced session says where it went.
        let notice = try #require(world.controller.replacedLeads[old.id]?.notice)
        #expect(notice.contains("went to Lead · \(world.project) as your message"))
        #expect(world.controller.replacedLeads[old.id]?.draft == "")
        // Its pty got nothing: cat would have shown it.
        try? await Task.sleep(nanoseconds: 300_000_000)
        let shown = await screen(old.id, world.host) ?? ""
        #expect(!shown.contains("split") && !shown.contains("films"), "\(shown)")
        // The live lead's own input isn't taken.
        #expect(!world.controller.takeInput(Data("x".utf8), for: new.id))

        // The new lead read the old one's last turns before greeting.
        let file = LeadLaunch.turnsFile(root: world.root)
        let turns = try String(contentsOfFile: file, encoding: .utf8)
        #expect(turns.contains("lead on \(old.tty)"))
        #expect(turns.contains("make the films page") && turns.contains("I'll add a task for the films page."))
        #expect(turns.contains("split the GenLayer layer out\n\n(No reply: act on this.)"))
        let command = try #require(new.command)
        #expect(command.contains("You replace the lead on \(old.tty)"))
        #expect(command.contains("Before greeting, read \(file)"))
    }

    @Test func aReplacedLeadWithNoTranscriptLeavesNoFileAndAPlainStart() async throws {
        let world = try world()
        defer { world.stop() }
        let old = try await oldLead(in: world)
        // An earlier replacement's file doesn't carry over.
        try LeadLaunch.writeTurns("# stale", root: world.root)
        let new = try await replace(in: world, old: old)
        #expect(await until { world.controller.replacedLeads[old.id]?.live == new.id })
        #expect(!FileManager.default.fileExists(atPath: LeadLaunch.turnsFile(root: world.root)))
        let command = try #require(new.command)
        // (The prompt is shell-quoted on the command line: its apostrophe is spelled out.)
        #expect(command.contains("starting as the project lead. Read status"))
        #expect(!command.contains("You replace") && !command.contains("replaced-lead-turns"))
    }
}

private final class ReplacedAnchor {}
