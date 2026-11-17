import Foundation
import Testing
import VibeCore
import VibeNode

/// The install's build record (the start plan's S4a, ST-D13): `BuildRecord.write` in process, on scratch build folders,
/// and the command line's unlisted `install-record` that `scripts/install-node.sh` runs from the just-built binary.
/// Nothing here reads or writes the account's builds folder. The Mac runs these.
struct InstallTests {
    private let scratch = Scratch()

    static let commit = String(repeating: "a", count: 40)
    static let other = String(repeating: "b", count: 40)
    static let swift = "Swift version 6.4.2 (swift-6.4.2-RELEASE)\nTarget: x86_64-unknown-linux-gnu"
    static let resolved = Data(#"{"pins":[],"version":3}"#.utf8)

    /// A scratch builds folder holding `<name>/bin/` with `programs` (name to bytes) in it: the build folder's path.
    private func buildFolder(named name: String = InstallTests.commit, programs: [String: Data]) throws -> String {
        let folder = scratch.url("builds").appendingPathComponent(name)
        let bin = folder.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for (program, bytes) in programs {
            try bytes.write(to: bin.appendingPathComponent(program))
        }
        return folder.path
    }

    private func record(_ folder: String, commit: String = InstallTests.commit) -> Result<BuildInfo, StartRefusal> {
        BuildRecord.write(folder: folder, commit: commit, swiftVersionOutput: Self.swift, resolved: Self.resolved)
    }

    private func recordFile(_ folder: String) -> String { (folder as NSString).appendingPathComponent(BuildInfo.fileName) }

    /// Creates `folder/bin/<name>` by its raw bytes, holding `bytes`: false when the filesystem won't hold that name as a
    /// new entry (the Mac's APFS refuses a name that isn't UTF-8 and takes an NFC and an NFD spelling as one name).
    private func createRaw(in folder: String, name: [UInt8], bytes: Data) -> Bool {
        let bin = Sys.open((folder as NSString).appendingPathComponent("bin"), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard bin >= 0 else { return false }
        defer { Sys.close(bin) }
        let fd = openat(bin, name.map { CChar(bitPattern: $0) } + [0], O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { Sys.close(fd) }
        return bytes.withUnsafeBytes { Sys.write(fd, $0.baseAddress, $0.count) } == bytes.count
    }

    @Test func aRecordForAFolderNamedOtherThanItsCommitIsRefused() throws {
        let programs = ["vibeswitcher-host": Data("host".utf8)]
        // Another commit's folder: refused, naming both, and nothing written.
        let folder = try buildFolder(programs: programs)
        guard case let .failure(refusal) = record(folder, commit: Self.other) else {
            Issue.record("a folder named \(Self.commit) took a record of \(Self.other)")
            return
        }
        #expect(refusal.text.contains(Self.commit) && refusal.text.contains(Self.other), "\(refusal)")
        #expect(!FileManager.default.fileExists(atPath: recordFile(folder)))

        // A name that only starts with the commit, or a commit that isn't 40 lowercase hex digits: refused too.
        for name in [Self.commit + "-old", Self.commit + ".partial.x", "x" + Self.commit] {
            let named = try buildFolder(named: name, programs: programs)
            #expect(throws: StartRefusal.self, "\(name)") { try record(named).get() }
            #expect(!FileManager.default.fileExists(atPath: recordFile(named)), "\(name)")
        }
        for commit in [String(repeating: "A", count: 40), String(repeating: "a", count: 39), "HEAD"] {
            let named = try buildFolder(named: commit, programs: programs)
            #expect(throws: StartRefusal.self, "\(commit)") { try record(named, commit: commit).get() }
            #expect(!FileManager.default.fileExists(atPath: recordFile(named)), "\(commit)")
        }

        // Its own name takes it, and so does the install's staging name (`<commit>.partial`, renamed to `<commit>`
        // after the record: S4b), with a trailing slash or none.
        let own = try buildFolder(programs: programs)
        #expect(try record(own + "/").get().commit == Self.commit)
        let staged = try buildFolder(named: Self.commit + ".partial", programs: programs)
        #expect(try record(staged).get().commit == Self.commit)
        #expect(FileManager.default.fileExists(atPath: recordFile(staged)))
    }

    @Test func aRecordHashesEveryProgramAndRefusesALink() throws {
        // `abc`'s SHA-256 (FIPS 180-2's first example), and two other programs, a hidden one among them.
        let programs = ["vibeswitcher-host": Data("abc".utf8), "vibeswitcher": Data("cli".utf8), ".hidden": Data()]
        let folder = try buildFolder(programs: programs)
        let info = try record(folder).get()
        #expect(info.binaries.count == 3, "\(info.binaries)")
        #expect(info.binaries["vibeswitcher-host"] == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        for (name, bytes) in programs { #expect(info.binaries[name] == BuildInfo.sha256(of: bytes), "\(name)") }
        #expect(!info.binaries.keys.contains(BuildInfo.fileName))

        // A link in `bin/` (to a program beside it, or to one outside): refused, naming it; nothing written.
        let bin = (folder as NSString).appendingPathComponent("bin")
        for (name, target) in [("vibeswitcher-mcp", "vibeswitcher-host"), ("vibeswitcher-hook", "/bin/sh")] {
            let linked = try buildFolder(programs: programs)
            let linkedBin = (linked as NSString).appendingPathComponent("bin")
            try FileManager.default.createSymbolicLink(atPath: (linkedBin as NSString).appendingPathComponent(name), withDestinationPath: target)
            guard case let .failure(refusal) = record(linked) else {
                Issue.record("a link \(name) -> \(target) in bin/ was recorded")
                continue
            }
            #expect(refusal.text.contains(name), "\(refusal)")
            #expect(refusal.exitCode == 77, "\(refusal.exitCode)")
            #expect(!FileManager.default.fileExists(atPath: recordFile(linked)))
        }
        // A FIFO in `bin/`, which opens without a writer and reads as nothing: not a regular file, refused, naming it.
        let piped = try buildFolder(programs: programs)
        #expect(mkfifo((piped as NSString).appendingPathComponent("bin/fifo"), 0o600) == 0, "mkfifo: errno \(errno)")
        switch record(piped) {
        case .success(let recorded): Issue.record("a FIFO in bin/ was recorded: \(recorded.binaries)")
        case .failure(let refusal): #expect(refusal.text.contains("fifo") && refusal.exitCode == 77, "\(refusal) \(refusal.exitCode)")
        }
        #expect(!FileManager.default.fileExists(atPath: recordFile(piped)))
        // A name that isn't UTF-8 (where the filesystem holds one): refused, not recorded under a name it doesn't have.
        let mangled = try buildFolder(programs: programs)
        if createRaw(in: mangled, name: [UInt8(ascii: "n"), 0xff], bytes: Data("n".utf8)) {
            guard case let .failure(refusal) = record(mangled) else {
                Issue.record("a name that isn't UTF-8 was recorded")
                return
            }
            #expect(refusal.text.contains("UTF-8") && refusal.exitCode == 77, "\(refusal) \(refusal.exitCode)")
            #expect(!FileManager.default.fileExists(atPath: recordFile(mangled)))
        }
        // Two names with different bytes that Swift compares as equal (an NFC and an NFD "café", where the filesystem
        // holds both): one key would stand for two files, paired with the other's hash. Refused.
        let twins = try buildFolder(programs: programs)
        if createRaw(in: twins, name: Array("caf\u{e9}".utf8), bytes: Data("one".utf8)),
           createRaw(in: twins, name: Array("cafe\u{301}".utf8), bytes: Data("two".utf8)) {
            switch record(twins) {
            case .success(let recorded): Issue.record("two files were recorded as \(recorded.binaries.count - programs.count) entry: \(recorded.binaries)")
            case .failure(let refusal): #expect(refusal.text.contains("caf") && refusal.exitCode == 77, "\(refusal) \(refusal.exitCode)")
            }
            #expect(!FileManager.default.fileExists(atPath: recordFile(twins)))
        }
        // A folder in `bin/`: not a regular file either.
        let nested = try buildFolder(programs: programs)
        try FileManager.default.createDirectory(atPath: (nested as NSString).appendingPathComponent("bin/sub"), withIntermediateDirectories: false)
        #expect(throws: StartRefusal.self) { try record(nested).get() }
        #expect(!FileManager.default.fileExists(atPath: recordFile(nested)))

        // `bin/` itself a link, the build folder a link, and no `bin/`: refused.
        let linkedFolder = scratch.url("builds").appendingPathComponent(Self.commit)
        try FileManager.default.createDirectory(at: linkedFolder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: linkedFolder.appendingPathComponent("bin").path, withDestinationPath: bin)
        #expect(throws: StartRefusal.self) { try record(linkedFolder.path).get() }
        let outer = scratch.url("builds")
        try FileManager.default.createDirectory(at: outer, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: outer.appendingPathComponent(Self.commit).path, withDestinationPath: folder)
        #expect(throws: StartRefusal.self) { try record(outer.appendingPathComponent(Self.commit).path).get() }
        let empty = scratch.url("builds").appendingPathComponent(Self.commit)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: StartRefusal.self) { try record(empty.path).get() }
        #expect(throws: StartRefusal.self) { try record(try buildFolder(programs: [:])).get() }
    }

    @Test func aRecordNamesItsToolchainAndResolvedFile() throws {
        let folder = try buildFolder(programs: ["vibeswitcher-host": Data("host".utf8), "vibeswitcher-server": Data("server".utf8)])
        let info = try record(folder).get()
        #expect(info.format == BuildInfo.format)
        #expect(info.commit == Self.commit)
        #expect(info.swift == Self.swift)
        #expect(info.resolved == BuildInfo.sha256(of: Self.resolved))
        // Written as `BuildInfo` encodes it, private to the user, and read back whole by `BuildInfo.read`.
        let file = recordFile(folder)
        #expect(FileManager.default.contents(atPath: file) == info.encoded)
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o077 == 0, "build-info is \(String(mode.intValue, radix: 8))")
        #expect(try BuildInfo.read(buildFolder: folder).get() == info)

        // No toolchain text: refused, nothing written.
        let blank = try buildFolder(programs: ["vibeswitcher-host": Data("host".utf8)])
        #expect(throws: StartRefusal.self) {
            try BuildRecord.write(folder: blank, commit: Self.commit, swiftVersionOutput: " \n", resolved: Self.resolved).get()
        }
        #expect(!FileManager.default.fileExists(atPath: recordFile(blank)))
    }

    /// A disk failure (a program that can't be opened, a `build-info` that can't be written) exits 1, `StartRefusal`'s
    /// failure, not 77, which is for a build that isn't the shape the record vouches for.
    @Test func aRecordThatCantBeReadOrWrittenIsAFailureNotARefusal() throws {
        let programs = ["vibeswitcher-host": Data("host".utf8)]
        // A program the user can't open.
        let locked = try buildFolder(programs: programs)
        let program = (locked as NSString).appendingPathComponent("bin/vibeswitcher-host")
        #expect(chmod(program, 0) == 0)
        defer { chmod(program, 0o600) }
        if Sys.open(program, O_RDONLY | O_CLOEXEC) < 0 {
            guard case let .failure(refusal) = record(locked) else {
                Issue.record("a program that can't be opened was recorded")
                return
            }
            #expect(refusal.exitCode == 1, "\(refusal) \(refusal.exitCode)")
        }
        #expect(!FileManager.default.fileExists(atPath: recordFile(locked)))

        // A build folder `build-info` can't be written in.
        let readOnly = try buildFolder(programs: programs)
        #expect(chmod(readOnly, 0o555) == 0)
        defer { chmod(readOnly, 0o755) }
        if access(readOnly, W_OK) != 0 {
            guard case let .failure(refusal) = record(readOnly) else {
                Issue.record("a record was written into a read-only folder")
                return
            }
            #expect(refusal.text.contains(BuildInfo.fileName) && refusal.exitCode == 1, "\(refusal) \(refusal.exitCode)")
        }
        #expect(!FileManager.default.fileExists(atPath: recordFile(readOnly)))
    }

