import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The developer tools notice on a node (`NodeToolchain`): what a project's files say its gate needs, read without
/// following a link or blocking, a pinned version kept only when it reads as one; the node's tools asked once a look
/// (a stand-in here), never in a project's folder; a missing or other-than-named tool a standing notice, a change told
/// to the lead once and noted for a day.
struct NodeToolchainTests {
    /// A FIFO pin is never waited on: the look returns well inside this (it opens with O_NONBLOCK).
    static let fifoLimit: TimeInterval = 5
    /// A program that never ends is stopped at its 1 s timeout; this bounds the stop and its reaping.
    static let stoppedLimit: TimeInterval = 10

    private let scratch = Scratch()

    private func project(_ name: String, files: [String: String]) throws -> String {
        let root = scratch.url(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (file, text) in files { try text.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8) }
        return root.path
    }

    private func tools(swift: String? = nil, node: String? = nil, installed: [String] = []) -> NodeToolchain.Tools {
        NodeToolchain.Tools(versions: ["swift": swift, "node": node], installedSwift: installed)
    }

    @Test func aProjectsFilesSayWhatItsGateNeeds() throws {
        let swift = try project("swift", files: ["Package.swift": "// swift-tools-version:6.0\n", ".swift-version": "6.4.2\n"])
        #expect(NodeToolchain.needs(root: swift) == [.init(tool: "swift", because: "Package.swift, .swift-version", wanted: "6.4.2")])
        let web = try project("web", files: ["package.json": "{}", ".node-version": "v22\n"])
        #expect(NodeToolchain.needs(root: web) == [.init(tool: "node", because: "package.json, .node-version", wanted: "v22")])
        let both = try project("both", files: ["Package.swift": "", "package.json": "{}", ".nvmrc": "\n"])
        #expect(NodeToolchain.needs(root: both) == [.init(tool: "swift", because: "Package.swift"), .init(tool: "node", because: "package.json")])
        #expect(NodeToolchain.needs(root: try project("plain", files: ["README.md": "#"])).isEmpty)
    }

    /// A pin that's a link is never followed (nor a `Package.swift` that's one), a FIFO doesn't hang the look, and a
    /// value that isn't a version (`lts/*`, escapes, words) is never kept or shown.
    @Test func aPinIsReadOnlyFromARegularFileAndOnlyAsAVersion() throws {
        let outside = scratch.url("outside.txt")
        try "6.9\n".write(to: outside, atomically: true, encoding: .utf8)
        let linked = try project("linked", files: ["Package.swift": ""])
        try FileManager.default.createSymbolicLink(atPath: linked + "/.swift-version", withDestinationPath: outside.path)
        #expect(NodeToolchain.needs(root: linked) == [.init(tool: "swift", because: "Package.swift")])

        let manifest = try project("manifest", files: [:])
        try FileManager.default.createSymbolicLink(atPath: manifest + "/Package.swift", withDestinationPath: outside.path)
        #expect(NodeToolchain.needs(root: manifest).isEmpty)

        let fifo = try project("fifo", files: ["package.json": "{}"])
        try #require(mkfifo(fifo + "/.nvmrc", 0o600) == 0)
        let start = Date()
        #expect(NodeToolchain.needs(root: fifo) == [.init(tool: "node", because: "package.json")])
        #expect(Date().timeIntervalSince(start) < Self.fifoLimit)

        for (index, weird) in ["lts/*", "6.4\u{1B}[31m", "latest; rm -rf ~", "1.2.3.4.5", String(repeating: "9", count: 300)].enumerated() {
            let root = try project("weird-\(index)", files: ["Package.swift": "", ".swift-version": weird + "\n"])
            #expect(NodeToolchain.needs(root: root).first?.wanted == nil, "\(weird)")
        }
        #expect(NodeToolchain.isVersion("6.4.2") && NodeToolchain.isVersion("v22") && !NodeToolchain.isVersion("v") && !NodeToolchain.isVersion("6..4"))
    }

