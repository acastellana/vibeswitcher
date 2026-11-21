import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// A session's branch as the node reads it (`NodeGitBranch`, the security review of 2026-11-21): a repository the
/// session wrote can't make the node read much, follow a link or hand a page anything but a branch's name, and the
/// reads are off the engine's queue (`SessionLiveValues`). Each test has a scratch folder.
struct NodeGitBranchTests {
    private let scratch = Scratch()

    private func repo(_ name: String, head: String? = "ref: refs/heads/main\n") throws -> URL {
        let root = scratch.url(name)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        if let head { try Data(head.utf8).write(to: root.appendingPathComponent(".git/HEAD")) }
        return root
    }

    @Test func aBranchADetachedHeadAndAWorktreeReadAsGitSaysThem() throws {
        let main = try repo("main")
        let sub = main.appendingPathComponent("src/deep")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        #expect(NodeGitBranch.current(in: sub.path) == "main")
        #expect(NodeGitBranch.current(in: try repo("detached", head: String(repeating: "ab12", count: 10) + "\n").path) == "ab12ab1")
        #expect(NodeGitBranch.current(in: try repo("slash", head: "ref: refs/heads/agent/login-fix\n").path) == "agent/login-fix")
        // A worktree: its .git file names its git folder, relative or absolute.
        let gitDir = main.appendingPathComponent(".git/worktrees/wt")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try Data("ref: refs/heads/task-a\n".utf8).write(to: gitDir.appendingPathComponent("HEAD"))
        let tree = scratch.url("wt")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data("gitdir: \(gitDir.path)\n".utf8).write(to: tree.appendingPathComponent(".git"))
        #expect(NodeGitBranch.current(in: tree.path) == "task-a")
        #expect(NodeGitBranch.current(in: scratch.url("nowhere-\(UUID().uuidString)").path) == nil)
    }

    /// A HEAD that is a link (to a file starting `ref:`, whose rest a page would see), a `.git` that is a link, a
    /// worktree's HEAD that is a link: no branch, and nothing of the file pointed at.
    @Test func noLinkIsFollowed() throws {
        let secret = scratch.url("secret.txt")
        try Data("ref: refs/heads/hunter2-is-the-password\n".utf8).write(to: secret)
        let linkedHead = try repo("linked-head", head: nil)
        try FileManager.default.createSymbolicLink(at: linkedHead.appendingPathComponent(".git/HEAD"), withDestinationURL: secret)
        #expect(NodeGitBranch.current(in: linkedHead.path) == nil)

        let real = try repo("real")
        let linkedGit = scratch.url("linked-git")
        try FileManager.default.createDirectory(at: linkedGit, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedGit.appendingPathComponent(".git"), withDestinationURL: real.appendingPathComponent(".git"))
        #expect(NodeGitBranch.current(in: linkedGit.path) == nil)

        let gitDir = scratch.url("gitdir")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: gitDir.appendingPathComponent("HEAD"), withDestinationURL: secret)
        let tree = scratch.url("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data("gitdir: \(gitDir.path)\n".utf8).write(to: tree.appendingPathComponent(".git"))
        #expect(NodeGitBranch.current(in: tree.path) == nil)
    }

    /// A huge HEAD (300 MB, sparse) is refused by its size before a byte is read; a FIFO isn't waited on.
    @Test func aHugeHeadOrAFifoIsNeverRead() throws {
        let huge = try repo("huge", head: nil)
        let path = huge.appendingPathComponent(".git/HEAD").path
        #expect(FileManager.default.createFile(atPath: path, contents: Data("ref: refs/heads/main\n".utf8)))
        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.truncate(atOffset: 300 << 20)
        try handle.close()
        #expect(NodeGitBranch.current(in: huge.path) == nil)

        let fifo = try repo("fifo", head: nil)
        #expect(mkfifo(fifo.appendingPathComponent(".git/HEAD").path, 0o600) == 0)
        #expect(NodeGitBranch.current(in: fifo.path) == nil)
    }

    /// Only a ref-shaped value is a branch.
    @Test func onlyARefShapedValueIsABranch() {
        let refused = ["ref: refs/heads/../../etc/passwd", "ref: refs/heads/" + String(repeating: "a", count: 200), "ref: refs/heads/naïve",
                       "ref: heads/main", "ref: refs/heads/a b", "ref: refs/heads/main\nsecond line", "ref: refs/heads//x", "ref: refs/heads/",
                       "not a ref", String(repeating: "g", count: 40), "abc1234", "ref: refs/heads/$(whoami)"]
        for head in refused { #expect(NodeGitBranch.branch(head: head) == nil, "\(head)") }
        #expect(NodeGitBranch.branch(head: "ref: refs/heads/release-1.2_x\n") == "release-1.2_x")
        #expect(NodeGitBranch.branch(head: "ref: refs/remotes/origin/main") == "main")
    }

    /// The branch is read off the engine's queue, and sent once it is.
    @Test func theBranchIsReadOffTheEnginesQueue() async throws {
        let queue = DispatchQueue(label: "engine")
        let key = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: key, value: true)
        let sessions = NodeSessions(root: scratch.url("node-root"), home: scratch.url("home").path, queue: queue)
        let onEngine = Seen()
        let values = SessionLiveValues(queue: queue, sessions: sessions, drafts: Changes(), branch: { _ in
            onEngine.add(DispatchQueue.getSpecific(key: key) == true)
            return "main"
        })
        queue.sync { values.start() }
        let session = Session(tty: "pts/4", agent: .claude, pid: 4242, startedAt: Date(), cwd: "/work/p", project: "p", task: nil,
                              status: .working, statusSince: Date(), detail: nil, hasHooks: true, inTerminalApp: false)
        queue.sync { sessions.changes.send("local:pts/4", session) }
        try #require(await eventually { queue.sync { values.changes.values["local:pts/4"]?["branch"] == NodeWire.Value.string("main") } })
        #expect(!onEngine.all.isEmpty && onEngine.all.allSatisfy { !$0 }, "\(onEngine.all)")
    }

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [Bool] = []
        func add(_ value: Bool) { lock.withLock { seen.append(value) } }
        var all: [Bool] { lock.withLock { seen } }
    }
}
