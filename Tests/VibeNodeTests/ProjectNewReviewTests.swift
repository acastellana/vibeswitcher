import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The independent security review of `project.new` (review-v2-s-new, 2026-11-26): attacks on `ProjectMaker.make` in a
/// scratch home and scratch projects folder. Each test states what it attacks; an `#expect` that fails is a finding.
/// Untracked: lives only in the reviewer's copy.
@Suite(.serialized, .timeLimit(.minutes(10)))
struct ProjectNewReviewTests {
    private let scratch = Scratch()

    private struct World {
        var home: String
        var projects: String
        var nodeScratch: URL
        var base: String
    }

    private func world(identity: Bool = true, made: Bool = true, extraConfig: String = "") throws -> World {
        let base = scratch.url("pn-review")
        let home = base.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if identity || !extraConfig.isEmpty {
            let who = identity ? "[user]\n\tname = The User\n\temail = user@example.invalid\n" : ""
            try (who + extraConfig).write(to: home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        }
        let projects = base.appendingPathComponent("projects")
        if made { try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true) }
        let nodeScratch = base.appendingPathComponent("node-scratch")
        try FileManager.default.createDirectory(at: nodeScratch, withIntermediateDirectories: true)
        return World(home: home.path, projects: projects.path, nodeScratch: nodeScratch, base: base.path)
    }

    private func make(_ world: World, _ name: String, in location: String? = nil, projectsFolder: String? = nil) -> Result<ProjectMaker.Made, ProjectMaker.Refusal> {
        ProjectMaker.make(name: name, location: location, projectsFolder: projectsFolder ?? world.projects, home: world.home, scratch: world.nodeScratch)
    }

    /// Every path under `path`, links not followed (FileManager.subpaths doesn't follow them).
    private func listing(_ path: String) -> [String] { (FileManager.default.subpaths(atPath: path) ?? []).sorted() }

    private func refusal(_ made: Result<ProjectMaker.Made, ProjectMaker.Refusal>) -> ProjectMaker.Refusal? {
        if case .failure(let refusal) = made { return refusal }
        return nil
    }

    private func git(_ args: [String], in folder: String, _ world: World) -> LeadInit.Ran {
        LeadInit.git(args, in: folder, home: world.home, scratch: world.nodeScratch)
    }

    // MARK: Names

    /// Names with shell metacharacters, leading dashes, dots, reserved words and look-alikes: each is refused, or made as
    /// one folder directly in the projects folder, its README exactly "# name\n", nothing run (no file the name would
    /// make were it ever run by a shell), nothing outside.
    @Test func r01_namesNeverEscapeOrRun() throws {
        let world = try world()
        let outside = world.base + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        let names = ["$(touch pwned1)", "`touch pwned2`", "x;touch pwned3", "x' ; touch pwned4 ; '", "\"$(touch pwned5)\"", "-rf", "--help", "a..b", "HEAD",
                     "CON", "objects", "\u{2215}etc", "ｓｈｏｐ", "ѕhop", "shop", "Shop", "café", "cafe\u{301}", "~root", "a\\b", "*", "a*b?",
                     "name\u{00A0}nbsp", "x\u{3000}y"]
        var outcomes: [String] = []
        for name in names {
            switch make(world, name) {
            case .success(let made):
                let parent = (made.folder as NSString).deletingLastPathComponent
                #expect(parent == LeadInit.resolved(world.projects), "\(name.debugDescription): made at \(made.folder)")
                let readme = try? String(contentsOfFile: made.folder + "/README.md", encoding: .utf8)
                #expect(readme == "# \(name.trimmingCharacters(in: .whitespacesAndNewlines))\n", "\(name.debugDescription): \(String(describing: readme))")
                outcomes.append("\(name.debugDescription) → made \((made.folder as NSString).lastPathComponent)")
            case .failure(let refused):
                outcomes.append("\(name.debugDescription) → \(refused.reason.rawValue): \(refused.message)")
            }
        }
        for planted in ["pwned1", "pwned2", "pwned3", "pwned4", "pwned5"] {
            let anywhere = listing(world.base).filter { ($0 as NSString).lastPathComponent == planted }
            #expect(anywhere.isEmpty, "\(planted): \(anywhere)")
        }
        #expect(listing(outside).isEmpty)
        print("R01 outcomes:\n" + outcomes.joined(separator: "\n"))
    }