    @Test func theInstalledNamesAreTheBuildsPrograms() {
        #expect(BuildRecord.installedNames == ["vibeswitcher-host", "vibeswitcher-server", "vibeswitcher", "vibeswitcher-hook", "vibeswitcher-mcp"])
        #expect(BuildRecord.installedNames.contains(BuildInfo.host) && BuildRecord.installedNames.contains(BuildInfo.server))
    }

    /// The command line's `install-record`, run as built: it writes what `BuildRecord.write` writes, from the files it
    /// is given; a misuse exits 64, a refusal 77 and a failure 1 (`StartRefusal`'s), each writing nothing; and the usage
    /// text doesn't list it.
    @Test func theCommandLineWritesTheRecord() async throws {
        let home = scratch.url("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("home"), withIntermediateDirectories: true)
        let environment = scratchEnvironment(home)
        let folder = try buildFolder(programs: ["vibeswitcher-host": Data("host".utf8), "vibeswitcher": Data("cli".utf8)])
        let inputs = scratch.url("inputs")
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let version = inputs.appendingPathComponent("swift-version"), resolvedFile = inputs.appendingPathComponent("Package.resolved")
        // As `swift --version > F` writes it: with its line end, which the record leaves out.
        try Data((Self.swift + "\n").utf8).write(to: version)
        try Self.resolved.write(to: resolvedFile)
        let arguments = ["install-record", folder, "--commit", Self.commit, "--swift-version-output", version.path, "--resolved", resolvedFile.path]

        for misuse in [["install-record"], ["install-record", folder, "--commit", Self.commit], arguments + ["--extra"],
                       ["install-record", folder, "--commit", Self.commit, "--swift-version-output", version.path, "--resolved"]] {
            let ran = try await run(commandLine, misuse, environment: environment)
            #expect(ran.status == 64, "\(misuse): \(ran.status) \(ran.errors)")
        }
        let refused = try await run(commandLine, ["install-record", folder, "--commit", Self.other, "--swift-version-output", version.path,
                                                  "--resolved", resolvedFile.path], environment: environment)
        #expect(refused.status == 77, "\(refused.status) \(refused.errors)")
        #expect(refused.errors.contains(Self.other), "\(refused.errors)")
        // An input that can't be read is a failure (1); one that is a link, or a FIFO, is refused (77).
        let unreadable = try await run(commandLine, ["install-record", folder, "--commit", Self.commit, "--swift-version-output",
                                                     inputs.appendingPathComponent("missing").path, "--resolved", resolvedFile.path], environment: environment)
        #expect(unreadable.status == 1, "\(unreadable.status) \(unreadable.errors)")
        let linkedInput = inputs.appendingPathComponent("linked"), fifoInput = inputs.appendingPathComponent("fifo")
        try FileManager.default.createSymbolicLink(at: linkedInput, withDestinationURL: version)
        #expect(mkfifo(fifoInput.path, 0o600) == 0, "mkfifo: errno \(errno)")
        for input in [linkedInput, fifoInput] {
            let refusedInput = try await run(commandLine, ["install-record", folder, "--commit", Self.commit, "--swift-version-output",
                                                           input.path, "--resolved", resolvedFile.path], environment: environment)
            #expect(refusedInput.status == 77, "\(input.lastPathComponent): \(refusedInput.status) \(refusedInput.errors)")
        }
        #expect(!FileManager.default.fileExists(atPath: recordFile(folder)))

        let ran = try await run(commandLine, arguments, environment: environment)
        #expect(ran.status == 0, "\(ran.status) \(ran.errors)")
        let info = try BuildInfo.read(buildFolder: folder).get()
        #expect(info.commit == Self.commit && info.swift == Self.swift && info.resolved == BuildInfo.sha256(of: Self.resolved))
        #expect(info.binaries == ["vibeswitcher-host": BuildInfo.sha256(of: Data("host".utf8)), "vibeswitcher": BuildInfo.sha256(of: Data("cli".utf8))])

        let help = try await run(commandLine, ["help"], environment: environment)
        #expect(help.status == 0)
        #expect(!help.output.contains("install-record"), "\(help.output)")
    }
}

/// `scripts/install-node.sh` (the start plan's S4b, ST-D8 to ST-D12), run whole on a synthetic repository: one commit of
/// the working copy's script, its libraries, `Resources/bin/vs-*`, `.swift-version` and `Package.resolved`, in a scratch
/// bare "origin" that serves a commit by its hash as GitHub does, a scratch clone as `--repo`, and a stand-in `gh` that
/// answers from canned JSON and records each call's arguments and environment. Every run passes `--prefix <scratch>`,
/// `--gh <stand-in>` and `--test-origin <scratch origin>`: nothing reaches GitHub, the user's token or the account's
/// builds folder. The runs that get past CI pass the debug products (`--test-products`), which the link check refuses
/// (RUNPATH into swiftly): the static products' cases are S4c's. Linux only: the script's tools (`readelf`, the loader's
/// `--list`, `getent`, `flock`) are Linux's. The cases are `InstallTests`' own, so the security document names them as
/// `InstallTests.<case>`; the fixture is `InstallScript`'s.
extension InstallTests {
    /// The world: the working repository's one commit (`extra` files beside the working copy's), pushed to a bare
    /// origin's `v2` that serves reachable commits by hash, its clone, the stand-in `gh` (answering that both runners
    /// passed the commit) and a prefix not yet made. With `repository`, the working repository is a `git clone
    /// --no-local` of it instead, its HEAD as `v2`, and the commit is the working copy's files committed on top of it.
    fileprivate func world(extra: [String: String] = [:], repository: URL? = nil) async throws -> InstallScript.World {
        typealias World = InstallScript.World
        let root = scratch.url("install")
        let world = World(root: root, work: root.appendingPathComponent("work"), origin: root.appendingPathComponent("origin.git"),
                          clone: root.appendingPathComponent("clone"), standIn: root.appendingPathComponent("gh"),
                          prefix: root.appendingPathComponent("builds"), base: "")
        for folder in [world.work, world.gitHome, world.home, world.standIn.appendingPathComponent("calls")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        var files = extra
        let workingCopy = InstallScript.workingCopy
        let copied = ["scripts/install-node.sh", ".swift-version", "Package.resolved"]
            + (try FileManager.default.contentsOfDirectory(atPath: workingCopy.appendingPathComponent("scripts/lib").path))
            .filter { $0.hasSuffix(".sh") }.map { "scripts/lib/" + $0 }
            + (try FileManager.default.contentsOfDirectory(atPath: workingCopy.appendingPathComponent("Resources/bin").path))
            .filter { $0.hasPrefix("vs-") }.map { "Resources/bin/" + $0 }
        for path in copied {
            files[path] = try String(contentsOf: workingCopy.appendingPathComponent(path), encoding: .utf8)
        }
        if let repository {
            try await InstallScript.git(["clone", "-q", "--no-local", repository.path, world.work.path], in: root, home: world.gitHome)
            try await world.git(["checkout", "-q", "-B", "v2"])
        } else {
            try await world.git(["init", "-q", "-b", "v2"])
        }
        let base = try await world.commit(files, message: "base")
        try await InstallScript.git(["init", "-q", "--bare", world.origin.path], in: root, home: world.gitHome)
        try await world.git(["config", "uploadpack.allowReachableSHA1InWant", "true"], in: world.origin)
        try await world.git(["push", "-q", "file://" + world.origin.path, "v2:v2"])
        try await InstallScript.git(["clone", "-q", "-b", "v2", "file://" + world.origin.path, world.clone.path], in: root, home: world.gitHome)
        try ScratchNode.script("""
            #!/bin/sh
            d='\(world.standIn.path)'
            c=$(/usr/bin/mktemp -d "$d/calls/call.XXXXXX") || exit 70
            printf '%s\\n' "$@" > "$c/args"
            /usr/bin/env > "$c/env"
            case "$1" in
              auth) printf '%s\\n' '\(InstallScript.token)' ;;
              api) /bin/cat "$d/compare.json" ;;
              run)
                # gh 2.45's own check (`gh run list --json` with no list prints these): an unknown field is exit 1.
                fields=""; prev=""
                for a in "$@"; do [ "$prev" = --json ] && fields=$a; prev=$a; done
                for f in $(printf '%s' "$fields" | /usr/bin/tr ',' ' '); do
                  case " conclusion createdAt databaseId displayTitle event headBranch headSha name number startedAt status updatedAt url workflowDatabaseId workflowName " in
                    *" $f "*) ;;
                    *) printf 'Unknown JSON field: "%s"\n' "$f" >&2; exit 1 ;;
                  esac
                done
                /bin/cat "$d/runs.json" ;;
              *) exit 1 ;;
            esac

            """, at: world.gh)
        let made = World(root: root, work: world.work, origin: world.origin, clone: world.clone, standIn: world.standIn,
                         prefix: world.prefix, base: base)
        try made.passing(base)
        return made
    }

    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func anInstallFromADirtyTreeIsRefused() async throws {
        let world = try await world()
        // A tracked file changed.
        try "0.0.0\n".write(to: world.clone.appendingPathComponent(".swift-version"), atomically: true, encoding: .utf8)
        let changed = try await world.install(try world.arguments(world.base, products: true))
        #expect(changed.status == 65, "\(changed.status) \(changed.errors)")
        #expect(changed.errors.contains(".swift-version"), "\(changed.errors)")
        try await world.git(["checkout", "--", ".swift-version"], in: world.clone)

        // An untracked file under Sources/.
        let sources = world.clone.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "let planted = 1\n".write(to: sources.appendingPathComponent("Planted.swift"), atomically: true, encoding: .utf8)
        let untracked = try await world.install(try world.arguments(world.base, products: true))
        #expect(untracked.status == 65, "\(untracked.status) \(untracked.errors)")
        #expect(untracked.errors.contains("Sources/Planted.swift"), "\(untracked.errors)")

        // Neither asked gh anything, nor made the prefix.
        #expect(try world.calls().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: world.prefix.path))
    }

    /// The courtesy check ignores what the user's own `git status` ignores under the HOME it runs with: the
    /// `core.excludesFile` of `~/.gitconfig`, else `~/.config/git/ignore`. A file neither lists is still refused.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func theAccountsOwnIgnoreFileIsHonouredByTheCleanCheck() async throws {
        let world = try await world()
        let idea = world.clone.appendingPathComponent(".idea")
        try FileManager.default.createDirectory(at: idea, withIntermediateDirectories: true)
        try "<project/>\n".write(to: idea.appendingPathComponent("workspace.xml"), atomically: true, encoding: .utf8)
        let refused = try await world.install(try world.arguments(world.base, products: true))
        #expect(refused.status == 65 && refused.errors.contains(".idea/workspace.xml"), "\(refused.status) \(refused.errors)")

        // core.excludesFile in ~/.gitconfig, by a ~/ path.
        try "[core]\n\texcludesFile = ~/global-ignore\n".write(to: world.home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        try ".idea/\n".write(to: world.home.appendingPathComponent("global-ignore"), atomically: true, encoding: .utf8)
        let configured = try await world.install(try world.arguments(world.base, products: true))
        // Past the courtesy check, the debug products stop at the link check.
        #expect(configured.status == 69, "\(configured.status) \(configured.errors)")

        // No core.excludesFile: ~/.config/git/ignore.
        try FileManager.default.removeItem(at: world.home.appendingPathComponent(".gitconfig"))
        let xdg = world.home.appendingPathComponent(".config/git")
        try FileManager.default.createDirectory(at: xdg, withIntermediateDirectories: true)
        try ".idea/\n".write(to: xdg.appendingPathComponent("ignore"), atomically: true, encoding: .utf8)
        let defaulted = try await world.install(try world.arguments(world.base, products: true))
        #expect(defaulted.status == 69, "\(defaulted.status) \(defaulted.errors)")

        // A file it doesn't list is still dirt.
        try "x\n".write(to: world.clone.appendingPathComponent("planted"), atomically: true, encoding: .utf8)
        let planted = try await world.install(try world.arguments(world.base, products: true))
        #expect(planted.status == 65 && planted.errors.contains("planted"), "\(planted.status) \(planted.errors)")
    }

    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func aCommitNotOnOriginV2IsRefused() async throws {
        let world = try await world()
        // A commit on another branch of the origin, not reachable from its v2.
        try await world.git(["checkout", "-q", "-b", "elsewhere"])
        let elsewhere = try await world.commit(["ELSEWHERE": "not on v2\n"], message: "elsewhere")
        try await world.git(["push", "-q", "file://" + world.origin.path, "elsewhere:elsewhere"])
        try world.passing(elsewhere)
        let refused = try await world.install(try world.arguments(elsewhere, products: true))
        #expect(refused.status == 67, "\(refused.status) \(refused.errors)")
        #expect(refused.errors.contains("isn't on v2"), "\(refused.errors)")
        #expect(world.prefixIsEmpty)

        // And GitHub's compare saying anything but identical or ahead, for a commit git finds on v2; an answer of two
        // lines is still refused on one.
        for status in ["diverged", "behind", #"two\nlines"#] {
            try world.answers(compare: status, runs: [InstallScript.World.ciRun("v2 linux", on: world.base, id: 10),
                                                      InstallScript.World.ciRun("v2 macos", on: world.base, id: 11)])
            let compared = try await world.install(try world.arguments(world.base, products: true))
            #expect(compared.status == 67, "\(status): \(compared.status) \(compared.errors)")
            #expect(compared.errors.contains(status.components(separatedBy: #"\n"#)[0]), "\(compared.errors)")
            #expect(compared.errors.split(separator: "\n").count == 1, "a refusal of more than one line: \(compared.errors)")
        }
        #expect(world.prefixIsEmpty)
    }

    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func aCommitBothRunnersDidntPassIsRefused() async throws {
        let world = try await world()
        let commit = world.base
        typealias World = InstallScript.World
        let cases: [(String, String, [[String: Any]])] = [
            ("v2 macos missing", "v2 macos", [World.ciRun("v2 linux", on: commit, id: 10),
                                              World.ciRun("v2 macos", on: commit, id: 11, event: "pull_request")]),
            ("v2 linux failed", "v2 linux", [World.ciRun("v2 linux", on: commit, id: 10, conclusion: "failure"),
                                             World.ciRun("v2 macos", on: commit, id: 11)]),
            ("the latest run cancelled", "v2 linux", [World.ciRun("v2 linux", on: commit, id: 10), World.ciRun("v2 macos", on: commit, id: 11),
                                                      World.ciRun("v2 linux", on: commit, id: 12, conclusion: "cancelled")]),
            ("an older success under a newer failure", "v2 macos", [World.ciRun("v2 macos", on: commit, id: 13, conclusion: "failure"),
                                                                    World.ciRun("v2 linux", on: commit, id: 10),
                                                                    World.ciRun("v2 macos", on: commit, id: 11)]),
        ]
        for (what, workflow, runs) in cases {
            try world.answers(runs: runs)
            let refused = try await world.install(try world.arguments(commit, products: true))
            #expect(refused.status == 67, "\(what): \(refused.status) \(refused.errors)")
            #expect(refused.errors.contains(workflow), "\(what): \(refused.errors)")
        }
        #expect(world.prefixIsEmpty)
    }

    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func ghRunsWithNothingFromTheUsersEnvironmentOrConfig() async throws {
        let world = try await world()
        let config = world.home.appendingPathComponent(".config/gh")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "http_unix_socket: \(world.root.path)/gh.sock\n".write(to: config.appendingPathComponent("config.yml"), atomically: true, encoding: .utf8)
        let users = ["GH_TOKEN": "the-users-token", "GH_REPO": "someone/else", "GITHUB_TOKEN": "the-users-other-token",
                     "HTTPS_PROXY": "http://127.0.0.1:9", "SSL_CERT_FILE": world.root.appendingPathComponent("certs.pem").path]
        let ran = try await world.install(try world.arguments(world.base, products: true), environment: users)
        #expect(ran.status == 69, "\(ran.status) \(ran.errors)")

        let calls = try world.calls()
        #expect(calls.count == 3, "\(calls.map(\.arguments))")
        // Only these: what the script gives (env -i), and what the stand-in's own shell adds.
        let allowed: Set<String> = ["HOME", "PATH", "GH_CONFIG_DIR", "GH_TOKEN", "GH_PROMPT_DISABLED", "GH_NO_UPDATE_NOTIFIER", "PWD", "OLDPWD", "SHLVL", "_"]
        let account = InstallScript.accountHome()
        for call in calls {
            #expect(Set(call.environment.keys).isSubset(of: allowed), "\(call.arguments): \(call.environment.keys.sorted())")
            #expect(call.environment["PATH"] == "/usr/bin:/bin")
            for name in users.keys where name != "GH_TOKEN" { #expect(call.environment[name] == nil, "\(name) reached gh") }
            #expect(call.environment["GH_TOKEN"] != users["GH_TOKEN"])
            guard call.arguments.first != "auth" else {
                // The token, read once from gh's own store of the account's home: no network call, no -R.
                #expect(call.arguments == ["auth", "token", "-h", "github.com"])
                #expect(call.environment["HOME"] == account && call.environment["GH_TOKEN"] == nil && call.environment["GH_CONFIG_DIR"] == nil,
                        "\(call.environment)")
                continue
            }
            #expect(call.environment["GH_TOKEN"] == InstallScript.token)
            // HOME and GH_CONFIG_DIR: folders no process of the user can make or write (a config.yml there, with an
            // http_unix_socket, would answer the CI check), so gh reads no configuration at all.
            let home = try #require(call.environment["HOME"]), configDir = try #require(call.environment["GH_CONFIG_DIR"])
            for folder in [home, configDir] {
                #expect(!folder.hasPrefix(world.home.path) && !folder.hasPrefix(account + "/"), "\(folder)")
                #expect(!InstallScript.userCanCreateOrWrite(folder), "the user can make or write gh's \(folder)")
            }
            let named = zip(call.arguments, call.arguments.dropFirst()).contains { $0 == ("-R", InstallScript.repository) }
                || call.arguments.contains { $0.hasPrefix("repos/\(InstallScript.repository)/") }
            #expect(named, "\(call.arguments)")
        }
        #expect(calls.filter { $0.arguments.first == "auth" }.count == 1)
        #expect(calls.contains { $0.arguments.starts(with: ["api", "repos/\(InstallScript.repository)/compare/\(world.base)...v2"]) })
        #expect(calls.contains { $0.arguments.starts(with: ["run", "list", "-R", InstallScript.repository, "--commit", world.base]) })
    }

    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func aToolchainTheUserCanWriteIsRefused() async throws {
        let world = try await world()
        var toolchains = [world.root.appendingPathComponent("toolchain").path]
        try FileManager.default.createDirectory(atPath: toolchains[0] + "/usr/bin", withIntermediateDirectories: true)
        let swiftly = InstallScript.accountHome() + "/.local/share/swiftly"
        if FileManager.default.fileExists(atPath: swiftly) { toolchains.append(swiftly) }
        for toolchain in toolchains {
            // No --test-products: the toolchain is checked. An origin that isn't there: a fetch would fail (1).
            let arguments = [world.base, "--prefix", world.prefix.path, "--repo", world.clone.path, "--gh", world.gh.path,
                             "--test-origin", "file://" + world.root.appendingPathComponent("no-origin.git").path, "--toolchain", toolchain]
            let refused = try await world.install(arguments)
            #expect(refused.status == 68, "\(toolchain): \(refused.status) \(refused.errors)")
            #expect(refused.errors.contains(toolchain), "\(refused.errors)")
        }
        #expect(try world.calls().isEmpty, "gh was asked before the toolchain's check")
        #expect(!FileManager.default.fileExists(atPath: world.prefix.path))
    }

    /// `--test-products` stands for the build: it is checked with the local refusals, before any fetch or gh call.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func aTestProductsFolderIsCheckedBeforeAnyFetch() async throws {
        let world = try await world()
        let products = try world.debugProducts()
        // No swift-version: usage (64).
        let version = products.appendingPathComponent("swift-version")
        try FileManager.default.removeItem(at: version)
        let unversioned = try await world.install(try world.arguments(world.base, products: true))
        #expect(unversioned.status == 64 && unversioned.errors.contains("swift-version"), "\(unversioned.status) \(unversioned.errors)")
        try Data((InstallTests.swift + "\n").utf8).write(to: version)
        // A product that is a link: not a regular file (69).
        let mcp = products.appendingPathComponent("vibeswitcher-mcp")
        try FileManager.default.removeItem(at: mcp)
        try FileManager.default.createSymbolicLink(at: mcp, withDestinationURL: builtProducts.appendingPathComponent("vibeswitcher-mcp"))
        let linked = try await world.install(try world.arguments(world.base, products: true))
        #expect(linked.status == 69 && linked.errors.contains("vibeswitcher-mcp"), "\(linked.status) \(linked.errors)")
        #expect(try world.calls().isEmpty, "gh was asked before --test-products was checked")
    }

    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func aFirstInstallRunsOnlyTheCommitsOwnScript() async throws {
        let world = try await world()
        let script = try String(contentsOf: world.script, encoding: .utf8)
        let scratchLib = try String(contentsOf: world.clone.appendingPathComponent("scripts/lib/scratch.sh"), encoding: .utf8)
        let swiftJobs = try String(contentsOf: world.clone.appendingPathComponent("scripts/lib/swift-jobs.sh"), encoding: .utf8)
        // A working copy (not --repo, which stays clean) holding the script and its libraries.
        func copy(_ name: String, script scriptText: String, scratch scratchText: String) throws -> URL {
            let scripts = world.root.appendingPathComponent(name).appendingPathComponent("scripts")
            try FileManager.default.createDirectory(at: scripts.appendingPathComponent("lib"), withIntermediateDirectories: true)
            try ScratchNode.script(scriptText, at: scripts.appendingPathComponent("install-node.sh"))
            try ScratchNode.script(scratchText, at: scripts.appendingPathComponent("lib/scratch.sh"))
            try ScratchNode.script(swiftJobs, at: scripts.appendingPathComponent("lib/swift-jobs.sh"))
            return scripts.appendingPathComponent("install-node.sh")
        }
        // The commit's own bytes, run from elsewhere: past provenance, to the link check.
        let same = try await world.install(try world.arguments(world.base, products: true), script: try copy("same", script: script, scratch: scratchLib))
        #expect(same.status == 69, "\(same.status) \(same.errors)")

        // The script changed: refused.
        let changedScript = try await world.install(try world.arguments(world.base, products: true),
                                                    script: try copy("script", script: script + "# changed\n", scratch: scratchLib))
        #expect(changedScript.status == 66, "\(changedScript.status) \(changedScript.errors)")
        #expect(changedScript.errors.contains("install-node.sh"), "\(changedScript.errors)")

        // Its scratch.sh changed with a marker write: refused, and the line never ran (nothing beside is sourced).
        let marker = world.root.appendingPathComponent("marker-scratch")
        let planted = scratchLib + "\n: > '\(marker.path)'\n"
        let changedLib = try await world.install(try world.arguments(world.base, products: true),
                                                 script: try copy("lib", script: script, scratch: planted))
        #expect(changedLib.status == 66, "\(changedLib.status) \(changedLib.errors)")
        #expect(changedLib.errors.contains("scratch.sh"), "\(changedLib.errors)")
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the changed scratch.sh ran")
        #expect(world.prefixIsEmpty)
    }

    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func theNextInstallRunsThePreviousBuildsScript() async throws {
        let world = try await world()
        // The installed build: the base commit, laid out by hand. The next commit on v2, what's installed now, changes
        // the script too, so only a comparison against the installed commit's blob passes the installed copy.
        let script = try String(contentsOf: world.script, encoding: .utf8)
        let next = try await world.commit(["NEXT": "the next commit\n", "scripts/install-node.sh": script + "# the next commit's\n"],
                                          message: "next")
        try await world.git(["push", "-q", "file://" + world.origin.path, "v2:v2"])
        try await world.git(["pull", "-q"], in: world.clone)
        try world.passing(next)
        /// `commit`'s build folder under the prefix, laid out by hand from its blobs, and `current` naming it: the
        /// installed copy of the script.
        func layOut(_ commit: String) async throws -> (script: String, resources: URL) {
            let installed = world.prefix.appendingPathComponent(commit)
            let resources = installed.appendingPathComponent("Resources")
            try FileManager.default.createDirectory(at: resources.appendingPathComponent("lib"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: installed.appendingPathComponent("bin"), withIntermediateDirectories: true)
            let installedScript = try await world.git(["show", "\(commit):scripts/install-node.sh"], in: world.work, raw: true)
            try ScratchNode.script(installedScript, at: resources.appendingPathComponent("install-node.sh"))
            for name in ["scratch.sh", "swift-jobs.sh"] {
                let text = try await world.git(["show", "\(commit):scripts/lib/\(name)"], in: world.work, raw: true)
                try text.write(to: resources.appendingPathComponent("lib/\(name)"), atomically: true, encoding: .utf8)
            }
            try Data("cli".utf8).write(to: installed.appendingPathComponent("bin/vibeswitcher"))
            _ = try BuildRecord.write(folder: installed.path, commit: commit, swiftVersionOutput: InstallTests.swift, resolved: InstallTests.resolved).get()
            let current = world.prefix.appendingPathComponent("current")
            try? FileManager.default.removeItem(at: current)
            try FileManager.default.createSymbolicLink(atPath: current.path, withDestinationPath: commit)
            return (installedScript, resources)
        }
        let (installedScript, resources) = try await layOut(world.base)
        #expect(installedScript != (try String(contentsOf: world.script, encoding: .utf8)), "the next commit's script is the installed one's")
        let current = world.prefix.appendingPathComponent("current/Resources/install-node.sh")

        // The repository's script: refused, naming the installed copy.
        let fromRepository = try await world.install(try world.arguments(next, products: true))
        #expect(fromRepository.status == 66, "\(fromRepository.status) \(fromRepository.errors)")
        #expect(fromRepository.errors.contains(current.path), "\(fromRepository.errors)")

        // The installed copy: past provenance (against the installed commit's blobs, not the next one's), to the link
        // check.
        let fromCurrent = try await world.install(try world.arguments(next, products: true), script: current)
        #expect(fromCurrent.status == 69, "\(fromCurrent.status) \(fromCurrent.errors)")
        #expect(fromCurrent.output.contains("checked out \(next) "), "\(fromCurrent.output)")

        // The installed copy changed: refused.
        try ScratchNode.script(installedScript + "# changed\n", at: resources.appendingPathComponent("install-node.sh"))
        let changed = try await world.install(try world.arguments(next, products: true), script: current)
        #expect(changed.status == 66, "\(changed.status) \(changed.errors)")
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: world.prefix.path)) == [world.base, "current"])

