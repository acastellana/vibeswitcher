import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The re-check of v2-project-new at 59543453 (re-check-v2-s-4): attacks that compile on both 941c507d and 59543453, so
/// each runs red-then-green. Swaps are timed deterministically: the scratch home's global git config includes a FIFO
/// (`include.path`), so every git run of `LeadInit.git` (HOME = the scratch home) blocks opening it until the test's
/// writer opens it; the writer makes its swap then and closes, and git goes on with an empty include. No sleep, no
/// window widened by load: the swap lands exactly while that git runs.
@Suite(.serialized, .timeLimit(.minutes(5)))
struct ProjectNewRecheckTests {
    private let scratch = Scratch()

    struct World {
        var home: String
        var projects: String
        var nodeScratch: URL
        var base: String
        var fifo: String
    }

    /// A scratch world whose global git config names the user, ignores what `ignore` lists (core.excludesFile, empty
    /// at first) and includes the FIFO `fifo`.
    func world() throws -> World {
        let base = scratch.url("pn-recheck")
        let home = base.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let fifo = base.appendingPathComponent("include.fifo").path
        #expect(mkfifo(fifo, 0o600) == 0)
        let ignore = home.appendingPathComponent("ignore").path
        try "".write(toFile: ignore, atomically: true, encoding: .utf8)
        try "[user]\n\tname = The User\n\temail = user@example.invalid\n[core]\n\texcludesFile = \(ignore)\n[include]\n\tpath = \(fifo)\n"
            .write(to: home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        let projects = base.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let nodeScratch = base.appendingPathComponent("node-scratch")
        try FileManager.default.createDirectory(at: nodeScratch, withIntermediateDirectories: true)
        return World(home: home.path, projects: projects.path, nodeScratch: nodeScratch, base: base.path, fifo: fifo)
    }

    /// Serves the FIFO: each time a git opens it, `onOpen(n)` runs (n counts the opens), then the FIFO is closed empty.
    final class FifoServer: @unchecked Sendable {
        let path: String
        let stopped = Locked(false)
        let opens = Locked(0)
        let finished = DispatchSemaphore(value: 0)
        init(_ path: String, onOpen: @escaping @Sendable (Int) -> Void) {
            self.path = path
            let thread = Thread { [self] in
                while true {
                    let fd = open(path, O_WRONLY)
                    if stopped.value { if fd >= 0 { close(fd) }; break }
                    guard fd >= 0 else { continue }
                    opens.mutate { $0 += 1 }
                    onOpen(opens.value)
                    close(fd)
                }
                finished.signal()
            }
            thread.start()
        }
        /// Stops the writer: a reader of our own lets its blocked open return, and it sees `stopped`.
        func stop() {
            stopped.value = true
            let reader = open(path, O_RDONLY | O_NONBLOCK)
            _ = finished.wait(timeout: .now() + 30)
            if reader >= 0 { close(reader) }
        }
    }

    func listing(_ path: String) -> [String] { (FileManager.default.subpaths(atPath: path) ?? []).sorted() }

    // MARK: I1: the location's folder moved out and linked back, timed at the parent's rev-parse

    /// After the descriptor walk opened `real` (Where), while git asks whether the parent is in a repository (the third
    /// git run: `identityKnown`'s two `config --global` runs, before the walk, read the include too), `real` is moved outside the projects
    /// folder and a link to it left in its place. `mkdirat` then makes the project's folder in the moved folder; the plan
    /// resolves to it outside. 941c507d: made there (`.git` outside, the lead's folder outside). 59543453: refused (the
    /// plan's path isn't the folder's), nothing of a repository outside.
    @Test func i1_whereMovedOutAndLinkedAtTheParentsRevParse() throws {
        let world = try world()
        let real = world.projects + "/real"
        let outside = world.base + "/outside"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        let swapped = Locked<String?>(nil)
        // Which `LeadInit.git` run opened the include: each makes its own `stderr-*` in the scratch it is given (the node's
        // for `identityKnown`'s two `config --global` runs and the parent's `rev-parse`; the plan's own runs use a probe
        // folder inside it). The third distinct one is the parent's rev-parse, after the walk, before `mkdirat`.
        let runs = Locked<[String]>([])
        let server = FifoServer(world.fifo) { _ in
            let now = ((try? FileManager.default.contentsOfDirectory(atPath: world.nodeScratch.path)) ?? []).filter { $0.hasPrefix("stderr-") }
            runs.mutate { seen in for name in now where !seen.contains(name) { seen.append(name) } }
            guard swapped.value == nil, runs.value.count == 3, now.contains(runs.value[2]) else { return }
            let moved = rename(real, outside + "/moved-real") == 0
            let linked = symlink(outside + "/moved-real", real) == 0
            swapped.value = "moved \(moved), linked \(linked), project folder there yet: \(LeadInit.kind(outside + "/moved-real/moved") != nil)"
        }
        let result = ProjectMaker.make(name: "moved", location: real, projectsFolder: world.projects, home: world.home, scratch: world.nodeScratch)
        server.stop()
        #expect(swapped.value == "moved true, linked true, project folder there yet: false", "\(swapped.value ?? "no swap")")
        switch result {
        case .success(let made):
            Issue.record("made outside the projects folder, its lead to start there: \(made.folder); outside: \(listing(outside))")
        case .failure(let refused):
            // The refusal the fix added (the plan's path isn't the folder's), not the walk's `link` (a swap too early).
            #expect(refused.message.hasPrefix("The folder the project was made in moved while it was made"), "refused for another reason: \(refused.reason) \(refused.message)")
            #expect(LeadInit.kind(outside + "/moved-real/moved/.git") == nil, "refused (\(refused.message)) but a repository left outside")
        }
    }

    // MARK: N2: the README swapped before a later step fails

    /// While the plan runs git (after the README was made), the README is swapped for another file of that name and the
    /// user's excludes made to ignore README.md, so the plan's files aren't the two made and the make undoes itself.
    /// 941c507d: the swapped-in README is unlinked by name. 59543453: it stays (not the inode made), and so does the folder.
    @Test func n2_aReadmeSwappedInBeforeTheUndoStays() throws {
        let world = try world()
        let folder = world.projects + "/shop"
        let kept = world.base + "/readme-made"
        let swapped = Locked<String?>(nil)
        let server = FifoServer(world.fifo) { _ in
            guard swapped.value == nil, LeadInit.kind(folder + "/README.md") == S_IFREG else { return }
            let moved = rename(folder + "/README.md", kept) == 0
            let planted = FileManager.default.createFile(atPath: folder + "/README.md", contents: Data("planted\n".utf8))
            let ignored = (try? "README.md\n".write(toFile: world.home + "/ignore", atomically: true, encoding: .utf8)) != nil
            swapped.value = "moved \(moved), planted \(planted), ignored \(ignored)"
        }
        let result = ProjectMaker.make(name: "shop", location: nil, projectsFolder: world.projects, home: world.home, scratch: world.nodeScratch)
        server.stop()
        #expect(swapped.value == "moved true, planted true, ignored true", "\(swapped.value ?? "no swap")")
        guard case .failure(let refused) = result else { Issue.record("made: \(result)"); return }
        let planted = try? String(contentsOfFile: folder + "/README.md", encoding: .utf8)
        #expect(planted == "planted\n", "the README put in place of the one made was removed by the undo (\(refused.message)); left: \(listing(world.projects))")
    }

    // MARK: Names: normalisation-equal and case-equal names next to an existing project

    /// The Mac's file system takes names equal under Unicode normalisation (and case) as one: a second project whose name
    /// is the first's in another form refuses as `exists`, never a second folder that looks the same.
    @Test func namesEqualUnderNormalisationOrCaseRefuseAsExisting() throws {
        let world = try world()
        let server = FifoServer(world.fifo) { _ in }
        defer { server.stop() }
        _ = try ProjectMaker.make(name: "Café", location: nil, projectsFolder: world.projects, home: world.home, scratch: world.nodeScratch).get()
        for name in ["Cafe\u{0301}", "CAFÉ", "Cafe\u{0301}".precomposedStringWithCanonicalMapping.uppercased()] {
            let result = ProjectMaker.make(name: name, location: nil, projectsFolder: world.projects, home: world.home, scratch: world.nodeScratch)
            if case .failure(let refused) = result {
                #expect(refused.reason == .exists, "\(name): \(refused)")
            } else {
                Issue.record("\(name): a second project made: \(result)")
            }
        }
        #expect(listing(world.projects).filter { !$0.contains("/") }.count == 1, "\(listing(world.projects).filter { !$0.contains("/") })")
    }

    /// The first review's r03 list (N1), beside an existing `shop`: a variation selector, the combining grapheme joiner,
    /// the Hangul fillers and the braille blank. 941c507d: each made a second folder that looks like `shop`. 59543453:
    /// each refused as `name`.
    @Test func n1_theFirstReviewsInvisibleLookAlikesRefuse() throws {
        let world = try world()
        let server = FifoServer(world.fifo) { _ in }
        defer { server.stop() }
        _ = try ProjectMaker.make(name: "shop", location: nil, projectsFolder: world.projects, home: world.home, scratch: world.nodeScratch).get()
        var madeBeside: [String] = []
        for scalar: UInt32 in [0xFE0F, 0x034F, 0x3164, 0x2800, 0x115F] {
            let name = "shop" + String(Unicode.Scalar(scalar)!)
            let result = ProjectMaker.make(name: name, location: nil, projectsFolder: world.projects, home: world.home, scratch: world.nodeScratch)
            if case .failure(let refused) = result, refused.reason == .name { continue }
            madeBeside.append(String(format: "U+%04X", scalar))
        }
        #expect(madeBeside.isEmpty, "not refused as name beside shop: \(madeBeside)")
    }

}

/// The re-check's attacks that still find a way through on 59543453 (red by design: each failure is a finding's
/// evidence). They compile on 941c507d too.
@Suite(.serialized, .timeLimit(.minutes(5)))
struct ProjectNewRecheckOpenTests {
    private let base = ProjectNewRecheckTests()
    func world() throws -> ProjectNewRecheckTests.World { try base.world() }
    typealias FifoServer = ProjectNewRecheckTests.FifoServer

