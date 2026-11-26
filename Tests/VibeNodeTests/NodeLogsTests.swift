import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The `logs` read kind (the no-terminal inventory's C8): what `vibeswitcher logs` shows, read by the same code
/// (`NodeLogs`, which the command line's Logs.swift calls), every line masked by the one masking (`NodeLogs.masked`):
/// a secret-shaped string planted in a log never leaves in a reply; the reply is bounded; a read of the user's
/// (`webRead`): a page with its read right, the user on the socket, never a session's process. Not `linuxOnly`, but for
/// the last suite (a session's process asking, through a scratch host).
struct NodeLogsTests {
    private let scratch = Scratch()

    /// Secret shapes the masking knows, made here at run time (no secret's shape in the source: SecretShapeLint).
    static let planted = ["TOKEN=" + "s3cr3t" + "-planted-" + "9f2c", "sk-" + "ant-" + "api03-" + String(repeating: "Q7", count: 24)]

    private func folder() throws -> URL {
        let root = scratch.url("logs")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func read(_ args: WireKinds.Logs.Args, root: URL, place: NodeLogs.Place,
                      run: @escaping (String, [String], [String]?) -> (status: Int32, output: String)? = { _, _, _ in nil }) -> Result<WireKinds.Logs.Result, Requests.ReadRefusal> {
        NodeLogs.read(args, root: root, place: place, scratch: true, run: run)
    }

    /// The session log and the detached host's file: their last lines, each masked; a planted secret is nowhere in the
    /// reply, its line is there with the mask in its place.
    @Test func aPlantedSecretNeverLeaves() throws {
        let root = try folder()
        let lines = ["2026-11-26T09:00:00Z session 39c587b5 started for the user (pts/16)",
                     "2026-11-26T09:00:01Z exported \(Self.planted[0]) before the run",
                     "2026-11-26T09:00:02Z header Authorization: Bearer \(Self.planted[1])",
                     "2026-11-26T09:00:03Z session 39c587b5 ended (exit 0)"]
        try (lines.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent("host.log"), atomically: true, encoding: .utf8)
        let host = root.appendingPathComponent("v2/host.log")
        try FileManager.default.createDirectory(at: host.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: host, atomically: true, encoding: .utf8)
        for (args, place, log) in [(WireKinds.Logs.Args(sessions: true), NodeLogs.Place.file("/nowhere"), "sessions"),
                                   (.init(), .file(host.path), "node")] {
            let result = try read(args, root: root, place: place).get()
            #expect(result.log == log && result.why == nil && result.cut == 0)
            #expect(result.lines == lines.map(NodeLogs.masked), "\(result.lines ?? [])")
            let text = String(decoding: NodeWire.line(result), as: UTF8.self)
            for secret in Self.planted { #expect(!text.contains(secret) && !text.contains(String(secret.suffix(12))), "\(log): \(secret) left") }
            #expect(result.lines?[1].contains("TOKEN=•••") == true && result.lines?[0] == lines[0])
        }
    }

    /// The one masking: `masked` is `Redaction.secrets` made inert (no control character or escape, 1000 characters at
    /// most), and the command line's Logs.swift masks through it, with no masking of its own.
    @Test func theCommandLineMasksWithTheSameCode() throws {
        let raw = "\u{1b}[31mred\u{1b}[0m \(Self.planted[0]) " + String(repeating: "x", count: 2000)
        #expect(NodeLogs.masked(raw) == ConfigSeal.inert(Redaction.secrets(in: raw), limit: 1000))
        #expect(!NodeLogs.masked(raw).contains("\u{1b}") && !NodeLogs.masked(raw).contains(Self.planted[0]))
        let source = try String(contentsOf: ServerLintTests.repo.appendingPathComponent("Sources/vibeswitcher-cli/Logs.swift"), encoding: .utf8)
        #expect(source.contains("NodeLogs.masked(text)") && source.contains("NodeLogs.tail(") && source.contains("NodeLogs.journal("))
        #expect(!source.contains("Redaction.") && !source.contains("ConfigSeal.inert(Redaction"), "Logs.swift masks with code of its own")
    }

    /// The journal (a scratch node's stand-in, or the system's by its path with the tools' environment): its entries'
    /// messages masked and stamped, the command line's own left out; why not when there is no journal or it didn't answer.
    @Test func theJournalIsReadAndMasked() throws {
        let root = try folder()
        let entries = [#"{"MESSAGE":"server listening","SYSLOG_IDENTIFIER":"vibeswitcher-node","__REALTIME_TIMESTAMP":"1764147600000000"}"#,
                       #"{"MESSAGE":"a hook said \#(Self.planted[0])","SYSLOG_IDENTIFIER":"vibeswitcher-node","__REALTIME_TIMESTAMP":"1764147601000000"}"#,
                       #"{"MESSAGE":"status asked","SYSLOG_IDENTIFIER":"vibeswitcher","__REALTIME_TIMESTAMP":"1764147602000000"}"#]
        var asked: (String, [String], [String]?)?
        let result = try read(.init(lines: 10), root: root, place: .journal(journalctl: "/usr/bin/journalctl", environment: ["PATH=/usr/bin:/bin"])) { program, arguments, environment in
            asked = (program, arguments, environment)
            return (0, entries.joined(separator: "\n"))
        }.get()
        #expect(asked?.0 == "/usr/bin/journalctl" && asked?.1.contains("--user") == true && asked?.1.contains("10") == true && asked?.2 == ["PATH=/usr/bin:/bin"])
        #expect(result.lines?.count == 2 && result.lines?[0].hasSuffix("server listening") == true, "\(result.lines ?? [])")
        #expect(result.lines?[1].contains("TOKEN=•••") == true && !(result.lines?[1].contains(Self.planted[0]) ?? true))
        let none = try read(.init(), root: root, place: .journal(journalctl: nil, environment: nil)).get()
        #expect(none.lines == [] && none.why == "scratch node: no journal, no manager")
        let silent = try read(.init(), root: root, place: .journal(journalctl: "/usr/bin/journalctl", environment: nil)).get()
        #expect(silent.why == "journalctl --user didn't answer")
        let missing = try read(.init(sessions: true), root: root, place: .file("/nowhere")).get()
        #expect(missing.why == "not there yet" && missing.log == "sessions")
    }

    /// Bounded: `lines` from 1 to `pageLines` (`bad-args` outside), and at most `replyBytes` of lines, the oldest left
    /// out first (`cut` says how many); the newest always kept.
    @Test func theReplyIsBounded() throws {
        let root = try folder()
        let lines = (1...3000).map { "line \($0) " + String(repeating: "w", count: 900) }
        try (lines.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent("host.log"), atomically: true, encoding: .utf8)
        let result = try read(.init(lines: NodeLogs.pageLines, sessions: true), root: root, place: .file("/nowhere")).get()
        let kept = result.lines ?? []
        #expect(kept.reduce(0) { $0 + $1.utf8.count + 1 } <= NodeLogs.replyBytes)
        #expect((result.cut ?? 0) > 0 && kept.count + (result.cut ?? 0) == NodeLogs.pageLines, "\(kept.count) + \(result.cut ?? 0)")
        #expect(kept.last?.hasPrefix("line 3000 ") == true)
        #expect(NodeWire.replyLine(NodeWire.Reply(re: "1", typed: result)).count < NodeWire.partBytes)
        for count in [0, NodeLogs.pageLines + 1] {
            guard case .failure(let failure) = read(.init(lines: count), root: root, place: .file("/nowhere")) else { Issue.record("\(count) taken"); continue }
            #expect(failure.code == NodeWire.Code.badArgs.rawValue, "\(count)")
        }
    }

    /// Who may read: a page with its token's read right (the private read's path, `webRead`), never one without it; on
    /// the socket the user's alone, judged as a user's read (a session's process is refused: `NodeLogsVoiceTests`);
    /// nothing about it changes state. And its typed arguments refuse a wrong form.
    @Test func onlyTheUserOrAPageThatReadsMayRead() {
        #expect(KindSpec.spec("logs")?.sender == .webRead && KindSpec.spec("logs")?.effect == .read && !NodeWire.changesState("logs"))
        let request = NodeWire.Request(id: "1", kind: "logs", args: ["sessions": .bool(true)])
        #expect(WebAccess.refusal(for: request, rights: [.read]) == nil)
        #expect(Principal.page([.read], terminals: false).route("logs") == .privateRead)
        for rights: LiveRights in [[], [.draft]] {
            #expect(WebAccess.refusal(for: request, rights: rights)?.error?.code == NodeWire.Code.voice.rawValue, "\(rights)")
        }
        #expect(WebAccess.kinds(for: [.read]).contains("logs") && !WebAccess.kinds(for: []).contains("logs"))
        #expect(Principal.process(CardWorldFacts.anyProcess).route("logs") == .usersVoice)
        let wrong = NodeWire.Request(id: "2", kind: "logs", args: ["lines": .string("many")])
        guard case .failure(let failure) = wrong.typedArgs(WireKinds.Logs.Args.self) else { Issue.record("taken"); return }
        #expect(failure.code == "bad-args" && failure.message.contains("lines"))
    }
}

/// A process's facts for routing alone (`Principal.route` reads only that it is a process).
enum CardWorldFacts {
    static let anyProcess = PeerFacts(pid: 1, uid: getuid(), cgroup: nil, ancestry: nil, terminal: .none, sessionMarker: nil, underRunner: nil)
}

/// `logs` through a scratch node's requests: the user reads the session log, masked; a session's own process is refused,
/// and so is a lead's tool server. Linux only: a scratch host.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct NodeLogsVoiceTests {
    private let scratch = Scratch()

    @Test func aSessionsProcessCannotReadTheLogs() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let log = world.host.root.appendingPathComponent("host.log")
        let planted = "exported " + NodeLogsTests.planted[0] + "\n"
        if let handle = try? FileHandle(forWritingTo: log) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(planted.utf8))
            try handle.close()
        } else {
            try planted.write(to: log, atomically: true, encoding: .utf8)
        }
        let read = try #require(await world.ask("logs", ["sessions": .bool(true)], action: nil))
        #expect(read.ok && read.result?["lines"]?.array?.contains(.string(NodeLogs.masked(planted.trimmingCharacters(in: .newlines)))) == true, "\(read)")
        #expect(!String(decoding: NodeWire.replyLine(read), as: UTF8.self).contains(NodeLogsTests.planted[0]))
        let harness = try await NodeHarness.start(on: world.host, fake: world.world.fake, cwd: world.repo, label: "Claude")
        let lead = try await world.sleepingLead()
        for facts in [PeerFacts.read(pid: harness.session.childPID), CardWorld.toolServer(of: lead)] {
            let refused = try #require(await world.ask("logs", ["sessions": .bool(true)], action: nil, from: facts))
            #expect(refused.error?.code == NodeWire.Code.voice.rawValue, "\(refused)")
        }
    }
}