        // An installed commit v2's tip doesn't reach (a branch of the origin's): fetched by its hash too, its copy runs.
        try await world.git(["checkout", "-q", "-b", "aside", world.base])
        let aside = try await world.commit(["ASIDE": "not on v2\n"], message: "aside")
        try await world.git(["push", "-q", "file://" + world.origin.path, "aside:aside"])
        try await world.git(["checkout", "-q", "v2"])
        _ = try await layOut(aside)
        let fromAside = try await world.install(try world.arguments(next, products: true), script: current)
        #expect(fromAside.status == 69, "\(fromAside.status) \(fromAside.errors)")
    }

    /// One install at a time on a prefix: a second, while the first holds the prefix's lock, is refused before any
    /// fetch (the staging folder and `current.new` have fixed names).
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func aSecondInstallOnTheSamePrefixIsRefused() async throws {
        let world = try await world()
        try FileManager.default.createDirectory(at: world.prefix, withIntermediateDirectories: true)
        let held = Sys.open(world.prefix.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try #require(held >= 0, "open: errno \(errno)")
        #expect(flock(held, LOCK_EX | LOCK_NB) == 0, "flock: errno \(errno)")
        let refused = try await world.install(try world.arguments(world.base, products: true))
        Sys.close(held)
        #expect(refused.status == 1 && refused.errors.contains("another install"), "\(refused.status) \(refused.errors)")
        #expect(try world.calls().isEmpty, "gh was asked while another install held the prefix")
        // Once it's let go, the same install runs on (to the link check).
        let ran = try await world.install(try world.arguments(world.base, products: true))
        #expect(ran.status == 69, "\(ran.status) \(ran.errors)")
    }

    /// A commit already under the prefix: refused with the local refusals, before any fetch, gh call or build.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func anInstalledCommitIsRefusedBeforeAnyFetch() async throws {
        let world = try await world()
        try FileManager.default.createDirectory(at: world.prefix.appendingPathComponent(world.base), withIntermediateDirectories: true)
        let refused = try await world.install(try world.arguments(world.base, products: true))
        #expect(refused.status == 1 && refused.errors.contains("is there already"), "\(refused.status) \(refused.errors)")
        #expect(try world.calls().isEmpty, "gh was asked about a commit already installed")
    }

    /// A build folder an earlier run renamed into place before it wrote `installs` and `current` (a failed append, a
    /// signal): the rerun finishes it, with no fetch or gh call, and the one after that is refused as installed. A
    /// folder whose build-info names another commit is refused, saying to remove it.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func anInstallStoppedAfterItsRenameIsFinishedByARerun() async throws {
        let world = try await world()
        let folder = world.prefix.appendingPathComponent(world.base)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"commit":"\#(world.base)"}"#.utf8).write(to: folder.appendingPathComponent("build-info"))
        let finished = try await world.install(try world.arguments(world.base, products: true))
        #expect(finished.status == 0, "\(finished.status) \(finished.errors)")
        let current = try? FileManager.default.destinationOfSymbolicLink(atPath: world.prefix.appendingPathComponent("current").path)
        #expect(current == world.base)
        let installs = (try? String(contentsOf: world.prefix.appendingPathComponent("installs"), encoding: .utf8)) ?? ""
        #expect(installs.split(separator: "\n").map { $0.split(separator: " ").first.map(String.init) } == [world.base], "\(installs)")
        #expect(try world.calls().isEmpty, "gh was asked while finishing a folder already checked")

        let again = try await world.install(try world.arguments(world.base, products: true))
        #expect(again.status == 1 && again.errors.contains("\(world.base) is installed"), "\(again.status) \(again.errors)")

        let other = world.root.appendingPathComponent("other-prefix")
        let otherFolder = other.appendingPathComponent(world.base)
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        try Data(#"{"commit":"\#(String(repeating: "0", count: 40))"}"#.utf8).write(to: otherFolder.appendingPathComponent("build-info"))
        var arguments = try world.arguments(world.base, products: true)
        arguments[2] = other.path
        let refused = try await world.install(arguments)
        #expect(refused.status == 1 && refused.errors.contains("remove it"), "\(refused.status) \(refused.errors)")
        #expect(!FileManager.default.fileExists(atPath: other.appendingPathComponent("current").path))
    }

    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func theTestFlagsNeedAScratchPrefix() async throws {
        let world = try await world()
        // A dirty --repo: were a prefix let through, the run would stop at the courtesy check (65), writing nothing.
        try "planted\n".write(to: world.clone.appendingPathComponent("planted"), atomically: true, encoding: .utf8)
        let origin = "file://" + world.origin.path
        let products = try world.debugProducts().path
        let hold = world.root.appendingPathComponent("hold")
        try FileManager.default.createDirectory(at: hold, withIntermediateDirectories: true)
        let flags = [["--gh", world.gh.path], ["--test-origin", origin], ["--test-products", products],
                     ["--test-hold", hold.path]]
        for flag in flags {
            let bare = try await world.install([world.base, "--repo", world.clone.path] + flag)
            #expect(bare.status == 64, "\(flag[0]) without --prefix: \(bare.status) \(bare.errors)")
            // With a scratch prefix, the same flag passes the arguments.
            let scratchPrefix = try await world.install([world.base, "--repo", world.clone.path, "--prefix", world.prefix.path] + flag)
            #expect(scratchPrefix.status == 65, "\(flag[0]) with a scratch prefix: \(scratchPrefix.status) \(scratchPrefix.errors)")
        }
        // The account's default prefix through a link to it, a prefix inside the account's .vibeswitcher spelled
        // there, and one inside it through a link (refused only once resolved, not as spelled nor as the builds folder).
        let account = InstallScript.accountHome()
        let link = world.root.appendingPathComponent("default-builds")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: account + "/.vibeswitcher/v2/builds")
        let inside = account + "/.vibeswitcher/v2/install-test-\(UUID().uuidString)"
        let linkedInside = world.root.appendingPathComponent("vibeswitcher-v2")
        try FileManager.default.createSymbolicLink(atPath: linkedInside.path, withDestinationPath: account + "/.vibeswitcher/v2")
        for prefix in [link.path, inside, linkedInside.path] {
            for flag in flags {
                let refused = try await world.install([world.base, "--repo", world.clone.path, "--prefix", prefix] + flag)
                #expect(refused.status == 64, "\(prefix) \(flag[0]): \(refused.status) \(refused.errors)")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: inside))
        #expect(try world.calls().isEmpty)
    }

    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func nothingInTheUsersCloneOrConfigShapesTheBuild() async throws {
        let world = try await world(extra: [".gitattributes": "* filter=marker\n"])
        let markers = world.root.appendingPathComponent("markers")
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        // Another commit to stand in for the base, in the origin and in the clone: replace refs for the base.
        try await world.git(["checkout", "-q", "-b", "stand-in"])
        let standIn = try await world.commit(["STAND-IN": "a replacement\n"], message: "stand-in")
        try await world.git(["push", "-q", "file://" + world.origin.path, "stand-in:stand-in"])
        try await world.git(["replace", world.base, standIn], in: world.origin)
        try await world.git(["fetch", "-q", "origin", "stand-in"], in: world.clone)
        try await world.git(["replace", world.base, standIn], in: world.clone)
        // A post-checkout hook in the clone, and core.hooksPath naming a folder with another.
        let hook = "#!/bin/sh\n: > '\(markers.path)/hook-$$'\n"
        try ScratchNode.script(hook, at: world.clone.appendingPathComponent(".git/hooks/post-checkout"))
        let hooks = world.root.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try ScratchNode.script(hook, at: hooks.appendingPathComponent("post-checkout"))
        try await world.git(["config", "core.hooksPath", hooks.path], in: world.clone)
        // A smudge and clean filter in the test home's ~/.gitconfig, named by the commit's .gitattributes.
        try """
            [filter "marker"]
            \tsmudge = ": > '\(markers.path)/smudge'; cat"
            \tclean = ": > '\(markers.path)/clean'; cat"

            """.write(to: world.home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)

        let tree = try await world.git(["rev-parse", "\(world.base)^{tree}"], in: world.origin, replaceObjects: false)
        let replaced = try await world.git(["rev-parse", "\(world.base)^{tree}"], in: world.origin)
        #expect(tree != replaced, "the origin's replace ref doesn't change what git reads")
        let ran = try await world.install(try world.arguments(world.base, products: true))
        #expect(ran.status == 69, "\(ran.status) \(ran.errors)")
        #expect(ran.output.contains("checked out \(world.base) tree \(tree)\n"), "\(ran.output)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: markers.path).isEmpty, "a hook or filter ran")
    }

    /// The courtesy check reads nothing of `--repo`'s own git configuration (the security follow-ups' item 25): a clean
    /// filter, then a process filter, that its `.git/config` defines and its committed `.gitattributes` applies to every
    /// file never runs, though a file's stat changed so git compares its bytes. The check still passes a clean checkout
    /// (on to the link check, 69) and still refuses a changed file (65).
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func aFilterInTheCheckoutsOwnConfigNeverRuns() async throws {
        let world = try await world(extra: [".gitattributes": "* filter=marker\n"])
        let markers = world.root.appendingPathComponent("markers")
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        let version = world.clone.appendingPathComponent(".swift-version")
        let text = try String(contentsOf: version, encoding: .utf8)
        for (kind, other) in [("clean", "process"), ("process", "clean")] {
            try await world.git(["config", "filter.marker.\(kind)", ": > '\(markers.path)/\(kind)'; cat"], in: world.clone)
            _ = try? await run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", world.clone.path, "config", "--unset", "filter.marker.\(other)"],
                               environment: ["HOME": world.gitHome.path, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1",
                                             "GIT_CONFIG_GLOBAL": "/dev/null"])
            // The same bytes in a new file: its stat changed, so a diff reads it through the filter.
            try text.write(to: version, atomically: true, encoding: .utf8)
            // The fixture fires: a plain diff in the clone runs the filter.
            _ = try? await run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", world.clone.path, "diff", "--name-only", "HEAD", "--"],
                               environment: ["HOME": world.gitHome.path, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1",
                                             "GIT_CONFIG_GLOBAL": "/dev/null"])
            #expect(FileManager.default.fileExists(atPath: markers.appendingPathComponent(kind).path), "\(kind): the fixture's filter never ran")
            try FileManager.default.removeItem(at: markers)
            try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
            try text.write(to: version, atomically: true, encoding: .utf8)

            let ran = try await world.install(try world.arguments(world.base, products: true))
            #expect(ran.status == 69, "\(kind): \(ran.status) \(ran.errors)")
            #expect(try FileManager.default.contentsOfDirectory(atPath: markers.path).isEmpty, "\(kind): the checkout's own filter ran")
        }
        // A changed file is still found, and still nothing of the checkout's runs.
        try "0.0.0\n".write(to: version, atomically: true, encoding: .utf8)
        let changed = try await world.install(try world.arguments(world.base, products: true))
        #expect(changed.status == 65 && changed.errors.contains(".swift-version"), "\(changed.status) \(changed.errors)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: markers.path).isEmpty, "the checkout's own filter ran")
    }

    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func aBinaryWithARunpathIsRefused() async throws {
        let world = try await world()
        let ran = try await world.install(try world.arguments(world.base, products: true))
        #expect(ran.status == 69, "\(ran.status) \(ran.errors)")
        // The first product checked, and the entry: the toolchain's library folder.
        #expect(ran.errors.contains("vibeswitcher-host") && ran.errors.contains("RUNPATH"), "\(ran.errors)")
        #expect(ran.errors.contains("/usr/lib/swift/linux"), "\(ran.errors)")
        #expect(world.prefixIsEmpty)
    }

    /// The `NEEDED` set is exactly ST-D12's: a binary that needs less (`/usr/bin/true`: libc alone) or more
    /// (`/usr/bin/ls`: libselinux too) is refused, naming what's missing or extra. Each has the right interpreter and no
    /// RUNPATH, and every library it loads is root's.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func aBinaryWhoseNeededSetIsntExactIsRefused() async throws {
        let world = try await world()
        for (program, named) in [("/usr/bin/true", "libm.so.6"), ("/usr/bin/ls", "libselinux.so.1")] {
            let products = world.root.appendingPathComponent("products-" + (program as NSString).lastPathComponent)
            try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
            for name in ["vibeswitcher-host", "vibeswitcher-server", "vibeswitcher-cli", "vibeswitcher-hook", "vibeswitcher-mcp"] {
                try copyClosedOnExec(program, to: products.appendingPathComponent(name).path)
            }
            try Data((InstallTests.swift + "\n").utf8).write(to: products.appendingPathComponent("swift-version"))
            let ran = try await world.install(try world.arguments(world.base) + ["--test-products", products.path])
            #expect(ran.status == 69, "\(program): \(ran.status) \(ran.errors)")
            #expect(ran.errors.contains("vibeswitcher-host") && ran.errors.contains(named), "\(program): \(ran.errors)")
        }
        #expect(world.prefixIsEmpty)
    }
}