    @Test func aVersionIsReadAndMatchedAsTheProjectNamesIt() {
        #expect(NodeToolchain.version(tool: "swift", output: "Swift version 6.4.2 (swift-6.4.2-RELEASE)\nTarget: x86_64-unknown-linux-gnu") == "6.4.2")
        #expect(NodeToolchain.version(tool: "node", output: "v22.11.0") == "22.11.0")
        #expect(NodeToolchain.version(tool: "swift", output: "error: toolchain 6.9 isn't installed") == nil)
        #expect(NodeToolchain.matches("6.4.2", wanted: "6.4"))
        #expect(NodeToolchain.matches("22.11.0", wanted: "v22"))
        #expect(!NodeToolchain.matches("6.4.2", wanted: "6.5"))
        #expect(!NodeToolchain.matches("6.4", wanted: "6.4.2"))
    }

    /// The live ask: run by its absolute path from `/`, never a working folder; PATH's relative folders dropped; one
    /// that never ends stopped in its time.
    @Test func theLiveAskRunsFromTheRootNeverAProjectsFolder() throws {
        let bin = scratch.url("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let marker = scratch.url("ran-in")
        let program = bin.appendingPathComponent("swift")
        try writeClosedOnExec("#!/bin/sh\npwd > '\(marker.path)'\necho 'Swift version 6.4.2 (swift-6.4.2-RELEASE)'\n", to: program)
        // Written through a close-on-exec descriptor: no other test's child holds it open, so it runs at once.
        let output = NodeToolchain.run([program.path, "--version"], environment: ["PATH=/usr/bin:/bin"], timeout: 15)
        #expect(output.flatMap { NodeToolchain.version(tool: "swift", output: $0) } == "6.4.2")
        #expect(try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "/")
        #expect(NodeToolchain.absolutePath("bin:.::/usr/bin") == "/usr/bin")
        let start = Date()
        #expect(NodeToolchain.run(["/bin/sleep", "30"], environment: [], timeout: 1) == nil)
        #expect(Date().timeIntervalSince(start) < Self.stoppedLimit)
    }

    /// The first look keeps what it found and tells nothing; a change is told to that project's lead once and noted for a
    /// day; a tool that stops running is a problem while it stands, and its return (to the same version) isn't a change.
    @Test func aChangeIsToldOnceAndAProblemStandsWhileItLasts() throws {
        let root = try project("app", files: ["Package.swift": "", ".swift-version": "6.4\n"])
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var seen = NodeToolchain.observe(.init(), roots: [root], now: start, tools: tools(swift: "6.4.2"))
        #expect(seen.told.isEmpty && seen.notices.isEmpty)
        #expect(seen.book.versions[root] == ["swift": "6.4.2"])

        seen = NodeToolchain.observe(seen.book, roots: [root], now: start.addingTimeInterval(600), tools: tools(swift: "6.4.3"))
        let told = try #require(seen.told[root])
        #expect(told.contains("swift 6.4.2 → 6.4.3") && told.contains("never changes them"))
        #expect(seen.notices == [told])
        seen = NodeToolchain.observe(seen.book, roots: [root], now: start.addingTimeInterval(1200), tools: tools(swift: "6.4.3"))
        #expect(seen.told.isEmpty && seen.notices == [told])
        seen = NodeToolchain.observe(seen.book, roots: [root], now: start.addingTimeInterval(600 + NodeToolchain.noteFor), tools: tools(swift: "6.4.3"))
        #expect(seen.notices.isEmpty)

        seen = NodeToolchain.observe(seen.book, roots: [root], now: start.addingTimeInterval(2 * NodeToolchain.noteFor), tools: tools())
        let problem = try #require(seen.notices.first)
        #expect(seen.notices.count == 1 && seen.told.isEmpty)
        #expect(problem.contains("needs swift (Package.swift, .swift-version)") && problem.contains(root) && problem.contains("installs nothing"))
        seen = NodeToolchain.observe(seen.book, roots: [root], now: start.addingTimeInterval(2 * NodeToolchain.noteFor + 600), tools: tools(swift: "6.4.3"))
        #expect(seen.told.isEmpty && seen.notices.isEmpty)

        // Another default than the project names: a problem, unless swiftly has the pinned one installed.
        let later = start.addingTimeInterval(2 * NodeToolchain.noteFor + 1200)
        let other = NodeToolchain.observe(seen.book, roots: [root], now: later, tools: tools(swift: "6.5.0"))
        #expect(other.notices.contains { $0.contains("names swift 6.4") && $0.contains("runs 6.5.0") })
        let pinned = NodeToolchain.observe(seen.book, roots: [root], now: later, tools: tools(swift: "6.5.0", installed: ["6.4.3", "6.5.0"]))
        #expect(pinned.told.isEmpty && pinned.notices.isEmpty, "\(pinned.notices)")
    }

    @Test func theBookIsKeptAcrossRestarts() throws {
        let file = scratch.url("toolchain.json")
        var book = NodeToolchain.Book()
        book.versions["/r"] = ["node": "22.11.0"]
        book.notes["/r"] = .init(text: "Developer tools changed", at: Date(timeIntervalSince1970: 1_800_000_000))
        try book.save(to: file)
        #expect(NodeToolchain.Book.load(from: file) == book)
        #expect(NodeToolchain.Book.load(from: scratch.url("none.json")) == NodeToolchain.Book())
    }
}

/// The engine's look (`ToolchainLook.swift`): a running lead's project's files read, the node's tools asked once (a
/// stand-in), a change told to its lead (held for it) and a problem a `status` notice.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct ToolchainLookTests {
    private let scratch = Scratch()

