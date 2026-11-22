import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The wire's schema, its vectors and the web client's validators (the live plan's E1, LW-D10): `WireSchema` is what the
/// encoders write, both ways; `WebApp/wire/validators.js` and `vectors.json` are what `WireVectors` writes from it; each
/// vector passes its validator, a wrong type fails naming the field, an unknown field passes (rule 3); and every vector
/// the live wire contract names is there. The JavaScript cases run the generated files with Node, and are skipped, with
/// their reason, where there is none. The Mac runs these.
struct WireVectorsTests {
    private let scratch = Scratch()

    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let contract = repo.appendingPathComponent("docs/superpowers/specs/2026-11-17-v2-live-wire-contract.md")

    /// Node, from the PATH this test was given; nil where there is none.
    static let node: String? = {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").map { "\($0)/node" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    // MARK: The schema against the encoders

    /// Every card, lead and message sample checked strictly (no key the schema lacks, no field it needs missing, every
    /// type its own), and every field of what they reach seen set and, where it may be, absent or null: the schema is
    /// what the encoders write, both ways. Fields the schema marks `pending` (written elsewhere, or by a task still to
    /// land) are left out of both.
    @Test func theSchemaIsWhatTheEncodersWrite() throws {
        var seen: Set<String> = []
        func check(_ value: NodeWire.Value, _ kind: String, _ what: String) {
            let failure = WireSchema.check(value, as: kind, strict: true) { field, state in seen.insert("\(field) \(state)") }
            #expect(failure == nil, "\(what): \(failure ?? "")")
        }
        for (index, card) in Samples.cards.enumerated() { check(card.value, "card", "card sample \(index) (\(card.kind.rawValue))") }
        for (index, lead) in Samples.leads.enumerated() { check(lead.value, "lead", "lead sample \(index)") }
        for (index, hello) in Samples.hellos.enumerated() { check(try Samples.value(hello), "hello", "hello sample \(index)") }
        for (index, bye) in Samples.byes.enumerated() { check(try Samples.value(bye), "bye", "bye sample \(index)") }
        for (index, request) in Samples.requests.enumerated() { check(try Samples.value(request), "request", "request sample \(index)") }
        for (index, reply) in Samples.replies.enumerated() { check(try Samples.value(reply), "reply", "reply sample \(index)") }
        for (index, item) in Samples.chatItems.enumerated() {
            check(try #require(ChatValue.value(item), "chat item \(index)"), "chat.item", "chat item sample \(index)")
        }

        let wanted = WireSchema.coverage(of: ["card", "lead", "hello", "bye", "request", "reply", "chat.item"])
        #expect(!wanted.isEmpty)
        let missed = wanted.subtracting(seen).sorted()
        #expect(missed.isEmpty, "never seen in the samples: \(missed.joined(separator: ", "))")
    }

    /// The other way round: a key the encoder writes that the schema lacks is caught, as is a field the schema needs
    /// that the encoder left out.
    @Test func aStrictCheckFindsWhatTheSchemaLacks() throws {
        guard case .object(var fields) = Samples.cards[0].value else { Issue.record("a card isn't an object"); return }
        fields["surprise"] = .int(1)
        #expect(WireSchema.check(.object(fields), as: "card", strict: true) == "surprise: not in the schema")
        #expect(WireSchema.check(.object(fields), as: "card") == nil)
        fields["surprise"] = nil
        fields["blocking"] = nil
        #expect(WireSchema.check(.object(fields), as: "card") == "blocking: missing")
    }

    // MARK: The files

    @Test func theCheckedInFilesAreWhatTheGeneratorWrites() throws {
        let files = WireVectors.files()
        #expect(Set(files.keys) == ["validators.js", "vectors.json"])
        for (name, data) in files.sorted(by: { $0.key < $1.key }) {
            let url = Self.repo.appendingPathComponent("WebApp/wire").appendingPathComponent(name)
            let checkedIn = try? Data(contentsOf: url)
            #expect(checkedIn == data,
                    "WebApp/wire/\(name) is stale: run `.build/debug/vibeswitcher-cli wire-vectors --out WebApp/wire` and commit it")
        }
    }

    @Test func theGeneratorIsReproducible() {
        #expect(WireVectors.files() == WireVectors.files())
    }

    /// `vibeswitcher wire-vectors --out DIR` writes the generator's files into a folder that exists, and refuses one that
    /// doesn't; without `--out` it is a usage error.
    @Test func theCommandWritesTheGeneratorsFiles() async throws {
        let folder = scratch.url("wire-out")
        let out = folder.appendingPathComponent("wire")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let missing = try await run(commandLine, ["wire-vectors", "--out", out.path], environment: scratchEnvironment(folder))
        #expect(missing.status == 73 && missing.errors.contains("no folder"), "\(missing.errors)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let ran = try await run(commandLine, ["wire-vectors", "--out", out.path], environment: scratchEnvironment(folder))
        #expect(ran.status == 0, "\(ran.errors)")
        for (name, data) in WireVectors.files() {
            #expect((try? Data(contentsOf: out.appendingPathComponent(name))) == data, "\(name) as the command wrote it")
        }
        let bare = try await run(commandLine, ["wire-vectors"], environment: scratchEnvironment(folder))
        #expect(bare.status == 64)
        #expect(bare.errors.contains("--out"))
    }

    // MARK: The vectors

    /// Every name the contract's §11 gives a vector, and §8's, each a vector.
    @Test func theContractsVectorsAreAllThere() throws {
        let text = try String(contentsOf: Self.contract, encoding: .utf8)
        let section11 = try #require(text.range(of: "## 11. Vectors").map { String(text[$0.lowerBound...]) }, "the contract has no §11")
        let pattern = try NSRegularExpression(pattern: "`([a-z]+\\.[a-z-]+)`")
        let named = Set(pattern.matches(in: section11, range: NSRange(section11.startIndex..., in: section11)).compactMap {
            Range($0.range(at: 1), in: section11).map { String(section11[$0]) }
        })
        // §11 names sixteen; a parse that finds far fewer is the test's fault, not the vectors'.
        #expect(named.count >= 16, "the contract's §11 names \(named.sorted())")
        // §8's vectors have headings, not names: the names given them here.
        let section8 = ["draft.acked", "draft.refused", "answer.from-a-page"]
        let have = Set(WireVectors.all.map(\.name))
        for name in named.union(section8).sorted() { #expect(have.contains(name), "no vector \(name)") }

        let json = try #require(WireVectors.files()["vectors.json"])
        let written = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(Set(written.keys) == have)
    }

    /// Each vector frame passes the Swift check for its kind (the JavaScript one's twin).
    @Test func everyVectorPassesTheSchema() {
        for vector in WireVectors.all {
            for (index, frame) in vector.frames.enumerated() {
                let failure = WireSchema.check(frame.value, as: frame.kind)
                #expect(failure == nil, "\(vector.name) frame \(index) as \(frame.kind): \(failure ?? "")")
            }
        }
    }

    @Test(.enabled(if: WireVectorsTests.node != nil, "no node on the PATH: the generated JavaScript isn't run"))
    func everyVectorPassesItsValidator() async throws {
        let cases = WireVectors.all.flatMap { vector in vector.frames.enumerated().map { ("\(vector.name) frame \($0.offset)", $0.element) } }
        let results = try await javaScript(cases.map { ($0.1.kind, $0.1.value) })
        #expect(results.count == cases.count)
        for (index, result) in results.enumerated() where index < cases.count {
            #expect(result == nil, "\(cases[index].0) as \(cases[index].1.kind): \(result ?? "")")
        }
        // `frame` tells a request, a reply and each event apart by itself.
        let framed = try await javaScript(cases.map { ("frame", $0.1.value) })
        #expect(framed.allSatisfy { $0 == nil }, "\(framed)")
    }

    /// A frame with one field of the wrong type, or missing, fails naming that field, in JavaScript and in Swift alike.
    @Test(.enabled(if: WireVectorsTests.node != nil, "no node on the PATH: the generated JavaScript isn't run"))
    func aVectorWithAWrongTypeFailsNamingTheField() async throws {
        let cases = try Self.brokenCases()
        let results = try await javaScript(cases.map { ($0.kind, $0.value) })
        for (index, broken) in cases.enumerated() {
            #expect(results[safe: index] == .some(broken.failure), "\(broken.what): JavaScript said \(String(describing: results[safe: index]))")
            #expect(WireSchema.check(broken.value, as: broken.kind) == broken.failure, "\(broken.what), in Swift")
        }
    }

    /// Rule 3: a reader ignores a field it doesn't know, at the top of a frame and inside every object in it.
    @Test(.enabled(if: WireVectorsTests.node != nil, "no node on the PATH: the generated JavaScript isn't run"))
    func anUnknownFieldPasses() async throws {
        let cases = WireVectors.all.flatMap { vector in vector.frames.map { ($0.kind, Self.withUnknownFields($0.value)) } }
        #expect(cases.contains { $0.1 != WireVectors.all.first?.frames.first?.value })
        let results = try await javaScript(cases)
        #expect(results.count == cases.count && results.allSatisfy { $0 == nil }, "\(results.compactMap { $0 })")
        for (kind, value) in cases { #expect(WireSchema.check(value, as: kind) == nil, "\(kind) in Swift") }
    }

    // MARK: An older server's frames

    /// The vectors of the build installed before this one, frozen (`Tests/Fixtures/wire/vectors-<commit>.json`, the
    /// architecture review's row 11): right after a switch the command line and the page are one build and the server
    /// may be the one before, so today's readers must still take what it wrote. Each frame decodes as its envelope
    /// (`Reply`, `Hello`, `Bye`, `Request`) and passes today's check for its kind, in Swift and in JavaScript.
    static func olderFrames() throws -> [(what: String, value: NodeWire.Value)] {
        let folder = repo.appendingPathComponent("Tests/Fixtures/wire")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("vectors-") && $0.hasSuffix(".json") }.sorted()
        var frames: [(String, NodeWire.Value)] = []
        for name in names {
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            guard case .object(let vectors) = try #require(NodeWire.decode(NodeWire.Value.self, data), "\(name) isn't JSON") else {
                Issue.record("\(name) isn't an object of vectors"); continue
            }
            for (vector, value) in vectors.sorted(by: { $0.key < $1.key }) {
                let list = value.array ?? [value]
                for (index, frame) in list.enumerated() { frames.append(("\(name) \(vector) frame \(index)", frame)) }
            }
        }
        return frames
    }

    @Test func thePreviousBuildsFramesStillRead() throws {
        let frames = try Self.olderFrames()
        #expect(frames.count > 40, "\(frames.count)")
        for (what, frame) in frames {
            #expect(WireSchema.check(frame, as: "frame") == nil, "\(what): \(WireSchema.check(frame, as: "frame") ?? "")")
            let line = NodeWire.line(frame).dropLast()
            switch (frame["re"], frame["kind"]?.string) {
            case (.some, _): #expect(NodeWire.decode(NodeWire.Reply.self, line) != nil, "\(what) as a reply")
            case (nil, "hello"): #expect(NodeWire.decode(NodeWire.Hello.self, line) != nil, "\(what) as a hello")
            case (nil, "bye"): #expect(NodeWire.decode(NodeWire.Bye.self, line) != nil, "\(what) as a bye")
            case (nil, _) where frame["id"] != nil: #expect(NodeWire.decode(NodeWire.Request.self, line) != nil, "\(what) as a request")
            default: break
            }
        }
    }

    @Test(.enabled(if: WireVectorsTests.node != nil, "no node on the PATH: the generated JavaScript isn't run"))
    func thePreviousBuildsFramesPassTodaysValidators() async throws {
        let frames = try Self.olderFrames()
        let results = try await javaScript(frames.map { ("frame", $0.value) })
        #expect(results.count == frames.count)
        for (index, result) in results.enumerated() where index < frames.count {
            #expect(result == nil, "\(frames[index].what): \(result ?? "")")
        }
    }

    // MARK: Helpers

    struct Broken {
        var what: String
        var kind: String
        var value: NodeWire.Value
        var failure: String
    }

    /// Vectors broken one field each, with the failure each must give.
    static func brokenCases() throws -> [Broken] {
        func vector(_ name: String, _ frame: Int = 0) throws -> (kind: String, value: NodeWire.Value) {
            let found = try #require(WireVectors.all.first { $0.name == name }, "no vector \(name)")
            return (found.frames[frame].kind, found.frames[frame].value)
        }
        var cases: [Broken] = []
        let sessions = try vector("snapshot.sessions")
        cases.append(.init(what: "a session's since as a number", kind: sessions.kind,
                           value: Self.set(sessions.value, ["entries", 0, "value", "since"], .int(5)), failure: "entries[0].value.since: expected a date"))
        let hello = try vector("hello.web")
        cases.append(.init(what: "a hello without its epoch", kind: hello.kind, value: Self.set(hello.value, ["epoch"], nil),
                           failure: "epoch: missing"))
        cases.append(.init(what: "a hello whose rights aren't a list", kind: hello.kind,
                           value: Self.set(hello.value, ["auth", "rights"], .string("read")), failure: "auth.rights: expected a list"))
        let drafted = try vector("draft.acked", 1)
        cases.append(.init(what: "a card's question version as text", kind: drafted.kind,
                           value: Self.set(drafted.value, ["changes", 0, "value", "question", "version"], .string("2")),
                           failure: "changes[0].value.question.version: expected an integer"))
        let subscribe = try vector("subscribe.sessions")
        cases.append(.init(what: "a subscribe whose sub is a number", kind: subscribe.kind,
                           value: Self.set(subscribe.value, ["args", "sub"], .int(1)), failure: "args.sub: expected a string"))
        let tail = try vector("resume.chat-tail", 2)
        cases.append(.init(what: "a tool result's failed as text", kind: tail.kind,
                           value: Self.set(tail.value, ["items", 0, "tools", 0, "result", "failed"], .string("no")),
                           failure: "items[0].tools[0].result.failed: expected true or false"))
        let node = try vector("snapshot.node")
        cases.append(.init(what: "the node's web as null", kind: node.kind, value: Self.set(node.value, ["entries", 0, "value", "web"], .null),
                           failure: "entries[0].value.web: expected an object"))
        return cases
    }

    /// `value` with `path` (keys and indexes) set to `new`, or removed when `new` is nil.
    static func set(_ value: NodeWire.Value, _ path: [Any], _ new: NodeWire.Value?) -> NodeWire.Value {
        guard let step = path.first else { return new ?? .null }
        let rest = Array(path.dropFirst())
        switch (value, step) {
        case (.object(var fields), let key as String):
            if rest.isEmpty, new == nil { fields[key] = nil } else { fields[key] = set(fields[key] ?? .null, rest, new) }
            return .object(fields)
        case (.array(var items), let index as Int) where index < items.count:
            items[index] = set(items[index], rest, new)
            return .array(items)
        default:
            return value
        }
    }

    /// The fields whose keys are data, not names (`WireSchema.Kind.map`): no unknown field goes in them.
    static let maps: Set<String> = ["applied", "verdicts"]

    /// `value` with an unknown field in every object in it but a map's.
    static func withUnknownFields(_ value: NodeWire.Value, map: Bool = false) -> NodeWire.Value {
        switch value {
        case .object(let fields):
            var fields = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, withUnknownFields($0.value, map: maps.contains($0.key))) })
            if !map { fields["zz-unknown"] = .object(["n": .int(1)]) }
            return .object(fields)
        case .array(let items):
            return .array(items.map { withUnknownFields($0) })
        default:
            return value
        }
    }

    /// `validate(kind, value)` of the generator's `validators.js` for each case, run by Node on the files written to a
    /// scratch folder: each failure, or nil.
    private func javaScript(_ cases: [(String, NodeWire.Value)]) async throws -> [String?] {
        let node = try #require(Self.node)
        let folder = scratch.url("wire-js")
        let wire = folder.appendingPathComponent("wire")
        try FileManager.default.createDirectory(at: wire, withIntermediateDirectories: true)
        for (name, data) in WireVectors.files() { try data.write(to: wire.appendingPathComponent(name)) }
        try Data(#"{"type":"module"}"#.utf8).write(to: wire.appendingPathComponent("package.json"))
        let input = NodeWire.Value.array(cases.map { .object(["kind": .string($0.0), "value": $0.1]) })
        try NodeWire.line(input).write(to: folder.appendingPathComponent("cases.json"))
        let script = """
            import { readFileSync } from "node:fs";
            import { pathToFileURL } from "node:url";
            const [wire, cases] = process.argv.slice(2);
            const { validate } = await import(pathToFileURL(wire + "/validators.js").href);
            const results = JSON.parse(readFileSync(cases, "utf8")).map((c) => validate(c.kind, c.value));
            process.stdout.write(JSON.stringify(results));
            """
        try Data(script.utf8).write(to: folder.appendingPathComponent("run.mjs"))
        let ran = try await run(URL(fileURLWithPath: node), [folder.appendingPathComponent("run.mjs").path, wire.path,
                                                              folder.appendingPathComponent("cases.json").path],
                                environment: scratchEnvironment(folder))
        try #require(ran.status == 0, "node: \(ran.errors)")
        let results = try #require(try JSONSerialization.jsonObject(with: Data(ran.output.utf8)) as? [Any])
        return results.map { $0 as? String }
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// What the encoders are checked on: each card kind, lead, message and chat item with every optional field set in one
/// sample and unset in another.
enum Samples {
    static let at = Date(timeIntervalSince1970: 1_763_370_000.250)
    static let root = "/home/u/acme-site"

    static var cards: [CardStore.Card] {
        var full = LeadQuestion(id: "q-7", text: "Merge now?", options: ["Yes", "Wait"], priority: .blocking, whyNow: "two tasks wait",
                                proposal: "Yes", decideIn: 10, at: at.timeIntervalSince1970)
        full.revisions = [.init(text: "Merge?", options: ["Yes"], note: "narrowed", at: at.timeIntervalSince1970)]
        full.answer = "Yes"
        full.answeredVersion = 2
        full.withdrawReason = "moot"
        full.task = "login-fix"
        var counting = LeadQuestion(id: "q-8", text: "Which?", options: ["a"], proposal: "a", decideIn: 5, at: at.timeIntervalSince1970)
        counting.task = nil
        let bare = LeadQuestion(id: "q-9", text: "Bare", options: [])

        var asked = CardStore.Card(id: "local:card:00000000-0000-4000-8000-000000000001", root: root, kind: .question, at: at)
        asked.question = full
        asked.closed = "answered"
        asked.notice = "taken late"
        var timed = CardStore.Card(id: "local:card:00000000-0000-4000-8000-000000000002", root: root, kind: .question, at: at)
        timed.question = counting
        // A draft a page left (B5), for the version it showed.
        timed.draft = .init(text: "a", version: counting.version, at: at, action: "6f1d2a34-9b8c-4e7d-a1f0-3c5b7d9e2f46")
        var plain = CardStore.Card(id: "local:card:00000000-0000-4000-8000-000000000003", root: root, kind: .question, at: at)
        plain.question = bare

        var approval = CardStore.Card(id: "local:card:00000000-0000-4000-8000-000000000004", root: root, kind: .approval, at: at)
        approval.question = bare
        approval.approval = .init(commit: String(repeating: "a", count: 40), tasks: ["login-fix"], base: "main", files: ["a.swift"],
                                  diffstat: "1 file changed", subject: "Fix login", verdicts: ["login-fix": "complete"],
                                  sensitive: ["a.swift"], problems: ["none"])
        var vouchless = CardStore.Card(id: "local:card:00000000-0000-4000-8000-000000000005", root: root, kind: .approval, at: at)
        vouchless.approval = .init(commit: String(repeating: "b", count: 40))

        var config = CardStore.Card(id: "local:card:00000000-0000-4000-8000-000000000006", root: root, kind: .configHeld, at: at)
        config.config = .init(items: [.init(name: "~/.claude/skills", changedAt: at, size: 12, hash: "abcdef012345", change: "added",
                                            outside: true, files: [.init(path: "x/SKILL.md", change: .added)], sinceAccept: "new"),
                                      .init(name: "settings.json")],
                              floor: LeadReviewFloor(), baseBranch: "main",
                              guarded: [.init(key: "test_command", value: "make test", sinceAccept: "same"), .init(key: "merge_policy", value: "auto")],
                              lastAccept: at)
        var bareConfig = CardStore.Card(id: "local:card:00000000-0000-4000-8000-000000000007", root: root, kind: .configHeld, at: at)
        bareConfig.config = .init()

        var base = CardStore.Card(id: "local:card:00000000-0000-4000-8000-000000000008", root: root, kind: .baseMove, at: at)
        base.base = .init(branch: "main", from: "1111111", fromIs: .recorded, to: "2222222", commits: [.init(sha: "2222222", subject: "Move")],
                          reason: "not a session's")
        var bareBase = CardStore.Card(id: "local:card:00000000-0000-4000-8000-000000000009", root: root, kind: .baseMove, at: at)
        bareBase.base = .init(branch: "main", from: nil, fromIs: .none, to: "3333333", commits: [])
        // A shell request's cards (`ShellCards.swift`): one waiting, one started, one that failed.
        let request = ShellRequest(id: "5b1e9a20-7c4d-4f3e-9a8b-1c2d3e4f5a6b", session: "3f6c2c1e-8a5b-4c1d-9e0f-2b7a6d5c4e3f", cwd: root,
                                   command: "make install", label: "install", createdAt: at)
        var shell = CardStore.Card(id: "local:card:00000000-0000-4000-8000-00000000000a", root: root, kind: .shell, at: at)
        shell.shell = .init(request: request, asker: "Claude · acme-site")
        var startedShell = CardStore.Card(id: "local:card:00000000-0000-4000-8000-00000000000b", root: root, kind: .shell, at: at)
        startedShell.shell = .init(request: request, asker: "Claude · acme-site", state: .started, shell: "7a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d",
                                   name: "Shell: install")
        startedShell.closed = "run: started in a new shell session \"Shell: install\""
        var failedShell = CardStore.Card(id: "local:card:00000000-0000-4000-8000-00000000000c", root: root, kind: .shell, at: at)
        failedShell.shell = .init(request: request, asker: "Claude · acme-site", state: .failed, why: "the folder isn't allowed")
        failedShell.closed = "didn't start: the folder isn't allowed"
        return [asked, timed, plain, approval, vouchless, config, bareConfig, base, bareBase, shell, startedShell, failedShell]
    }

    static var leads: [LeadStore.Lead] {
        var full = LeadStore.Lead(project: NodeIds.project(root: root), root: root)
        full.session = UUID(uuidString: "3f6c2c1e-8a5b-4c1d-9e0f-2b7a6d5c4e3f")
        full.named = "3F6C2C1E-8A5B-4C1D-9E0F-2B7A6D5C4E3F"
        full.bound = "3f6c2c1e-8a5b-4c1d-9e0f-2b7a6d5c4e3f"
        full.replaced = [UUID(): UUID()]
        full.held = 2
        full.notice = "the board names another session"
        full.starting = true
        full.lastStart = "started"
        full.lastStartAt = at
        full.push = LeadPush.Request(id: "3c9e1f20", commit: String(repeating: "c", count: 40), remote: "origin", branch: "main",
                                     url: "git@example.invalid:r.git", ahead: 1, subjects: ["ccccccc One"], askedAt: at.timeIntervalSince1970)
        return [full, LeadStore.Lead(project: NodeIds.project(root: "/home/u/notes"), root: "/home/u/notes")]
    }

    static var hellos: [NodeWire.Hello] {
        [NodeWire.Hello(node: "local", epoch: "e", server: .init(commit: "c", startedAt: NodeWire.dateText(at), pid: 2),
                        host: .init(startedAt: NodeWire.dateText(at),
                                    notes: Requests.value(HostNotes(startedAt: at, serverRestarts: 1, replacedPaths: ["/x"], refusedAppConnections: 0,
                                                                    lockHeldElsewhere: "pid 7", build: "f62aef61"), at: at),
                                    pid: 1),
                        kinds: ["status"], peer: .init(voice: "other", why: "a web client"), rule: "systemd",
                        auth: .object(["rights": .array([.string("read")]), "token": .string("t"), "expiresAt": .date(at)]),
                        assets: "9f2c61d0"),
         NodeWire.Hello(node: "local", epoch: "e", server: .init(commit: "c", startedAt: NodeWire.dateText(at), pid: 2),
                        host: .init(startedAt: nil, notes: nil, pid: nil), kinds: [], peer: .init(voice: "user", why: nil), rule: "weaker"),
         NodeWire.Hello(node: "local", epoch: "e", server: .init(commit: "c", startedAt: NodeWire.dateText(at), pid: 2),
                        host: .init(startedAt: nil, notes: Requests.value(HostNotes(startedAt: at, serverRestarts: 0, replacedPaths: [],
                                                                                    refusedAppConnections: 0), at: at)), kinds: [], peer: .init(voice: "other", why: "a web client"), rule: "systemd",
                        auth: .object(["rights": .array([.string("read")]), "expiresAt": .date(at)]), assets: "9f2c61d0")]
    }

    static var byes: [NodeWire.Bye] { [NodeWire.Bye(reason: "stopping", code: "stopping"), NodeWire.Bye(reason: "a line too long")] }

    static var requests: [NodeWire.Request] {
        [NodeWire.Request(id: "1", kind: "answer", args: ["card": .string("c")], action: "a", must: true),
         NodeWire.Request(id: "2", kind: "status")]
    }

    static var replies: [NodeWire.Reply] {
        [NodeWire.Reply(re: "1", result: .object([:])), NodeWire.Reply(re: "2", error: .init(.voice, "not the user's voice"))]
    }

    /// One of each chat item and tool detail the reader makes, with optional fields set and unset.
    static var chatItems: [ChatItem] {
        let at = Date(timeIntervalSince1970: 1_763_370_000.25)
        let image = ChatImage(id: "img", mediaType: "image/png", data: Data([1, 2, 3]))
        let details: [ToolDetail] = [
            .thought("hmm"), .todos([ChatTodo(text: "a", status: .pending), ChatTodo(text: "b", status: .active), ChatTodo(text: "c", status: .done)]),
            .plan("plan"), .command("ls"), .edit(path: "a.swift", changes: [ChatEditChange(old: "a", new: "b")]),
            .write(path: "b.swift", content: "x"), .read(path: "c.swift"), .patch("*** Begin Patch"),
            .questions([ChatQuestion(question: "Which?", options: ["A", "B"], header: "Pick", descriptions: ["first", nil], multiSelect: true),
                        ChatQuestion(question: "Sure?", options: ["Yes"])]),
            .agent(description: "explore", prompt: "look"), .fields([ChatField(name: "subject", value: "Write c.txt")]),
        ]
        let tools = details.enumerated().map { index, detail in
            ChatTool(id: "t\(index)", name: "Tool", title: "Tool \(index)", detail: detail, at: index == 0 ? nil : at,
                     result: index % 2 == 0 ? nil : ChatResult(output: "out", truncated: index == 1, failed: index == 3, at: index == 1 ? nil : at,
                                                               images: index == 1 ? [image] : []))
        }
        var items: [ChatItem] = [
            .prompt(ChatEntry(id: "p1", at: at, kind: .prompt(text: "Hi", images: [image]))),
            .prompt(ChatEntry(id: "p2", at: nil, kind: .steered(text: "Also this", fromLead: true))),
            .reply(ChatEntry(id: "r1", at: at, kind: .reply("**Done**"))),
            .reply(ChatEntry(id: "r2", at: nil, kind: .reply("More"))),
            .tools(id: ChatItem.toolsID("t0"), tools),
            .tools(id: ChatItem.toolsID("t1"), Array(tools.dropFirst())),
        ]
        let senders: [TeamMessage.Sender] = [.user, .lead("lead of acme"), .vibeSwitcher("worker login-fix"), .vibeSwitcher("witness"),
                                             .teammate(member: "ana", task: "login-fix")]
        for (index, sender) in senders.enumerated() {
            let message = TeamMessage(sender: sender, body: "Body \(index)", part: index == 2 ? .init(index: 1, count: 2) : nil)
            items.append(.team(ChatEntry(id: "m\(index)", at: index == 0 ? nil : at, kind: .steered(text: message.text, fromLead: message.fromLead), team: message), message))
        }
        // The all-done card in the lead's chat: one with its summary, receipts and seen mark, one from before those.
        var full = LeadAllDone(id: "done-1", at: at.timeIntervalSince1970, since: 0, tasks: [LeadAllDone.Task(slug: "a", title: "A", outcome: .merged),
                                                                                             LeadAllDone.Task(slug: "b", title: "B", outcome: .reverted)])
        full.summary = LeadAllDone.Summary(headline: "A is in", bullets: ["B was put back"], byModel: true)
        full.receipts = try? JSONDecoder().decode(LeadReceiptTotals.self, from: Data(#"{"tasks":1,"worked":60,"tokens":10,"cost":0.1,"unpriced":0,"pricesAsOf":"2026-11-01"}"#.utf8))
        full.seenAt = at.timeIntervalSince1970
        items += [.allDone(full), .allDone(LeadAllDone(id: "done-0", at: at.timeIntervalSince1970, since: 0, tasks: []))]
        return items
    }

    /// An encodable message as the value its JSON is.
    static func value<T: Encodable>(_ message: T) throws -> NodeWire.Value {
        try #require(NodeWire.decode(NodeWire.Value.self, NodeWire.line(message).dropLast()))
    }
}