    /// Dots, separators, NUL, controls and lengths: refused as `name`, nothing made.
    @Test func r02_badNamesRefused() throws {
        let world = try world()
        let long = String(repeating: "é", count: 100)  // 100 characters, 200 bytes: taken
        let wide = "a" + String(repeating: "\u{301}", count: 300)  // one character, 601 bytes: too long for a folder
        for name in [".", "..", "...", ".git", "../x", "x/../../y", "a\u{0}b", "a\u{85}b", "a\u{2028}b", "a\u{200D}b", "a\u{FEFF}b", wide,
                     String(repeating: "x", count: 101), "   ", ""] {
            let refused = refusal(make(world, name))
            #expect(refused?.reason == .name, "\(name.debugDescription): \(String(describing: refused))")
        }
        #expect(listing(world.projects).isEmpty, "\(listing(world.projects))")
        #expect((try? make(world, long).get()) != nil, "100 two-byte characters are a name")
    }

    /// Invisible characters the worker's rule doesn't name (not control or format: nonspacing marks, Hangul fillers, a
    /// braille blank): a name that looks like an existing project's is made beside it. Recorded, not asserted: a spoof
    /// of the user's own eyes, inside the projects folder.
    @Test func r03_invisibleLookAlikesBesideAnExistingProject() throws {
        let world = try world()
        _ = try make(world, "shop").get()
        var said: [String] = []
        for name in ["shop\u{FE0F}", "shop\u{034F}", "shop\u{3164}", "shop\u{2800}", "shop\u{115F}"] {
            switch make(world, name) {
            case .success(let made): said.append("\(name.unicodeScalars.map { String(format: "U+%04X", $0.value) }.suffix(1)) made \(made.folder)")
            case .failure(let refused): said.append("\(name.debugDescription) refused \(refused.reason)")
            }
        }
        print("R03 look-alikes:\n" + said.joined(separator: "\n"))
        #expect(said.allSatisfy { $0.contains("refused") }, "an invisible character made a look-alike of an existing project: \(said)")
    }

    // MARK: Where

    /// `..`, relative paths, a tilde escape, NUL and controls, the projects folder's sibling and parent: refused as
    /// `outside`, nothing made anywhere.
    @Test func r04_locationsOutsideRefused() throws {
        let world = try world()
        try FileManager.default.createDirectory(atPath: world.projects + "/sub", withIntermediateDirectories: true)
        let tildeOut = "~/../" + (world.base as NSString).lastPathComponent
        for location in ["~/..", tildeOut, "../projects", "./projects", world.projects + "/sub/..", world.projects + "/sub/../../x",
                         world.projects + "/sub\u{0}/../../x", world.projects + "/su\u{85}b", world.projects + "/sub\u{202E}", world.projects + "\u{0}/sub",
                         "~", world.home, world.projects.uppercased()] {
            let refused = refusal(make(world, "Shop", in: location))
            #expect(refused?.reason == .outside, "\(location.debugDescription): \(String(describing: refused))")
        }
        #expect(listing(world.base).filter { $0.hasSuffix("shop") }.isEmpty, "\(listing(world.base))")
    }