    final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var swift: String?
        private var count = 0
        init(_ swift: String?) { self.swift = swift }
        var asked: Int { lock.withLock { count } }
        func set(_ swift: String?) { lock.withLock { self.swift = swift } }
        func tools() -> NodeToolchain.Tools { lock.withLock { count += 1; return .init(versions: ["swift": swift, "node": nil]) } }
    }

    @Test func aRunningLeadsProjectIsLookedAtAndAChangeToldToItsLead() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        _ = try await world.sleepingLead()
        try "// swift-tools-version:6.0\n".write(toFile: world.repo + "/Package.swift", atomically: true, encoding: .utf8)
        try #require(await eventually(timeout: 60) { world.queue.sync { world.engine.leadRoots.isEmpty == false } })
        let answers = Answers("6.4.2")
        func look() async {
            let done = Locked(false)
            world.queue.async {
                world.engine.toolchain.tools = { answers.tools() }
                world.engine.lookAtToolchain { done.value = true }
            }
            _ = await eventually(timeout: 60) { done.value }
        }
        await look()
        #expect(answers.asked == 1)
        #expect(world.queue.sync { world.engine.toolchainNotices }.isEmpty)

        answers.set(nil)
        await look()
        let status = try #require(await world.ask("status", action: nil))
        let notices = status.result?["notices"]?.array?.compactMap(\.string) ?? []
        #expect(notices.contains { $0.contains("needs swift (Package.swift)") && $0.contains(world.repo) }, "\(notices)")

        answers.set("6.5.0")
        await look()
        await world.drained()
        #expect(world.queue.sync { world.engine.toolchainNotices }.contains { $0.contains("swift 6.4.2 → 6.5.0") })
        // The sleeping lead runs no agent: the witness's message is held for it.
        let told = await eventually(timeout: 60) { world.held().contains { $0.text.contains("swift 6.4.2 → 6.5.0") && $0.from == .system("witness") } }
        #expect(told, "the change is told to the lead: \(world.held())")
    }
}