/// The install's static build (the start plan's S4c, ST-D11 and ST-D12): the static products S4c's spike built
/// (`VIBESWITCHER_STATIC_PRODUCTS=<that folder>` on the run's command line, skipped otherwise), installed by the script
/// into a scratch prefix and run from there; and the gated build itself, with the root toolchain M3 installs
/// (`VIBESWITCHER_INSTALL_TOOLCHAIN=/opt/swift-6.4.2`). Linux only, as the script's other cases.
extension InstallTests {
    /// The static products' folder (the five products by their build names, `swift-version`), as `--test-products`
    /// takes it: given on the run's command line, nil otherwise.
    static let staticProducts: URL? = ProcessInfo.processInfo.environment["VIBESWITCHER_STATIC_PRODUCTS"]
        .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
    static let staticBuilt: ConditionTrait = .enabled(if: staticProducts != nil, "the static products aren't built: S4c Step 1")
    /// M3's root toolchain, given on the run's command line and there.
    static let rootToolchain: String? = ProcessInfo.processInfo.environment["VIBESWITCHER_INSTALL_TOOLCHAIN"]
        .flatMap { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0 + "/usr/bin/swift") ? $0 : nil }

    /// The world's base commit installed from the static products: the world, the build folder and the run.
    fileprivate func staticInstall() async throws -> (world: InstallScript.World, build: URL, ran: CommandRun) {
        let world = try await world()
        let products = try #require(Self.staticProducts)
        let ran = try await world.install(try world.arguments(world.base) + ["--test-products", products.path])
        return (world, world.prefix.appendingPathComponent(world.base, isDirectory: true), ran)
    }

    /// What an install of `world.base` laid out under the prefix (`build` its folder), from the products whose
    /// `swift --version` output is `versionText`: the layout, `current`, `installs`, `build-info`, and where `vs-heavy`
    /// is found. `products`: the folder the programs came from, when they were given (`--test-products`).
    fileprivate func expectLaidOut(_ world: InstallScript.World, build: URL, versionText: String, products: URL?) throws {
        let files = FileManager.default
        let bin = build.appendingPathComponent("bin")
        #expect(Set(try files.contentsOfDirectory(atPath: bin.path)) == Set(BuildRecord.installedNames))
        let workingResources = InstallScript.workingCopy.appendingPathComponent("Resources/bin")
        let tools = try files.contentsOfDirectory(atPath: workingResources.path).filter { $0.hasPrefix("vs-") }
        #expect(Set(try files.contentsOfDirectory(atPath: build.appendingPathComponent("Resources/bin").path)) == Set(tools))
        var programs = BuildRecord.installedNames.map { bin.appendingPathComponent($0) }
        programs += tools.map { build.appendingPathComponent("Resources/bin/" + $0) } + [build.appendingPathComponent("Resources/install-node.sh")]
        for program in programs {
            var info = stat()
            #expect(lstat(program.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG, "\(program.path) isn't a regular file")
            #expect(info.st_mode & 0o7777 == 0o755, "\(program.path): mode \(String(info.st_mode & 0o7777, radix: 8))")
        }
        // The script and its libraries are the commit's, which is the working copy's here.
        for (installed, committed) in [("Resources/install-node.sh", "scripts/install-node.sh"), ("Resources/lib/scratch.sh", "scripts/lib/scratch.sh"),
                                       ("Resources/lib/swift-jobs.sh", "scripts/lib/swift-jobs.sh")] {
            #expect(files.contents(atPath: build.appendingPathComponent(installed).path)
                        == files.contents(atPath: InstallScript.workingCopy.appendingPathComponent(committed).path), "\(installed)")
        }
        // No .git anywhere under the prefix.
        let under = files.subpaths(atPath: world.prefix.path) ?? []
        #expect(!under.isEmpty && !under.contains { $0.split(separator: "/").contains(".git") }, "\(under.filter { $0.contains(".git") })")
        // current names the commit, and installs has its one line.
        #expect(try files.destinationOfSymbolicLink(atPath: world.prefix.appendingPathComponent("current").path) == world.base)
        let installs = try String(contentsOf: world.prefix.appendingPathComponent("installs"), encoding: .utf8)
        let lines = installs.split(separator: "\n")
        #expect(lines.count == 1 && lines.first?.hasPrefix(world.base + " ") == true, "\(installs)")

        let info = try BuildInfo.read(buildFolder: build.path).get()
        #expect(info.commit == world.base && info.commit == build.lastPathComponent)
        #expect(info.binaries.count == BuildRecord.installedNames.count)
        for name in BuildRecord.installedNames {
            let bytes = try Data(contentsOf: bin.appendingPathComponent(name))
            #expect(info.binaries[name] == BuildInfo.sha256(of: bytes), "\(name)")
            if let products {
                let built = name == NodeFolders.installedCLI ? "vibeswitcher-cli" : name
                #expect(bytes == (try Data(contentsOf: products.appendingPathComponent(built))), "\(name) isn't the product given")
            }
        }
        let resolved = try Data(contentsOf: InstallScript.workingCopy.appendingPathComponent("Package.resolved"))
        #expect(info.resolved == BuildInfo.sha256(of: resolved))
        #expect(info.swift == versionText.trimmingCharacters(in: .newlines), "\(info.swift)")
        // vs-heavy is found where TestLock looks: two folders up from the program, then Resources/bin.
        #expect(TestLock.commandFolder(besideExecutable: bin.appendingPathComponent("vibeswitcher-mcp").path)
                    == build.appendingPathComponent("Resources/bin").resolvingSymlinksInPath().path)
    }

    @Test(NodeTraits.linuxOnly, InstallTests.staticBuilt, .timeLimit(.minutes(10)))
    func aScratchInstallLaysOutTheBuildAndItsRecord() async throws {
        let (world, build, ran) = try await staticInstall()
        #expect(ran.status == 0, "\(ran.status) \(ran.errors)")
        #expect(ran.output.contains("the seal holds every team until `vs config accept`"), "\(ran.output)")
        let products = try #require(Self.staticProducts)
        let versionText = try String(contentsOf: products.appendingPathComponent("swift-version"), encoding: .utf8)
        try expectLaidOut(world, build: build, versionText: versionText, products: products)
    }

    @Test(NodeTraits.linuxOnly, InstallTests.staticBuilt, .timeLimit(.minutes(10)))
    func aHostStartsFromAnInstalledFolder() async throws {
        let (world, build, ran) = try await staticInstall()
        try #require(ran.status == 0, "\(ran.status) \(ran.errors)")
        // Its build-info check passed: the host's start line, said once both images matched it, names the commit.
        let host = try await InstalledHost(scratch, build: build)
        defer { host.end() }
        let started = await eventually(timeout: 120) { host.said.contains("vibeswitcher-host: started pid \(host.pid) build \(world.base) ") }
        #expect(started, "\(host.said)")

        // One byte changed in a copy of the installed server: refused, naming it, and the host ends.
        let copy = scratch.url("changed-server")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        let server = copy.appendingPathComponent(BuildInfo.server)
        var bytes = try Data(contentsOf: build.appendingPathComponent("bin/" + BuildInfo.server))
        bytes[bytes.count / 2] ^= 0x01
        try bytes.write(to: server)
        #expect(chmod(server.path, 0o755) == 0)
        let refused = try await InstalledHost(scratch, build: build, server: server)
        defer { refused.end() }
        let status = await offPool { refused.collected(by: MacTime.real.awake() + 120) }
        let raw = try #require(status, "the host with a changed server never ended: \(refused.said)")
        #expect(raw & 0x7f == 0 && (raw >> 8) & 0xff == 1, "status \(raw): \(refused.said)")
        #expect(refused.said.contains("not started: \(BuildInfo.server): its sha256"), "\(refused.said)")
        #expect(!refused.said.contains("started pid"), "\(refused.said)")
    }

    /// The maps half of S9's `anInstalledBinaryLoadsNothingFromAFolderTheUserCanWrite` (ST-D12; its `readelf` and
    /// loader half is the script's link check, which this install passed): the installed host (held dumpable), a
    /// session's launcher held after `beforeProgram` (the host's launchers' sealed copy, which stands for the parsers'
    /// copy of the same image) and `vibeswitcher-mcp` waiting on stdin map nothing but ST-D12's allowed lines, and the
    /// server's maps can't be read by its own uid (non-dumpable: `EACCES`, measured).
    @Test(NodeTraits.linuxOnly, InstallTests.staticBuilt, .timeLimit(.minutes(10)))
    func anInstalledBinaryLoadsNothingFromAFolderTheUserCanWrite() async throws {
        let (_, build, ran) = try await staticInstall()
        try #require(ran.status == 0, "\(ran.status) \(ran.errors)")
        let hold = try scratch.shortFolder("vsmh").appendingPathComponent("go")
        // HostImages.launcherTestHoldFlag and HostHardening.staysDumpableFlag (VibeHost's).
        let node = try await ScratchNode(scratch, build: build, hostArguments: ["--launcher-test-hold", hold.path, "--test-stays-dumpable"])
        defer {
            FileManager.default.createFile(atPath: hold.path, contents: nil)
            node.stop()
        }
        func maps(_ pid: pid_t) throws -> String { try String(contentsOfFile: "/proc/\(pid)/maps", encoding: .utf8) }

        // The host: dumpable by its test flag, so its maps can be read.
        try #require(Platform.Processes.isDumpable(node.hostPID) == true)
        let hostMaps = try maps(node.hostPID)
        #expect(Self.disallowedMaps(hostMaps, own: build.appendingPathComponent("bin/" + BuildInfo.host).path).isEmpty,
                "\(Self.disallowedMaps(hostMaps, own: build.appendingPathComponent("bin/" + BuildInfo.host).path))")
        #expect(hostMaps.contains(build.appendingPathComponent("bin/" + BuildInfo.host).path), "\(hostMaps)")

        // A session's launcher, held dumpable after beforeProgram, still running the launchers' copy.
        let session = try await node.spawn("exec sleep 600")
        defer { kill(session.childPID, SIGKILL) }
        #expect(await eventually { Platform.Processes.isDumpable(session.childPID) == true }, "\(node.said)")
        let exe = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(session.childPID)/exe")) ?? ""
        try #require(exe.hasPrefix("/memfd:"), "\(exe)")
        let launcherMaps = try maps(session.childPID)
        #expect(Self.disallowedMaps(launcherMaps, own: nil).isEmpty, "\(Self.disallowedMaps(launcherMaps, own: nil))")

        // The server: non-dumpable, its maps refused to this uid.
        #expect(await eventually { node.serverPID != nil }, "no server under the host")
        let server = try #require(node.serverPID)
        #expect(Platform.Processes.isDumpable(server) == false)
        let fd = Sys.open("/proc/\(server)/maps", O_RDONLY | O_CLOEXEC)
        let code = errno
        if fd >= 0 { Sys.close(fd) }
        #expect(fd < 0 && code == EACCES, "the server's maps: fd \(fd), errno \(code)")

        // vibeswitcher-mcp, waiting on stdin: in its read of fd 0, or the poll of its loop over stdin (the syscall
        // /proc names: 0 read, 7 poll, 271 ppoll).
        let mcp = build.appendingPathComponent("bin/" + "vibeswitcher-mcp").path
        var input: [Int32] = [-1, -1]
        try #require(Sys.pipeClosedOnExec(&input) == 0)
        defer { Sys.close(input[1]) }
        let work = scratch.url("mcp")
        try FileManager.default.createDirectory(at: work.appendingPathComponent("home"), withIntermediateDirectories: true)
        var spawn = Platform.Spawn(executable: mcp, arguments: [mcp, "--root", work.path])
        spawn.environment = ["HOME=\(work.appendingPathComponent("home").path)", "PATH=/usr/bin:/bin",
                             "VIBESWITCHER_HOME=\(work.appendingPathComponent("vibeswitcher").path)", "TMPDIR=\(work.path)/"]
        spawn.stdin = .descriptor(input[0])
        spawn.stdout = .path("/dev/null", flags: O_WRONLY)
        spawn.stderr = .path(work.appendingPathComponent("mcp.err").path, flags: O_WRONLY | O_CREAT | O_APPEND)
        let pid = try await startRetrying(spawn)
        Sys.close(input[0])
        defer { kill(pid, SIGKILL); _ = collected(pid, by: MacTime.real.awake() + 10) }
        let waiting = await eventually(timeout: 120) {
            let syscall = (try? String(contentsOfFile: "/proc/\(pid)/syscall", encoding: .utf8)) ?? ""
            return syscall.hasPrefix("0 0x0 ") || syscall.hasPrefix("7 ") || syscall.hasPrefix("271 ")
        }
        #expect(waiting, "vibeswitcher-mcp isn't reading stdin: \((try? String(contentsOfFile: "/proc/\(pid)/syscall", encoding: .utf8)) ?? "gone") \((try? String(contentsOf: work.appendingPathComponent("mcp.err"), encoding: .utf8)) ?? "")")
        let mcpMaps = try maps(pid)
        #expect(Self.disallowedMaps(mcpMaps, own: mcp).isEmpty, "\(Self.disallowedMaps(mcpMaps, own: mcp))")
    }

    /// A folder of hard links to the static products (copies where a link can't be made) and their `swift-version`, as
    /// `--test-products` takes it. A case swaps a file there only by a rename, never by a write into the link, so the
    /// spike's folder never changes.
    fileprivate func linkedStaticProducts(_ world: InstallScript.World) throws -> URL {
        let given = try #require(Self.staticProducts)
        let folder = world.root.appendingPathComponent("static-products")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["vibeswitcher-host", "vibeswitcher-server", "vibeswitcher-cli", "vibeswitcher-hook", "vibeswitcher-mcp", "swift-version"] {
            let source = given.appendingPathComponent(name).path, target = folder.appendingPathComponent(name).path
            if link(source, target) != 0 { try copyClosedOnExec(source, to: target) }
        }
        return folder
    }

    /// Each file's sha256 by its name, `sha256sum`'s (the products are too big to read whole here).
    fileprivate func sha256s(_ files: [URL]) async throws -> [String: String] {
        let ran = try await run(URL(fileURLWithPath: "/usr/bin/sha256sum"), files.map(\.path), environment: ["PATH": "/usr/bin:/bin"])
        try #require(ran.status == 0, "sha256sum: \(ran.status) \(ran.errors)")
        var hashes: [String: String] = [:]
        for line in ran.output.split(separator: "\n") {
            let words = line.split(separator: " ", maxSplits: 1)
            guard words.count == 2 else { continue }
            hashes[(String(words[1]).trimmingCharacters(in: CharacterSet(charactersIn: " *")) as NSString).lastPathComponent] = String(words[0])
        }
        return hashes
    }

    /// A command line that attests itself: run as `install-record FOLDER …`, it leaves `marker` and writes into FOLDER
    /// the `build-info` the real one would write for the products whose hashes (by build name) are `hashes`. Its text.
    fileprivate func forgingCLI(_ world: InstallScript.World, hashes: [String: String], products: URL, marker: URL) throws -> String {
        var binaries: [String: String] = [:]
        for name in BuildRecord.installedNames {
            binaries[name] = hashes[name == NodeFolders.installedCLI ? "vibeswitcher-cli" : name]
        }
        let swift = try String(contentsOf: products.appendingPathComponent("swift-version"), encoding: .utf8)
        let resolved = try Data(contentsOf: InstallScript.workingCopy.appendingPathComponent("Package.resolved"))
        let info = BuildInfo(commit: world.base, binaries: binaries, swift: swift.trimmingCharacters(in: .newlines),
                             resolved: BuildInfo.sha256(of: resolved))
        let forged = world.root.appendingPathComponent("forged-build-info")
        try info.encoded.write(to: forged)
        return "#!/bin/sh\n: > '\(marker.path)'\n/bin/cp '\(forged.path)' \"$2/build-info\"\n"
    }

    /// `text` as an executable script put in place of `file` by a rename: the old file (a link to the spike's product,
    /// say) is unlinked, never written.
    fileprivate func swapIn(_ text: String, for file: URL) throws {
        let swapped = file.deletingLastPathComponent().appendingPathComponent(".swapped-" + file.lastPathComponent)
        try ScratchNode.script(text, at: swapped)
        try #require(rename(swapped.path, file.path) == 0, "rename over \(file.path): errno \(errno)")
    }

    /// `world.base` installed from `products` with `--test-hold`: once the products are checked, `act` gets where the
    /// install is (`src`, `partial`, `bin`, from `checked.at`) and changes what a worker could there; then the install
    /// goes on. The run.
    fileprivate func heldInstall(_ world: InstallScript.World, products: URL,
                                 act: ([String: String]) throws -> Void) async throws -> CommandRun {
        let hold = world.root.appendingPathComponent("hold-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: hold, withIntermediateDirectories: true)
        let go = hold.appendingPathComponent("checked.go"), at = hold.appendingPathComponent("checked.at")
        try #require(mkfifo(go.path, 0o600) == 0, "mkfifo: errno \(errno)")
        let arguments = try world.arguments(world.base) + ["--test-products", products.path, "--test-hold", hold.path]
        async let installed = world.install(arguments, limit: 300)
        let held = await eventually(timeout: 240) { FileManager.default.fileExists(atPath: at.path) }
        var failure: Error?
        if held {
            do {
                var place: [String: String] = [:]
                for line in try String(contentsOf: at, encoding: .utf8).split(separator: "\n") {
                    guard let equals = line.firstIndex(of: "=") else { continue }
                    place[String(line[..<equals])] = String(line[line.index(after: equals)...])
                }
                try act(place)
            } catch { failure = error }
        }
        // Let it go on (it holds the FIFO open for reading and writing, so this open doesn't wait).
        let fd = Sys.open(go.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        if fd >= 0 {
            _ = "go\n".withCString { write(fd, $0, 3) }
            Sys.close(fd)
        }
        let ran = try await installed
        if let failure { throw failure }
        try #require(held, "the install never held: \(ran.status) \(ran.errors)")
        return ran
    }

    /// A product swapped in the products' folder after its check isn't what's installed (the security follow-ups'
    /// items 28 and 26): each product is read once, into the staging folder, and only that copy is checked and
    /// installed. Here the command line is swapped for one that attests itself (it writes the `build-info` the checked
    /// products would get): it never runs, and the installed command line is the checked one.
    @Test(NodeTraits.linuxOnly, InstallTests.staticBuilt, .timeLimit(.minutes(10)))
    func aProductSwappedAfterItsCheckIsNotWhatsInstalled() async throws {
        let world = try await world()
        let products = try linkedStaticProducts(world)
        let names = ["vibeswitcher-host", "vibeswitcher-server", "vibeswitcher-cli", "vibeswitcher-hook", "vibeswitcher-mcp"]
        let hashes = try await sha256s(names.map { products.appendingPathComponent($0) })
        let marker = world.root.appendingPathComponent("marker-forged")
        let forging = try forgingCLI(world, hashes: hashes, products: products, marker: marker)
        let ran = try await heldInstall(world, products: products) { _ in
            try swapIn(forging, for: products.appendingPathComponent("vibeswitcher-cli"))
        }
        #expect(ran.status == 0, "\(ran.status) \(ran.errors)")
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the swapped command line ran")
        let build = world.prefix.appendingPathComponent(world.base)
        let installed = try await sha256s([build.appendingPathComponent("bin/" + NodeFolders.installedCLI)])
        #expect(installed[NodeFolders.installedCLI] == hashes["vibeswitcher-cli"], "the installed command line isn't the checked one")
        let info = try BuildInfo.read(buildFolder: build.path).get()
        #expect(info.binaries[NodeFolders.installedCLI] == hashes["vibeswitcher-cli"])
    }

    /// A program in the staging folder changed after its check is refused before it runs (the security follow-ups'
    /// item 26): each copy is hashed again before the command line runs `install-record`, so a command line that
    /// attests itself (writing the `build-info` the checked products would get) never runs, and nothing is installed.
    @Test(NodeTraits.linuxOnly, InstallTests.staticBuilt, .timeLimit(.minutes(10)))
    func aStagedProgramChangedBeforeItRunsIsRefused() async throws {
        let world = try await world()
        let products = try linkedStaticProducts(world)
        let names = ["vibeswitcher-host", "vibeswitcher-server", "vibeswitcher-cli", "vibeswitcher-hook", "vibeswitcher-mcp"]
        let hashes = try await sha256s(names.map { products.appendingPathComponent($0) })
        let marker = world.root.appendingPathComponent("marker-forged")
        let forging = try forgingCLI(world, hashes: hashes, products: products, marker: marker)
        let ran = try await heldInstall(world, products: products) { place in
            let partial = try #require(place["partial"])
            try swapIn(forging, for: URL(fileURLWithPath: partial).appendingPathComponent("bin/" + NodeFolders.installedCLI))
        }
        #expect(ran.status == 1, "\(ran.status) \(ran.errors)")
        #expect(ran.errors.contains("bin/\(NodeFolders.installedCLI) changed since its check") && ran.errors.contains("refused before it runs"),
                "\(ran.errors)")
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the changed command line ran")
        #expect(world.prefixIsEmpty, "\((try? FileManager.default.contentsOfDirectory(atPath: world.prefix.path)) ?? [])")
    }

    /// A file planted in the build's checkout after its checkout, untracked or ignored, is refused before the layout
    /// (the security follow-ups' item 27): the re-check lists untracked and ignored files too.
    @Test(NodeTraits.linuxOnly, InstallTests.staticBuilt, .timeLimit(.minutes(10)))
    func aFilePlantedInTheBuildTreeIsRefused() async throws {
        let world = try await world(extra: [".gitignore": "*.o\n"])
        let products = try linkedStaticProducts(world)
        for planted in ["Sources/Planted.swift", "planted.o"] {
            let ran = try await heldInstall(world, products: products) { place in
                let file = URL(fileURLWithPath: try #require(place["src"])).appendingPathComponent(planted)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "planted\n".write(to: file, atomically: true, encoding: .utf8)
            }
            #expect(ran.status == 1, "\(planted): \(ran.status) \(ran.errors)")
            #expect(ran.errors.contains("changed since it was checked out") && ran.errors.contains(planted), "\(planted): \(ran.errors)")
            #expect(world.prefixIsEmpty, "\(planted): \((try? FileManager.default.contentsOfDirectory(atPath: world.prefix.path)) ?? [])")
        }
    }

    /// The gated build: the real build through the script, with M3's root toolchain, on a `git clone --no-local` of
    /// this repository with the working copy's script committed on top, a scratch prefix, the scratch origin and the
    /// stand-in `gh`. Every binary passes the link check, and the layout is the static case's. It adds to those only
    /// the root-owned toolchain and the build itself (minutes, under the run's `vs-heavy`; SwiftPM fetches the
    /// commit's dependencies from their own origins, as any build does).
    @Test(NodeTraits.linuxOnly, .enabled(if: InstallTests.rootToolchain != nil, "M3: the root toolchain isn't installed"), .timeLimit(.minutes(60)))
    func anInstallBuildsWithTheRootToolchain() async throws {
        let toolchain = try #require(Self.rootToolchain)
        let world = try await world(repository: InstallScript.workingCopy)
        // A cold release build of 406 steps (the spike's second run, 138 of them kept, took 236 s): 55 minutes, inside
        // the case's 60.
        let ran = try await world.install(try world.arguments(world.base) + ["--toolchain", toolchain], limit: 55 * 60)
        #expect(ran.status == 0, "\(ran.status) \(ran.errors)")
        // What install-record was given: the toolchain's `swift --version`, as the script runs it.
        let version = try await run(URL(fileURLWithPath: toolchain + "/usr/bin/swift"), ["--version"],
                                    environment: ["HOME": world.home.path, "PATH": "\(toolchain)/usr/bin:/usr/bin:/bin"])
        let versionText = version.output
        try expectLaidOut(world, build: world.prefix.appendingPathComponent(world.base, isDirectory: true), versionText: versionText, products: nil)
    }

    /// An install's run past its limit ends what the script started, not the script alone: the gated build's
    /// `vs-heavy` and `swift-build` (here a `sleep` the script left in the background) don't run on in a scratch
    /// folder the case removes. The limit is the caller's: the gated build's is minutes, not the default 120 s.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(2)))
    func anInstallPastItsLimitEndsWhatItStarted() async throws {
        let folder = scratch.url("past-limit")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("home"), withIntermediateDirectories: true)
        let recorded = folder.appendingPathComponent("background")
        let started = MacTime.real.awake()
        let ran = try await run(URL(fileURLWithPath: "/bin/bash"),
                                ["-c", "sleep 600 & echo $! > \(recorded.path); wait"],
                                environment: scratchEnvironment(folder), limit: 5, ownGroup: true)
        #expect(MacTime.real.awake() - started < 60, "the limit wasn't the caller's")
        #expect(ran.status != 0, "\(ran.status)")
        let text = try String(contentsOf: recorded, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let background = try #require(pid_t(text), "\(text)")
        #expect(Self.ended(background), "the script's background child \(background) runs on")
        if !Self.ended(background) { kill(background, SIGKILL) }
    }

    /// Whether `pid` has ended (gone, or a zombie its new parent hasn't collected yet), waiting up to 10 s.
    static func ended(_ pid: pid_t) -> Bool {
        let deadline = MacTime.real.awake() + 10
        while true {
            guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
                  let close = stat.lastIndex(of: ")") else { return true }
            if stat[stat.index(after: close)...].trimmingCharacters(in: .whitespaces).hasPrefix("Z") { return true }
            guard MacTime.real.awake() < deadline else { return false }
            usleep(20_000)
        }
    }

    /// The maps check names a file the user can write (a scratch file, a deleted file that isn't a sealed copy) and
    /// passes a root folder's file, the program's own file, the kernel's names, an anonymous mapping and a sealed copy.
    @Test func theMapsCheckNamesAFileTheUserCanWrite() throws {
        let folder = scratch.url("maps")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mine = folder.appendingPathComponent("libmine.so").path, own = folder.appendingPathComponent("vibeswitcher-mcp").path
        for path in [mine, own] { FileManager.default.createFile(atPath: path, contents: Data("x".utf8)) }
        let allowed = [
            "55a0c0000000-55a0c0100000 r-xp 00000000 08:20 1234                       \(own)",
            "7f0000000000-7f0000100000 r-xp 00000000 08:20 99                    /usr/bin/env",
            "7f0000100000-7f0000200000 rw-p 00000000 00:00 0                          [heap]",
            "7f0000200000-7f0000300000 rw-p 00000000 00:00 0 ",
            "7f0000300000-7f0000400000 r-xp 00000000 00:01 7                          /memfd:vibeswitcher-launcher (deleted)",
            "7ffd00000000-7ffd00100000 rw-p 00000000 00:00 0                          [stack]",
            "7ffd00100000-7ffd00102000 r--p 00000000 00:00 0                          [vvar]",
            "7ffd00102000-7ffd00104000 r-xp 00000000 00:00 0                          [vdso]",
        ]
        let refused = [
            "7f0000400000-7f0000500000 r-xp 00000000 08:20 4321                       \(mine)",
            "7f0000500000-7f0000600000 r-xp 00000000 08:20 4322                       /usr/bin/env (deleted)",
            "7f0000600000-7f0000700000 r-xp 00000000 08:20 4323                       [vsyscall-ish]",
        ]
        #expect(Self.disallowedMaps(allowed.joined(separator: "\n") + "\n", own: own).isEmpty, "\(Self.disallowedMaps(allowed.joined(separator: "\n"), own: own))")
        #expect(Self.disallowedMaps((allowed + refused).joined(separator: "\n"), own: own) == refused)
        // Without `own`, the program's own file is a file the user can write too.
        #expect(Self.disallowedMaps(allowed[0], own: nil) == [allowed[0]])
    }

    /// The lines of a `/proc/<pid>/maps` that aren't ST-D12's: each names a file whose folders up to `/` are root's
    /// and writable by nobody else (the file root's too), or is `[heap]`, `[stack]`, `[vdso]`, `[vvar]`, `[vsyscall]`,
    /// an anonymous mapping or a sealed copy (`/memfd:… (deleted)`). `own`, the program's own installed file (the
    /// image `execve` mapped, checked against `build-info`), is allowed besides.
    static func disallowedMaps(_ text: String, own: String?) -> [String] {
        text.split(separator: "\n").compactMap { line in
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            guard words.count > 5 else { return nil }
            let name = words.dropFirst(5).joined(separator: " ")
            if ["[heap]", "[stack]", "[vdso]", "[vsyscall]"].contains(name) || name.hasPrefix("[vvar") || name.hasPrefix("[anon:") { return nil }
            if name.hasPrefix("/memfd:"), name.hasSuffix(" (deleted)") { return nil }
            if name == own { return nil }
            if name.hasPrefix("/"), !name.hasSuffix(" (deleted)"), rootOnly(name) { return nil }
            return String(line)
        }
    }

    /// Whether `path` is root's, and every folder from it up to `/` root's and writable by nobody else.
    static func rootOnly(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == 0, info.st_mode & 0o022 == 0 else { return false }
        var folder = (path as NSString).deletingLastPathComponent
        while true {
            guard lstat(folder, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o022 == 0 else { return false }
            if folder == "/" { return true }
            folder = (folder as NSString).deletingLastPathComponent
        }
    }
}

/// A scratch host started from an installed build folder's `bin/vibeswitcher-host` (S4c): `DetachedScratch`'s command
/// line (a short root whose `home/.vibeswitcher` links to it, `--lock` in it, `--exit-with` this process, no `--node`)
/// with the installed folder as `--node-root` and `server` (its own server by default) as `--server`; HOME, PATH and
/// `SWIFT_BACKTRACE` as the unit gives them; what it says in `<root>/host.out`.
private final class InstalledHost: @unchecked Sendable {
    let root: URL
    let pid: pid_t
    private let lock = NSLock()
    /// Whether `collected(by:)` collected it: its pid is the kernel's again, so `end()` signals nothing.
    private var reaped = false

    init(_ scratch: Scratch, build: URL, server: URL? = nil) async throws {
        root = try scratch.shortFolder("vsih")
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent(".vibeswitcher").path, withDestinationPath: root.path)
        let out = root.appendingPathComponent("host.out").path
        FileManager.default.createFile(atPath: out, contents: nil)
        let host = build.appendingPathComponent("bin/" + BuildInfo.host).path
        let socket = home.appendingPathComponent(".vibeswitcher/host.sock").path, lock = root.appendingPathComponent(NodeCheck.scratchLock).path
        let arguments = [host, "--socket", socket, "--lock", lock, "--idle-exit", "600",
                         "--server", (server ?? build.appendingPathComponent("bin/" + BuildInfo.server)).path, "--node-root", build.path,
                         "--exit-with", String(getpid())]
        var spawn = Platform.Spawn(executable: host, arguments: arguments)
        spawn.environment = NodeStarter.detachedEnvironment(home: home.path, path: DetachedScratch.path)
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.stdout = .path(out, flags: O_WRONLY | O_APPEND)
        spawn.stderr = .path(out, flags: O_WRONLY | O_APPEND)
        spawn.keep = []
        pid = try await startRetrying(spawn)
    }

    var said: String { (try? String(contentsOf: root.appendingPathComponent("host.out"), encoding: .utf8)) ?? "" }

    /// Its status once it ends, by `deadline` (killed then, as `collected` does); nil if it never ended. Once collected
    /// its pid may name another process, so `end()` does nothing after.
    func collected(by deadline: TimeInterval) -> Int32? {
        let status = VibeNodeTests.collected(pid, by: deadline)
        if status != nil { lock.withLock { reaped = true } }
        return status
    }

    /// Ends it and what it started, whatever a case left; nothing once `collected(by:)` collected it (its pid released,
    /// what it started was reparented, so no signal here could still be sure of reaching its own).
    func end() {
        guard !lock.withLock({ reaped }) else { return }
        DetachedScratch.end(pid)
    }
}

/// `InstallTests`' fixture for `scripts/install-node.sh`: the synthetic repository, its origin, the clone and the
/// stand-in `gh`.
private enum InstallScript {
    /// The repository the script names, a constant in it (ST-D10).
    static let repository = "acastellana/vibeswitcher"
    static let workingCopy = packageFolder
    static let token = "stand-in-token"

    /// The account's home, as the script reads it (`getent passwd`), not this process's HOME.
    static func accountHome() -> String {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return "/nonexistent" }
        return String(cString: directory)
    }

    /// Whether this process could make `path` or write in it: true when its nearest existing folder (itself, once it
    /// exists) is writable.
    static func userCanCreateOrWrite(_ path: String) -> Bool {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        return access(url.path, W_OK) == 0
    }

    /// A git run with nothing of this process's environment or the user's git config: its output, trimmed.
    @discardableResult
    static func git(_ arguments: [String], in folder: URL, home: URL, replaceObjects: Bool = true, raw: Bool = false) async throws -> String {
        var environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        if !replaceObjects { environment["GIT_NO_REPLACE_OBJECTS"] = "1" }
        let ran = try await run(URL(fileURLWithPath: "/usr/bin/git"),
                                ["-c", "user.name=Install Test", "-c", "user.email=install@example.com", "-C", folder.path] + arguments,
                                environment: environment)
        #expect(ran.status == 0, "git \(arguments.joined(separator: " ")): \(ran.status) \(ran.errors)")
        return raw ? ran.output : ran.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The scratch world one case runs the script in.
    struct World {
        let root: URL
        let work: URL
        let origin: URL
        let clone: URL
        let standIn: URL
        let prefix: URL
        /// The first commit, on the origin's `v2`.
        let base: String

        var gitHome: URL { root.appendingPathComponent("git-home") }
        var home: URL { root.appendingPathComponent("home") }
        var gh: URL { standIn.appendingPathComponent("gh") }
        var script: URL { clone.appendingPathComponent("scripts/install-node.sh") }

        @discardableResult
        func git(_ arguments: [String], in folder: URL? = nil, replaceObjects: Bool = true, raw: Bool = false) async throws -> String {
            try await InstallScript.git(arguments, in: folder ?? work, home: gitHome, replaceObjects: replaceObjects, raw: raw)
        }

        /// `files` (path to text) written in the working repository and committed on its current branch: the commit.
        func commit(_ files: [String: String], message: String) async throws -> String {
            for (path, text) in files {
                let file = work.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: file, atomically: true, encoding: .utf8)
            }
            try await git(["add", "-A"])
            try await git(["commit", "-q", "--allow-empty", "-m", message])
            return try await git(["rev-parse", "HEAD"])
        }

        /// GitHub's answers for `commit`: the compare's status, and the runs `gh run list` lists.
        func answers(compare: String = "identical", runs: [[String: Any]]) throws {
            try Data(#"{"status":"\#(compare)"}"#.utf8).write(to: standIn.appendingPathComponent("compare.json"))
            try JSONSerialization.data(withJSONObject: runs).write(to: standIn.appendingPathComponent("runs.json"))
        }

        /// A run of `workflow` on `commit`, as `gh run list --json` gives it.
        static func ciRun(_ workflow: String, on commit: String, id: Int, status: String = "completed", conclusion: String = "success",
                          event: String = "push") -> [String: Any] {
            ["databaseId": id, "createdAt": "2026-11-16T10:00:\(String(format: "%02d", id % 60))Z", "workflowName": workflow, "headSha": commit,
             "status": status, "conclusion": conclusion, "event": event]
        }

        /// Both runners passed `commit`.
        func passing(_ commit: String) throws {
            try answers(runs: [Self.ciRun("v2 linux", on: commit, id: 10), Self.ciRun("v2 macos", on: commit, id: 11)])
        }

        /// The build's debug products (linked to, not copied) and a `swift-version`, as `--test-products` takes them.
        func debugProducts() throws -> URL {
            let folder = root.appendingPathComponent("products")
            guard !FileManager.default.fileExists(atPath: folder.path) else { return folder }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["vibeswitcher-host", "vibeswitcher-server", "vibeswitcher-cli", "vibeswitcher-hook", "vibeswitcher-mcp"] {
                let built = builtProducts.appendingPathComponent(name).path
                try #require(FileManager.default.isExecutableFile(atPath: built), "\(name) isn't built")
                let target = folder.appendingPathComponent(name).path
                if link(built, target) != 0 { try copyClosedOnExec(built, to: target) }
            }
            try Data((InstallTests.swift + "\n").utf8).write(to: folder.appendingPathComponent("swift-version"))
            return folder
        }

        /// The script's arguments for `commit`: the scratch prefix, the clone, the stand-in and the origin.
        func arguments(_ commit: String, products: Bool = false) throws -> [String] {
            var arguments = [commit, "--prefix", prefix.path, "--repo", clone.path, "--gh", gh.path, "--test-origin", "file://" + origin.path]
            if products { arguments += ["--test-products", try debugProducts().path] }
            return arguments
        }

        /// Runs `script` (the clone's by default) with `arguments` under bash, HOME the test's own home, in a process
        /// group of its own: past `limit` (120 s by default; the real build's are minutes) the group is ended, so a
        /// build's `vs-heavy` and `swift-build` don't run on after the script.
        func install(_ arguments: [String], script: URL? = nil, environment extra: [String: String] = [:],
                     limit: TimeInterval = 120) async throws -> CommandRun {
            try await run(URL(fileURLWithPath: "/bin/bash"), [(script ?? self.script).path] + arguments,
                          environment: scratchEnvironment(root, extra), limit: limit, ownGroup: true)
        }

        /// What the stand-in `gh` was called with: each call's arguments and environment.
        func calls() throws -> [(arguments: [String], environment: [String: String])] {
            let folder = standIn.appendingPathComponent("calls")
            return try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted().map { name in
                let call = folder.appendingPathComponent(name)
                let arguments = try String(contentsOf: call.appendingPathComponent("args"), encoding: .utf8).split(separator: "\n").map(String.init)
                var environment: [String: String] = [:]
                for line in try String(contentsOf: call.appendingPathComponent("env"), encoding: .utf8).split(separator: "\n") {
                    guard let equals = line.firstIndex(of: "=") else { continue }
                    environment[String(line[..<equals])] = String(line[line.index(after: equals)...])
                }
                return (arguments, environment)
            }
        }

        /// Whether anything is under the prefix.
        var prefixIsEmpty: Bool { ((try? FileManager.default.contentsOfDirectory(atPath: prefix.path)) ?? []).isEmpty }
    }
}
