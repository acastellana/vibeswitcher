import Foundation
import Testing
@testable import VibeCore

/// A look at the agents' config (`ConfigSeal.hashes`) costs what its bounds allow, whatever a session puts in a watched
/// thing: a file past the read bound, or past its folder's byte budget, is told by its size, times and inode, never
/// read whole and never left out; and the vault hashes one look at a time, so looks that wait on a slow one share the
/// next instead of piling up. Every file here is sparse (no disk is written for its size), in a Scratch home.
struct ConfigSealBoundsTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    var home: String { book.configHome }

    func repo() throws -> String {
        let url = temp.url("lead")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        try FileManager.default.createDirectory(atPath: root + "/.vibeswitcher", withIntermediateDirectories: true)
        try "---\nmax_workers: 3\n---\n".write(toFile: root + "/.vibeswitcher/workflow.md", atomically: true, encoding: .utf8)
        return root
    }

    func write(_ text: String, _ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// `path`, made (or grown) sparse to `size` bytes: its size is told, no disk is written for it.
    func sparse(_ path: String, size: Int) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) { #expect(FileManager.default.createFile(atPath: path, contents: nil)) }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
    }

    /// One byte written at the start of `path`, its size kept: a rewrite in place.
    func poke(_ path: String, _ byte: String = "x") throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(byte.utf8))
        try handle.close()
    }

    /// The bytes a look at the home's watched things reads.
    func bytesRead() -> Int {
        let count = ConfigSeal.ReadCount()
        _ = ConfigSeal.$readCount.withValue(count) { ConfigSeal.hashes(of: ConfigSeal.homeWatched(home: home)) }
        return count.bytes
    }

    static let megabyte = 1 << 20

    /// The symptom: sparse files in a watched folder (and a watched file) the seal read whole, so a look's work grew
    /// with their size. Now a look reads the same, small, however big they grow.
    @Test func aLooksReadsDontGrowWithTheSizeOfWhatsWatched() throws {
        try write("# skill\n", home + "/.claude/skills/one/SKILL.md")
        let small = bytesRead()
        #expect(small < Self.megabyte)
        let files = [home + "/.claude/skills/one/a.bin", home + "/.claude/skills/one/b.bin", home + "/.claude/CLAUDE.md"]
        for file in files { try sparse(file, size: 96 * Self.megabyte) }
        let once = bytesRead()
        for file in files { try sparse(file, size: 192 * Self.megabyte) }
        let twice = bytesRead()
        #expect(once == twice, "a look read \(once) bytes, then \(twice) once the files doubled")
        #expect(twice < 8 * Self.megabyte, "a look read \(twice) bytes")
    }

    /// Many files each under the read bound, past the folder's budget together: the folder reads at most its budget.
    @Test func aFolderReadsAtMostItsBudget() throws {
        for index in 0..<6 { try sparse(home + "/.claude/commands/c\(index).md", size: 24 * Self.megabyte) }
        let read = bytesRead()
        #expect(read <= 64 * Self.megabyte, "a look read \(read) bytes of a 144 MB folder")
    }

    /// Past a bound is held as changed the first time it's seen that way, even in instructions a quiet look seals as
    /// yours: once accepted, it's told by its size, times and inode, so a rewrite in place is a change too.
    @Test func pastTheBoundIsHeldTheFirstTimeAndARewriteIsAChange() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        _ = try lead(root, runtime)
        let asLead = vault(for: runtime)
        try write("# reviewer\n", home + "/.claude/agents/reviewer.md")
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
        // Quiet, an edit to instructions is the user's: sealed as it is.
        try write("# reviewer, edited\n", home + "/.claude/agents/reviewer.md")
        #expect(try asLead.checkConfig(root: root).resealed == ["~/.claude/agents"])

        let big = home + "/.claude/agents/huge.md"
        try sparse(big, size: 96 * Self.megabyte)
        #expect(try asLead.checkConfig(root: root).held == ["~/.claude/agents"])
        #expect(try asLead.checkConfig(root: root).held == ["~/.claude/agents"])
        #expect(try vault.checkConfig(root: root).resealed == ["~/.claude/agents"])
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
        // Accepted past the bound, a quiet rewrite of it is the user's like any edit of instructions; and it is seen.
        try poke(big)
        #expect(try asLead.checkConfig(root: root).resealed == ["~/.claude/agents"])

        // In what executes, a rewrite in place of a file past the bound (its size kept) is held.
        let binary = home + "/.claude/skills/tool/tool.bin"
        try sparse(binary, size: 96 * Self.megabyte)
        #expect(try asLead.checkConfig(root: root).held == ["~/.claude/skills"])
        #expect(try vault.checkConfig(root: root).resealed == ["~/.claude/skills"])
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
        try poke(binary)
        #expect(try asLead.checkConfig(root: root).held == ["~/.claude/skills"])
    }

    /// A seal made before the bounds, with a watched file already past them (hashed then by its contents): one card,
    /// once, then nothing.
    @Test func aFilePastTheBoundBeforeTheBoundsIsOneCardOnce() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        _ = try lead(root, runtime)
        try sparse(home + "/.claude/agents/huge.md", size: 96 * Self.megabyte)
        #expect(try vault(for: runtime).checkConfig(root: root) == LeadVault.ConfigCheck())

        // The vault as a version that read it whole left it: another hash for the folder, no note of what's past a bound.
        var saved = try #require(try JSONSerialization.jsonObject(with: book.serialized) as? [String: Any])
        var config = try #require(saved["config"] as? [String: Any])
        var hashes = try #require(config["hashes"] as? [String: String])
        let key = ConfigSeal.keyPrefix + "~/.claude/agents"
        #expect(hashes[key] != nil)
        hashes[key] = String(repeating: "0", count: 64)
        config["hashes"] = hashes.filter { !$0.key.hasPrefix(ConfigSeal.keyPrefix + "#past ") }
        saved["config"] = config
        let older = LeadVault.Book(restoring: try JSONSerialization.data(withJSONObject: saved))
        older.configHome = home
        older.wallFolder = vault.folder
        nonisolated(unsafe) let shared = runtime
        let asLead = older.vault(folder: vault.folder, as: { shared.currentAgent()?.session.map { .session($0) } ?? .unknown })
        let app = older.vault(folder: vault.folder, as: { .app })
        #expect(try asLead.checkConfig(root: root).held == ["~/.claude/agents"])
        #expect(try asLead.checkConfig(root: root).held == ["~/.claude/agents"])
        #expect(try app.checkConfig(root: root).resealed == ["~/.claude/agents"])
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
    }

    /// What the injected hashing saw: how many hashed at once, at most, and how many hashed in all.
    final class Overlap: @unchecked Sendable {
        private let lock = NSLock()
        private var now = 0, most = 0, all = 0
        /// The call's number: 1 for the first.
        @discardableResult
        func enter() -> Int { lock.lock(); defer { lock.unlock() }; now += 1; all += 1; most = max(most, now); return all }
        func leave() { lock.lock(); now -= 1; lock.unlock() }
        var active: Int { lock.lock(); defer { lock.unlock() }; return now }
        var peak: Int { lock.lock(); defer { lock.unlock() }; return most }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return all }
    }

    /// Three looks while the first one's hashing is slow (a watched folder that takes long to read): never two hash
    /// at once, and the two that waited share one look made after they asked, instead of one each.
    @Test func looksHashOneAtATimeAndTheWaitingShareTheNext() async throws {
        let book = LeadVault.Book()
        book.configHome = home
        let root = temp.url("root").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let overlap = Overlap()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        book.hashLook = { home, _ in
            let call = overlap.enter()
            defer { overlap.leave() }
            if call == 1 {
                entered.signal()
                _ = release.wait(timeout: .now() + hangGuard)
            }
            return ConfigSeal.hashes(of: ConfigSeal.homeWatched(home: home))
        }
        let look = { @Sendable () -> LeadVault.Reply in
            book.answer(.setGuarded(root: root, hashes: [ConfigSeal.checkKey: "1"]), from: .app)
        }
        let done = DispatchSemaphore(value: 0)
        Thread { _ = look(); done.signal() }.start()
        #expect(await offPool { entered.wait(timeout: .now() + hangGuard) } == .success)
        for _ in 0..<2 { Thread { _ = look(); done.signal() }.start() }
        // The two later looks either hash beside the first or wait for it: either way, it's let go then.
        #expect(await eventually { overlap.active == 3 || book.looksWaiting == 2 })
        release.signal()
        for _ in 0..<3 { #expect(await offPool { done.wait(timeout: .now() + hangGuard) } == .success) }
        #expect(overlap.peak == 1, "\(overlap.peak) looks hashed at once")
        #expect(overlap.calls == 2, "\(overlap.calls) looks hashed for three asked")
    }
}
