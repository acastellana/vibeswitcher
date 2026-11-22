import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The captured replies the typed kinds are held to (Tests/Fixtures/wire-kinds): written scrubbed of this machine
/// (`scrub`), so a fixture names no real account, host, checkout or scratch folder; `WireFixturesTests` fails on any
/// that does. How fixtures are captured: `WireFixtureCaptureTests` (a scratch node's replies, with
/// `VIBESWITCHER_CAPTURE_FIXTURES=DIR`), and any reply captured another way scrubbed in place
/// (`VIBESWITCHER_SCRUB_FIXTURES=DIR`), before it is copied in.
enum WireFixtures {
    static let folder = ServerLintTests.repo.appendingPathComponent("Tests/Fixtures/wire-kinds")

    /// What stands for each machine-specific value.
    static let checkout = "/home/user/vibeswitcher"
    static let home = "/home/user"
    static let user = "user"
    static let host = "host"
    static let scratch = "/tmp/vs-test.scratch"

    /// This machine's values: the checkout these tests run from, the account's own home and name (not the tests' scratch
    /// home), the host's name.
    static var machine: (checkout: String, home: String?, user: String?, host: String) {
        let entry = getpwuid(getuid())
        let home = entry.flatMap { $0.pointee.pw_dir.map { String(cString: $0) } }
        let user = entry.flatMap { $0.pointee.pw_name.map { String(cString: $0) } }
        return (ServerLintTests.repo.standardizedFileURL.path, home, user, ProcessInfo.processInfo.hostName)
    }

    /// `text` (a reply as JSON) with this machine's values replaced by neutral ones: the checkout's path first, then the
    /// account's home, its name and the host's name as whole words, and each test run's scratch folder
    /// (`/tmp/vs-test.XXXXXX`, `/tmp/vs-load.XXXXXX`) by one fixed name. Paths and names hold no character JSON escapes,
    /// so the text stays the same JSON with other strings in it.
    static func scrub(_ text: String) -> String {
        let machine = machine
        var text = text.replacingOccurrences(of: machine.checkout, with: checkout)
        if let home = machine.home, home.count > 1 { text = text.replacingOccurrences(of: home + "/", with: Self.home + "/") }
        for (real, neutral) in [(machine.user, user), (machine.host, host)] {
            guard let real, real.count > 2, real != neutral else { continue }
            text = text.replacingOccurrences(of: "\\b\(NSRegularExpression.escapedPattern(for: real))\\b", with: neutral, options: .regularExpression)
        }
        return text.replacingOccurrences(of: #"/tmp/vs-(test|load)\.[A-Za-z0-9]{6}(?![A-Za-z0-9])"#, with: scratch, options: .regularExpression)
    }

    /// What in `text` still names this machine, or nil.
    static func names(_ text: String) -> String? {
        let machine = machine
        if text.contains(machine.checkout) { return machine.checkout }
        if let home = machine.home, home.count > 1, text.contains(home + "/") { return home }
        for real in [machine.user, machine.host].compactMap({ $0 }) where real.count > 2 && ![user, host].contains(real) {
            if text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: real))\\b", options: .regularExpression) != nil { return real }
        }
        return text.range(of: #"/tmp/vs-(test|load)\.[A-Za-z0-9]{6}(?![A-Za-z0-9])"#, options: .regularExpression).map { String(text[$0]) }
    }

    /// `reply` (a reply line as the server wrote it) scrubbed and written as `name`.json in `folder`.
    static func write(_ reply: Data, name: String, in folder: URL) throws {
        try Data(scrub(String(decoding: reply, as: UTF8.self)).utf8).write(to: folder.appendingPathComponent(name + ".json"))
    }
}

/// Every fixture is scrubbed: nothing of this machine in it (the checkout, the account, the host, a scratch folder's
/// name), and scrubbing it again changes nothing.
struct WireFixturesTests {
    @Test func noFixtureNamesThisMachine() throws {
        let files = try FileManager.default.subpathsOfDirectory(atPath: WireFixtures.folder.path).filter { $0.hasSuffix(".json") }
        #expect(files.count > 60, "\(files.count)")
        for file in files {
            let text = try String(contentsOf: WireFixtures.folder.appendingPathComponent(file), encoding: .utf8)
            #expect(WireFixtures.names(text) == nil, "\(file) names \(WireFixtures.names(text) ?? "")")
            #expect(WireFixtures.scrub(text) == text, "\(file)")
        }
    }