    /// A place inside a repository's .git folder, a bare repository (and a folder in one), a folder whose .git file
    /// points nowhere, a submodule-like nested repository: refused as `repository`, and nothing written into any of them.
    @Test func r05_locationsInRepositoriesRefused() throws {
        let world = try world()
        let repo = world.projects + "/repo"
        #expect(git(["init", "--quiet", repo], in: world.base, world).ok)
        let bare = world.projects + "/bare.git"
        #expect(git(["init", "--quiet", "--bare", bare], in: world.base, world).ok)
        let pointer = world.projects + "/pointer"
        try FileManager.default.createDirectory(atPath: pointer, withIntermediateDirectories: true)
        try "gitdir: /nonexistent/elsewhere\n".write(toFile: pointer + "/.git", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: repo + "/deep/er", withIntermediateDirectories: true)
        let before = listing(world.projects)
        for location in [repo, repo + "/deep/er", repo + "/.git", repo + "/.git/refs", bare, bare + "/refs", bare + "/objects", pointer] {
            let refused = refusal(make(world, "Shop", in: location))
            #expect(refused?.reason == .repository || refused?.reason == .failed, "\(location): \(String(describing: refused))")
            #expect(refused != nil, "\(location) made")
        }
        #expect(listing(world.projects) == before, "\(Set(listing(world.projects)).subtracting(before))")
    }

    /// The projects folder set to `/` (and spellings of it, and a link to it), to the home folder, inside a repository
    /// (and missing there: the levels made are taken back).
    @Test func r06_projectsFolderEdges() throws {
        let world = try world()
        try FileManager.default.createSymbolicLink(atPath: world.base + "/root-link", withDestinationPath: "/")
        for root in ["/", "//", "/.", "/usr/..", world.base + "/root-link"] {
            let refused = refusal(make(world, "Shop", projectsFolder: root))
            #expect(refused != nil && LeadInit.kind("/shop") == nil, "\(root): \(String(describing: refused))")
            print("R06 root \(root): \(String(describing: refused))")
        }
        let repo = world.base + "/repo"
        #expect(git(["init", "--quiet", repo], in: world.base, world).ok)
        let inside = repo + "/a/b/c"
        let refused = refusal(make(world, "Shop", projectsFolder: inside))
        #expect(refused?.reason == .repository, "\(String(describing: refused))")
        #expect(LeadInit.kind(repo + "/a") == nil, "the levels made inside the repository are taken back: \(listing(repo))")
        let relative = refusal(make(world, "Shop", projectsFolder: "dev"))
        #expect(relative?.reason == .failed, "\(String(describing: relative))")
    }

    // MARK: Undo

