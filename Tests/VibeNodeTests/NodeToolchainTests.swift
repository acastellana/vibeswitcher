import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The developer tools notice on a node (`NodeToolchain`): what a project's files say its gate needs, each tool asked its
/// version in the project's folder (a stand-in here: nothing runs), a missing or other-than-named tool a standing notice,
/// a change told to the lead once and noted for a day.
struct NodeToolchainTests {
    private let scratch = Scratch()

    private func project(_ name: String, files: [String: String]) throws -> String {
        let root = scratch.url(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (file, text) in files { try text.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8) }
        return root.path
    }

    /// Tools by name: what `--version` says (nil: it doesn't run); records each ask.
    final class FakeTools: @unchecked Sendable {
        let lock = NSLock()
        var said: [String: String] = [:]
        var asked: [(tool: String, folder: String)] = []
        var run: (String, [String], String) -> String? {
            { [self] tool, args, folder in
                lock.withLock {
                    asked.append((tool, folder))
                    return args == ["--version"] ? said[tool] : nil
                }
            }
        }
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

    @Test func aVersionIsReadAndMatchedAsTheProjectNamesIt() {
        #expect(NodeToolchain.version(tool: "swift", output: "Swift version 6.4.2 (swift-6.4.2-RELEASE)\nTarget: x86_64-unknown-linux-gnu") == "6.4.2")
        #expect(NodeToolchain.version(tool: "node", output: "v22.11.0") == "22.11.0")
        #expect(NodeToolchain.version(tool: "swift", output: "error: toolchain 6.9 isn't installed") == nil)
        #expect(NodeToolchain.matches("6.4.2", wanted: "6.4"))
        #expect(NodeToolchain.matches("22.11.0", wanted: "v22"))
        #expect(!NodeToolchain.matches("6.4.2", wanted: "6.5"))
        #expect(!NodeToolchain.matches("6.4", wanted: "6.4.2"))
        // A name that isn't numbers isn't judged.
        #expect(NodeToolchain.matches("22.11.0", wanted: "lts/*"))
        #expect(NodeToolchain.matches("6.4.2", wanted: "main-snapshot"))
    }

    /// The first look keeps what it found and tells nothing; a change is told to that project's lead once and noted for a
    /// day; a tool that stops running is a problem while it stands, and its return (to the same version) isn't a change.
    @Test func aChangeIsToldOnceAndAProblemStandsWhileItLasts() throws {
        let root = try project("app", files: ["Package.swift": "", ".swift-version": "6.4\n"])
        let tools = FakeTools()
        tools.said = ["swift": "Swift version 6.4.2 (swift-6.4.2-RELEASE)"]
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var seen = NodeToolchain.observe(.init(), roots: [root], now: start, run: tools.run)
        #expect(seen.told.isEmpty && seen.notices.isEmpty)
        #expect(seen.book.versions[root] == ["swift": "6.4.2"])
        #expect(tools.asked.map(\.folder) == [root])

        tools.said["swift"] = "Swift version 6.4.3 (swift-6.4.3-RELEASE)"
        seen = NodeToolchain.observe(seen.book, roots: [root], now: start.addingTimeInterval(600), run: tools.run)
        let told = try #require(seen.told[root])
        #expect(told.contains("swift 6.4.2 → 6.4.3") && told.contains("never changes them"))
        #expect(seen.notices == [told])
        // Told once; noted until a day has passed.
        seen = NodeToolchain.observe(seen.book, roots: [root], now: start.addingTimeInterval(1200), run: tools.run)
        #expect(seen.told.isEmpty && seen.notices == [told])
        seen = NodeToolchain.observe(seen.book, roots: [root], now: start.addingTimeInterval(600 + NodeToolchain.noteFor), run: tools.run)
        #expect(seen.notices.isEmpty)

        // Gone (swiftly can't find the pinned toolchain): a problem naming the tool, the files and the folder.
        tools.said["swift"] = nil
        seen = NodeToolchain.observe(seen.book, roots: [root], now: start.addingTimeInterval(2 * NodeToolchain.noteFor), run: tools.run)
        let problem = try #require(seen.notices.first)
        #expect(seen.notices.count == 1 && seen.told.isEmpty)
        #expect(problem.contains("needs swift (Package.swift, .swift-version)") && problem.contains(root) && problem.contains("installs nothing"))
        // Back as it was: no change told, no problem.
        tools.said["swift"] = "Swift version 6.4.3"
        seen = NodeToolchain.observe(seen.book, roots: [root], now: start.addingTimeInterval(2 * NodeToolchain.noteFor + 600), run: tools.run)
        #expect(seen.told.isEmpty && seen.notices.isEmpty)

        // Another version than the project names: a problem while it stands (and the change, told).
        tools.said["swift"] = "Swift version 6.5.0"
        seen = NodeToolchain.observe(seen.book, roots: [root], now: start.addingTimeInterval(2 * NodeToolchain.noteFor + 1200), run: tools.run)
        #expect(seen.told[root]?.contains("swift 6.4.3 → 6.5.0") == true)
        #expect(seen.notices.contains { $0.contains("names swift 6.4") && $0.contains("runs 6.5.0") })
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

/// The engine's look (`ToolchainLook.swift`): a running lead's project's tools asked in its folder, a change told to its
/// lead (held for it, or in its inbox) and a problem a `status` notice.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct ToolchainLookTests {
    private let scratch = Scratch()

    @Test func aRunningLeadsProjectIsLookedAtAndAChangeToldToItsLead() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        _ = try await world.sleepingLead()
        try "// swift-tools-version:6.0\n".write(toFile: world.repo + "/Package.swift", atomically: true, encoding: .utf8)
        try #require(await eventually(timeout: 60) { world.queue.sync { world.engine.leadRoots.isEmpty == false } })
        let tools = NodeToolchainTests.FakeTools()
        tools.said = ["swift": "Swift version 6.4.2"]
        func look() async {
            let done = Locked(false)
            world.queue.async {
                world.engine.toolchainRun = tools.run
                world.engine.lookAtToolchain { done.value = true }
            }
            _ = await eventually(timeout: 60) { done.value }
        }
        await look()
        #expect(tools.asked.map(\.folder) == [world.repo])
        #expect(world.queue.sync { world.engine.toolchainNotices }.isEmpty)

        tools.lock.withLock { tools.said["swift"] = nil }
        await look()
        let status = try #require(await world.ask("status", action: nil))
        let notices = status.result?["notices"]?.array?.compactMap(\.string) ?? []
        #expect(notices.contains { $0.contains("needs swift (Package.swift)") && $0.contains(world.repo) }, "\(notices)")

        tools.lock.withLock { tools.said["swift"] = "Swift version 6.5.0" }
        await look()
        await world.drained()
        #expect(world.queue.sync { world.engine.toolchainNotices }.contains { $0.contains("swift 6.4.2 → 6.5.0") })
        // The sleeping lead runs no agent: the witness's message is held for it.
        let told = await eventually(timeout: 60) { world.held().contains { $0.text.contains("swift 6.4.2 → 6.5.0") && $0.from == .system("witness") } }
        #expect(told, "the change is told to the lead: \(world.held())")
    }
}