    /// Characters beyond the fix's list that draw as nothing (or a blank) in common fonts, beside an existing `shop`:
    /// which still make a second folder that looks like it (a residual of N1, the user's own eyes only).
    @Test func n1_residualBlankDrawingCharactersBesideAnExistingProject() throws {
        let world = try world()
        let server = FifoServer(world.fifo) { _ in }
        defer { server.stop() }
        _ = try ProjectMaker.make(name: "shop", location: nil, projectsFolder: world.projects, home: world.home, scratch: world.nodeScratch).get()
        var madeBeside: [String] = []
        for scalar: UInt32 in [0xFFA0, 0x180B, 0x17B4, 0xE0100, 0x2062, 0x00AD, 0x1D159, 0x16FE4, 0x2003, 0x3000] {
            guard let character = Unicode.Scalar(scalar) else { continue }
            let name = "shop" + String(character)
            if case .success = ProjectMaker.make(name: name, location: nil, projectsFolder: world.projects, home: world.home, scratch: world.nodeScratch) {
                madeBeside.append(String(format: "U+%04X", scalar))
            }
        }
        #expect(madeBeside.isEmpty, "made beside shop: \(madeBeside)")
    }
    // MARK: A hidden folder reached through a link in the projects folder's own path

    /// The fix refuses a projects folder whose path, as set, holds a hidden component; set instead to a path whose last
    /// component is a link to a hidden folder (`~/projects-link -> ~/.claude/commands`, both the user's own or a page's
    /// setting), the hidden check reads the path as set, never as it resolves: the project and its repository are made
    /// in the hidden folder. Where, typed by the resolved path, gets in the same way.
    @Test func hiddenFolderReachedThroughALinkInTheProjectsFolderPath() throws {
        let world = try world()
        let server = FifoServer(world.fifo) { _ in }
        defer { server.stop() }
        let hidden = world.home + "/.claude/commands"
        try FileManager.default.createDirectory(atPath: hidden + "/sub", withIntermediateDirectories: true)
        #expect(symlink(hidden, world.home + "/projects-link") == 0)
        var madeIn: [String] = []
        for (name, location) in [("deploy now", nil as String?), ("ship it", hidden + "/sub")] {
            if case .success(let made) = ProjectMaker.make(name: name, location: location, projectsFolder: "~/projects-link", home: world.home, scratch: world.nodeScratch) {
                madeIn.append(made.folder)
            }
        }
        #expect(madeIn.isEmpty, "made in a hidden folder: \(madeIn)")
    }
}