    /// A step after the README fails (the user's own global ignore leaves README.md out, an init.defaultBranch git won't
    /// take): the folder and the projects folder's new levels are taken back; nothing else.
    @Test func r07_undoAfterTheReadmeLeavesNothing() throws {
        for config in ["[core]\n\texcludesFile = EXCLUDES\n", "[init]\n\tdefaultBranch = a..b\n"] {
            let world = try world(made: false)
            let excludes = world.base + "/excludes"
            try "README.md\n".write(toFile: excludes, atomically: true, encoding: .utf8)
            try ("[user]\n\tname = The User\n\temail = user@example.invalid\n" + config.replacingOccurrences(of: "EXCLUDES", with: excludes))
                .write(toFile: world.home + "/.gitconfig", atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(atPath: world.base + "/keep", withIntermediateDirectories: true)
            let nested = world.projects + "/x/y"
            let refused = refusal(make(world, "Shop", projectsFolder: nested))
            #expect(refused?.reason == .failed, "\(config): \(String(describing: refused))")
            #expect(LeadInit.kind(world.projects) == nil, "\(config): the projects folder's new levels are taken back: \(listing(world.base))")
            #expect(LeadInit.kind(world.base + "/keep") == S_IFDIR && LeadInit.kind(world.home + "/.gitconfig") == S_IFREG)
            print("R07 \(config.split(separator: "\n").first ?? ""): \(String(describing: refused))")
        }
    }

    /// Anything by the folder's name there, in every shape, under a projects folder that existed: refused, the thing
    /// left byte for byte, and the projects folder not removed (it wasn't made).
    @Test func r08_anExistingThingIsNeverTouched() throws {
        let world = try world()
        try "keep\n".write(toFile: world.projects + "/keep.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: world.projects + "/empty", withIntermediateDirectories: true)
        let refused = refusal(make(world, "Empty"))
        #expect(refused?.reason == .exists)
        #expect(LeadInit.kind(world.projects + "/empty") == S_IFDIR, "an empty folder by its name stays")
        #expect(listing(world.projects) == ["empty", "keep.txt"])
    }

    // MARK: The race the worker named first

    /// The location's folder is swapped for a link to an attacker's folder (which holds a folder by the project's
    /// name) and back, over and over, while `make` runs: whatever the interleaving, nothing is ever written into the
    /// attacker's folder, and a project made is in the real folder. Stochastic by nature: it asserts the invariant on
    /// every run and prints which refusals the interleavings hit. The racer stops when `make` returns.
    @Test func r09_aFolderSwappedForALinkWhileItWorks() throws {
        let world = try world()
        let real = world.projects + "/real"
        let away = world.projects + "/real-away"
        let attacker = world.base + "/attacker"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: attacker, withIntermediateDirectories: true)
        var counts: [String: Int] = [:]
        let runs = 40
        for run in 0..<runs {
            let name = "p\(run)"
            try FileManager.default.createDirectory(atPath: attacker + "/" + name, withIntermediateDirectories: true)
            try "theirs\n".write(toFile: attacker + "/" + name + "/theirs.txt", atomically: true, encoding: .utf8)
            let stop = Locked(false)
            let stopped = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                var flips = 0
                while !stop.value {
                    rename(real, away)
                    symlink(attacker, real)
                    usleep(UInt32(50 + (flips % 7) * 40))
                    unlink(real)
                    rename(away, real)
                    usleep(UInt32(50 + (flips % 5) * 30))
                    flips += 1
                }
                stopped.signal()
            }
            let result = make(world, name, in: real)
            stop.value = true
            stopped.wait()
            // Settled: the real folder back in its place.
            if LeadInit.kind(real) == S_IFLNK { unlink(real) }
            if LeadInit.kind(away) == S_IFDIR { rename(away, real) }
            #expect(listing(attacker + "/" + name) == ["theirs.txt"], "run \(run): the attacker's folder was written: \(listing(attacker + "/" + name))")
            switch result {
            case .success(let made):
                #expect(made.folder.hasPrefix(LeadInit.resolved(world.projects) + "/"), "run \(run): made at \(made.folder)")
                #expect(LeadInit.kind(real + "/" + name + "/.git") == S_IFDIR, "run \(run): made, but not in the real folder: \(listing(real))")
                counts["made", default: 0] += 1
            case .failure(let refused):
                counts[refused.reason.rawValue + (refused.message.contains("stays") ? "+stays" : ""), default: 0] += 1
                // Nothing of the project's left in the real folder.
                let left = listing(real + "/" + name)
                #expect(left.isEmpty, "run \(run): refused (\(refused.message)), but left: \(left)")
            }
        }
        #expect(listing(attacker).filter { !$0.hasSuffix("theirs.txt") && $0.split(separator: "/").count > 1 }.isEmpty, "\(listing(attacker))")
        print("R09 outcomes over \(runs) runs: \(counts.sorted { $0.key < $1.key })")
    }