    @Test func scrubbingReplacesTheMachinesValues() {
        let machine = WireFixtures.machine
        let text = #"{"a":"\#(machine.checkout)/.build/x","b":"/tmp/vs-test.Ab12Cd/tmp/vsn-1/home","c":"/tmp/vs-load.Zz99Yy/3"}"#
        let scrubbed = WireFixtures.scrub(text)
        #expect(scrubbed == #"{"a":"/home/user/vibeswitcher/.build/x","b":"/tmp/vs-test.scratch/tmp/vsn-1/home","c":"/tmp/vs-test.scratch/3"}"#, "\(scrubbed)")
        #expect(WireFixtures.names(text) != nil && WireFixtures.names(scrubbed) == nil)
    }
}

/// Captures the read kinds' fixtures from a scratch node (a lead with a question, a board, held config, an agent, a
/// shell), scrubbed, into `VIBESWITCHER_CAPTURE_FIXTURES`; and scrubs in place every reply in
/// `VIBESWITCHER_SCRUB_FIXTURES` (one captured another way: a state change's, from a whole run). Skipped otherwise.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct WireFixtureCaptureTests {
    private let scratch = Scratch()
    static let captureTo = ProcessInfo.processInfo.environment["VIBESWITCHER_CAPTURE_FIXTURES"]
    static let scrubIn = ProcessInfo.processInfo.environment["VIBESWITCHER_SCRUB_FIXTURES"]

    @Test(.enabled(if: WireFixtureCaptureTests.scrubIn != nil, "VIBESWITCHER_SCRUB_FIXTURES names no folder"))
    func scrubAFolder() throws {
        let folder = URL(fileURLWithPath: try #require(Self.scrubIn))
        for file in try FileManager.default.subpathsOfDirectory(atPath: folder.path) where file.hasSuffix(".json") {
            let url = folder.appendingPathComponent(file)
            try Data(WireFixtures.scrub(try String(contentsOf: url, encoding: .utf8)).utf8).write(to: url)
        }
    }

    @Test(.enabled(if: WireFixtureCaptureTests.captureTo != nil, "VIBESWITCHER_CAPTURE_FIXTURES names no folder"))
    func captureTheReadKinds() async throws {
        let out = URL(fileURLWithPath: try #require(Self.captureTo))
        let node = try await ScratchNode(scratch, holdFirstLook: true)
        defer { node.stop() }
        let site = try await HookedAgent.start(node, project: "example-site")
        try site.hook(node, "Stop")
        let repo = node.root.appendingPathComponent("example-app")
        try await scratchRepository(repo)
        try EngineEndToEndTests.workflow(repo)
        let head = Git.run(["rev-parse", "main"], in: repo.path).output
        try await node.acceptConfig(repo)
        try await node.acceptBase(repo, from: head)
        let started = try await node.runOnTerminal(["lead", repo.path, "--goal", "Ship"])
        try #require(started.status == 0, "\(started.output)")
        let lead = try #require(try node.sessions().first { $0.isLive && $0.label.hasPrefix("Lead · ") })
        let tools = node.fake.files(terminal: lead.tty)
        try #require(await eventually(timeout: 60) { EngineEndToEndTests.state(tools)["pid"] != nil })
        let leadPID = try #require((EngineEndToEndTests.state(tools)["pid"] as? Int).map(Int32.init))
        try hook(node, ["hook_event_name": "Stop"], tty: lead.tty, pid: leadPID)
        try tools.call("ask_user", ["question": "Thursday or wait?", "options": ["Thursday", "Wait"]])
        try #require(await eventually(timeout: 120) { tools.calls().count == 1 })
        let made = WireVectors.sampleBoard(now: Date().timeIntervalSince1970, worker: site.session.id)
        try BoardStore(root: repo.path).update { $0.tasks = made.tasks }
        let settings = node.home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"env":{"CAPTURE":"1"}}"#.write(to: settings, atomically: true, encoding: .utf8)
        _ = try await node.spawn("exec sleep 600", cwd: repo.path, label: "Shell")
        try #require(await eventually(timeout: 120) {
            guard let client = try? WireClient(node) else { return false }
            let cards = WireClient.reply(client.request("questions", action: nil))?.result?["cards"]?.array?.count ?? 0
            let tasks = WireClient.reply(client.request("board", action: nil))?.result?["boards"]?.array?.first?["tasks"]?.array?.count ?? 0
            let shells = WireClient.reply(client.request("shells", action: nil))?.result?["shells"]?.array?.count ?? 0
            return cards > 0 && tasks > 0 && shells > 0
        })
        let client = try WireClient(node)
        let asks: [(String, String, [String: NodeWire.Value]?)] = [
            ("status", "status", nil), ("questions", "questions", nil), ("questions-all", "questions", ["all": .bool(true)]),
            ("questions-folder", "questions", ["folder": .string(repo.path)]), ("board", "board", nil), ("board-folder", "board", ["folder": .string(repo.path)]),
            ("config.held", "config.held", ["folder": .string(node.home.path)]), ("config.held-repo", "config.held", ["folder": .string(repo.path)]),
            ("settings", "settings", nil), ("settings-folder", "settings", ["folder": .string(repo.path)]), ("plugin.list", "plugin.list", nil),
            ("approve.list", "approve.list", nil), ("approve.list-config", "approve.list", ["only": .array([.string("config")])]),
            ("brief-folder", "brief", ["folder": .string(repo.path)]), ("mail", "mail", nil),
            ("mail-folder", "mail", ["folder": .string(repo.path), "all": .bool(true)]),
            ("session.presets", "session.presets", ["folder": .string(repo.path)]),
            ("session.presets-values", "session.presets", ["folder": .string(repo.path), "values": .bool(true)]),
            ("shells", "shells", nil), ("stats", "stats", ["range": .string("week")]), ("stats-today", "stats", ["range": .string("today")]),
            ("base.show", "base.show", ["folder": .string(repo.path)]),
        ]
        for (name, kind, args) in asks {
            let messages = client.request(kind, args: args, action: nil, timeout: 120)
            let line = try #require(messages.last { NodeWire.decode(NodeWire.Envelope.self, $0)?.re != nil }, "\(name)")
            try WireFixtures.write(line, name: name, in: out)
        }
        // Mail with messages and update.check, as the server's own builders write them.
        let records = [LeadMail.Record(at: 1_800_000_000, from: "example-app", to: "other", kind: .question, text: "hello", outcome: .delivered, detail: "sent"),
                       LeadMail.Record(at: 1_800_000_100, from: "other", to: "example-app", kind: nil, text: "refused one", outcome: .delivered, detail: "why")]
        let project = NodeWire.Value.object(["root": .string(repo.path), "project": .string("example-app"), "total": .int(5),
                                             "messages": .array(records.reversed().map { Requests.mailValue($0, project: "example-app") })])
        try WireFixtures.write(NodeWire.message(NodeWire.Reply(re: "t1", result: .object(["projects": .array([project])]))), name: "mail-messages", in: out)
        let running = String(repeating: "a", count: 40), newer = String(repeating: "b", count: 40)
        for (name, failing) in [("update.check", false), ("update.check-problem", true)] {
            let runs = [UpdateWatch.Run(databaseId: 1, workflowName: "v2 linux", headSha: newer, status: "completed", conclusion: "success"),
                        UpdateWatch.Run(databaseId: 2, workflowName: "v2 macos", headSha: newer, status: "completed", conclusion: "success")]
            let looker = UpdateWatch.Looker(runs: { failing ? .failure(.init("offline")) : .success(runs) },
                                            compare: { base, head in .success(.init(status: base == running && head == newer ? "ahead" : "identical", aheadBy: 1)) })
            let queue = DispatchQueue(label: "capture-\(name)")
            let watch = UpdateWatch(file: scratch.url("\(name).json"), running: running, looker: looker, queue: queue, note: { _ in })
            let told = Locked<NodeWire.Value?>(nil)
            queue.async { watch.look { told.value = watch.checked } }
            try #require(await eventually(timeout: 60) { told.value != nil })
            try WireFixtures.write(NodeWire.message(NodeWire.Reply(re: "t1", result: told.value!)), name: name, in: out)
        }
    }
}