    /// The race the worker named, in its sharpest form: once the walk has opened the location's folder, that same folder
    /// is moved out of the projects folder and a link to it left in its place. The descriptor still names the folder;
    /// `LeadInit.plan` takes the path, follows the link, and finds the same inode. Triggered by the event itself (the
    /// project's folder appearing in the watched folder), the window widened by a full node scratch (`tidy` lists it
    /// first). Safe: refused, or made in the projects folder. Red: the project (and so its lead) is outside it.
    @Test func r12_theSameFolderMovedOutAndReachedThroughALink() throws {
        let world = try world()
        let real = world.projects + "/real"
        let outside = world.base + "/outside"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        for number in 0..<20_000 { mkdir(world.nodeScratch.path + "/lead-init-fill-\(number)", 0o700) }
        let name = "moved"
        let watched = open(real, O_EVTONLY)
        #expect(watched >= 0)
        let swapped = Locked<String?>(nil)
        let queue = DispatchQueue(label: "r12")
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: watched, eventMask: .write, queue: queue)
        source.setEventHandler {
            guard swapped.value == nil, LeadInit.kind(real + "/" + name) == S_IFDIR else { return }
            let moved = rename(real, outside + "/moved-real") == 0
            let linked = symlink(outside + "/moved-real", real) == 0
            swapped.value = "moved \(moved), linked \(linked)"
            source.cancel()
        }
        source.setCancelHandler { close(watched) }
        source.resume()
        let result = make(world, name, in: real)
        source.cancel()
        let atSwap = queue.sync { swapped.value }
        print("R12 swap: \(atSwap ?? "none"); result: \(result)")
        print("R12 outside: \(listing(outside).filter { $0.split(separator: "/").count <= 3 })")
        switch result {
        case .success(let made):
            #expect(made.folder.hasPrefix(LeadInit.resolved(world.projects) + "/"), "made outside the projects folder, its lead to start there: \(made.folder)")
        case .failure(let refused):
            #expect(LeadInit.kind(outside + "/moved-real/" + name) == nil, "refused (\(refused.message)) but left outside: \(listing(outside))")
        }
    }

    // MARK: projects_folder, page-settable

    /// What an acting page gains: `set projects_folder` (a page's: `.sets`) to any folder the user can write, then
    /// `project.new`: a folder with README.md and .gitignore and a repository there, no claude in the loop. Here, the
    /// agents' own settings folder (~/.claude/commands, where Claude Code takes every .md as a command).
    @Test func r10_aPageMovesTheRootIntoTheAgentsSettings() throws {
        let setting = try #require(NodeSettings.all.first { $0.key == "projects_folder" })
        #expect(setting.page == .sets, "projects_folder is a page's to set")
        let world = try world()
        let commands = world.home + "/.claude/commands"
        let made = make(world, "Deploy now", projectsFolder: commands)
        print("R10 ~/.claude/commands: \(String(describing: refusal(made))) listing \(listing(commands))")
        #expect(refusal(made) != nil, "made in the agents' settings, ~/.claude/commands: \(listing(commands))")
        let library = make(world, "Agents", projectsFolder: world.home + "/Library/LaunchAgents")
        print("R10 ~/Library/LaunchAgents: \(String(describing: refusal(library)))")
        #expect(refusal(library) != nil, "made in ~/Library/LaunchAgents, its missing folders made too")
    }

    // MARK: Who may send it

    /// A process on the socket (a team session's too) is judged as the user's voice, as `lead` is; a page with any
    /// rights short of act is refused before the server sees it; a page never has it in its hello's kinds unless it acts.
    @Test func r11_whoMaySendIt() {
        let facts = PeerFacts(pid: 1, uid: nil, cgroup: nil, ancestry: nil, terminal: .none, sessionMarker: true, underRunner: nil)
        #expect(Principal.process(facts).route("project.new") == Principal.process(facts).route("lead"))
        #expect(Principal.process(facts).route("project.new") == .usersVoice)
        for rights: LiveRights in [[], .read, [.read, .draft], [.read, .draft, .watch], [.draft, .watch]] {
            for terminals in [false, true] {
                let route = Principal.page(rights, terminals: terminals).route("project.new")
                if case .refused(.voice, let why) = route {
                    #expect(!why.contains("/"), "a refusal names no path: \(why)")
                } else { Issue.record("\(rights) \(terminals): \(route)") }
            }
        }
    }
}
