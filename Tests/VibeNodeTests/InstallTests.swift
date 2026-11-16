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

extension InstallTests {
    /// `scripts/install-node.sh` (the start plan's S4b, ST-D8 to ST-D12), run whole on a synthetic repository: one commit
    /// of the working copy's script, its libraries, `Resources/bin/vs-*`, `.swift-version` and `Package.resolved`, in a
    /// scratch bare "origin" that serves a commit by its hash as GitHub does, a scratch clone as `--repo`, and a stand-in
    /// `gh` that answers from canned JSON and records each call's arguments and environment. Every run passes
    /// `--prefix <scratch>`, `--gh <stand-in>` and `--test-origin <scratch origin>`: nothing reaches GitHub, the user's
    /// token or the account's builds folder. The runs that get past CI pass the debug products (`--test-products`),
    /// which the link check refuses (RUNPATH into swiftly): the static products' cases are S4c's. Linux only: the
    /// script's tools (`readelf`, the loader's `--list`, `getent`) are Linux's.
    @Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(10)))
    struct Script {
        private let scratch = Scratch()

        /// The repository the script names, a constant in it (ST-D10).
        static let repository = "acastellana/vibeswitcher"
        static let workingCopy = packageFolder
        static let token = "stand-in-token"

        /// The account's home, as the script reads it (`getent passwd`), not this process's HOME.
        static func accountHome() -> String {
            guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return "/nonexistent" }
            return String(cString: directory)
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
                try await Script.git(arguments, in: folder ?? work, home: gitHome, replaceObjects: replaceObjects, raw: raw)
            }

            /// `files` (path to text) written in the working repository and committed on its current branch: the commit.
            func commit(_ files: [String: String], message: String) async throws -> String {
                for (path, text) in files {
                    let file = work.appendingPathComponent(path)
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try text.write(to: file, atomically: true, encoding: .utf8)
                }
                try await git(["add", "-A"])
                try await git(["commit", "-q", "-m", message])
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
                 "status": status, "conclusion": conclusion, "attempt": 1, "event": event]
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

            /// Runs `script` (the clone's by default) with `arguments` under bash, HOME the test's own home.
            func install(_ arguments: [String], script: URL? = nil, environment extra: [String: String] = [:]) async throws -> CommandRun {
                try await run(URL(fileURLWithPath: "/bin/bash"), [(script ?? self.script).path] + arguments,
                              environment: scratchEnvironment(root, extra))
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

        /// The world: the working repository's one commit (`extra` files beside the working copy's), pushed to a bare
        /// origin's `v2` that serves reachable commits by hash, its clone, the stand-in `gh` (answering that both runners
        /// passed the commit) and a prefix not yet made.
        func world(extra: [String: String] = [:]) async throws -> World {
            let root = scratch.url("install")
            let world = World(root: root, work: root.appendingPathComponent("work"), origin: root.appendingPathComponent("origin.git"),
                              clone: root.appendingPathComponent("clone"), standIn: root.appendingPathComponent("gh"),
                              prefix: root.appendingPathComponent("builds"), base: "")
            for folder in [world.work, world.gitHome, world.home, world.standIn.appendingPathComponent("calls")] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            var files = extra
            let copied = ["scripts/install-node.sh", ".swift-version", "Package.resolved"]
                + (try FileManager.default.contentsOfDirectory(atPath: Self.workingCopy.appendingPathComponent("scripts/lib").path))
                .filter { $0.hasSuffix(".sh") }.map { "scripts/lib/" + $0 }
                + (try FileManager.default.contentsOfDirectory(atPath: Self.workingCopy.appendingPathComponent("Resources/bin").path))
                .filter { $0.hasPrefix("vs-") }.map { "Resources/bin/" + $0 }
            for path in copied {
                files[path] = try String(contentsOf: Self.workingCopy.appendingPathComponent(path), encoding: .utf8)
            }
            try await world.git(["init", "-q", "-b", "v2"])
            let base = try await world.commit(files, message: "base")
            try await Self.git(["init", "-q", "--bare", world.origin.path], in: root, home: world.gitHome)
            try await world.git(["config", "uploadpack.allowReachableSHA1InWant", "true"], in: world.origin)
            try await world.git(["push", "-q", "file://" + world.origin.path, "v2:v2"])
            try await Self.git(["clone", "-q", "-b", "v2", "file://" + world.origin.path, world.clone.path], in: root, home: world.gitHome)
            try ScratchNode.script("""
                #!/bin/sh
                d='\(world.standIn.path)'
                c=$(/usr/bin/mktemp -d "$d/calls/call.XXXXXX") || exit 70
                printf '%s\\n' "$@" > "$c/args"
                /usr/bin/env > "$c/env"
                case "$1" in
                  auth) printf '%s\\n' '\(Self.token)' ;;
                  api) /bin/cat "$d/compare.json" ;;
                  run) /bin/cat "$d/runs.json" ;;
                  *) exit 1 ;;
                esac

                """, at: world.gh)
            let made = World(root: root, work: world.work, origin: world.origin, clone: world.clone, standIn: world.standIn,
                             prefix: world.prefix, base: base)
            try made.passing(base)
            return made
        }

        @Test func anInstallFromADirtyTreeIsRefused() async throws {
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

        @Test func aCommitNotOnOriginV2IsRefused() async throws {
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

            // And GitHub's compare saying anything but identical or ahead, for a commit git finds on v2.
            for status in ["diverged", "behind"] {
                try world.answers(compare: status, runs: [World.ciRun("v2 linux", on: world.base, id: 10), World.ciRun("v2 macos", on: world.base, id: 11)])
                let compared = try await world.install(try world.arguments(world.base, products: true))
                #expect(compared.status == 67, "\(status): \(compared.status) \(compared.errors)")
                #expect(compared.errors.contains(status), "\(compared.errors)")
            }
            #expect(world.prefixIsEmpty)
        }

        @Test func aCommitBothRunnersDidntPassIsRefused() async throws {
            let world = try await world()
            let commit = world.base
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

        @Test func ghRunsWithNothingFromTheUsersEnvironmentOrConfig() async throws {
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
            let account = Self.accountHome()
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
                #expect(call.environment["GH_TOKEN"] == Self.token)
                // HOME and GH_CONFIG_DIR: the script's own scratch folder, gone once it has ended.
                let home = try #require(call.environment["HOME"]), configDir = try #require(call.environment["GH_CONFIG_DIR"])
                for folder in [home, configDir] {
                    #expect(!folder.hasPrefix(world.home.path) && !folder.hasPrefix(account + "/"), "\(folder)")
                }
                #expect(URL(fileURLWithPath: home).deletingLastPathComponent() == URL(fileURLWithPath: configDir).deletingLastPathComponent())
                #expect(!FileManager.default.fileExists(atPath: home), "the scratch folder \(home) outlived the run")
                let named = zip(call.arguments, call.arguments.dropFirst()).contains { $0 == ("-R", Self.repository) }
                    || call.arguments.contains { $0.hasPrefix("repos/\(Self.repository)/") }
                #expect(named, "\(call.arguments)")
            }
            #expect(calls.filter { $0.arguments.first == "auth" }.count == 1)
            #expect(calls.contains { $0.arguments.starts(with: ["api", "repos/\(Self.repository)/compare/\(world.base)...v2"]) })
            #expect(calls.contains { $0.arguments.starts(with: ["run", "list", "-R", Self.repository, "--commit", world.base]) })
        }

        @Test func aToolchainTheUserCanWriteIsRefused() async throws {
            let world = try await world()
            var toolchains = [world.root.appendingPathComponent("toolchain").path]
            try FileManager.default.createDirectory(atPath: toolchains[0] + "/usr/bin", withIntermediateDirectories: true)
            let swiftly = Self.accountHome() + "/.local/share/swiftly"
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

        @Test func aFirstInstallRunsOnlyTheCommitsOwnScript() async throws {
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

        @Test func theNextInstallRunsThePreviousBuildsScript() async throws {
            let world = try await world()
            // The installed build: the base commit, laid out by hand; the next commit on v2 is what's installed now.
            let next = try await world.commit(["NEXT": "the next commit\n"], message: "next")
            try await world.git(["push", "-q", "file://" + world.origin.path, "v2:v2"])
            try await world.git(["pull", "-q"], in: world.clone)
            try world.passing(next)
            let installed = world.prefix.appendingPathComponent(world.base)
            let resources = installed.appendingPathComponent("Resources")
            try FileManager.default.createDirectory(at: resources.appendingPathComponent("lib"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: installed.appendingPathComponent("bin"), withIntermediateDirectories: true)
            let installedScript = try await world.git(["show", "\(world.base):scripts/install-node.sh"], in: world.clone, raw: true)
            try ScratchNode.script(installedScript, at: resources.appendingPathComponent("install-node.sh"))
            for name in ["scratch.sh", "swift-jobs.sh"] {
                let text = try await world.git(["show", "\(world.base):scripts/lib/\(name)"], in: world.clone, raw: true)
                try text.write(to: resources.appendingPathComponent("lib/\(name)"), atomically: true, encoding: .utf8)
            }
            try Data("cli".utf8).write(to: installed.appendingPathComponent("bin/vibeswitcher"))
            _ = try BuildRecord.write(folder: installed.path, commit: world.base, swiftVersionOutput: InstallTests.swift, resolved: InstallTests.resolved).get()
            try FileManager.default.createSymbolicLink(atPath: world.prefix.appendingPathComponent("current").path, withDestinationPath: world.base)
            let current = world.prefix.appendingPathComponent("current/Resources/install-node.sh")

            // The repository's script: refused, naming the installed copy.
            let fromRepository = try await world.install(try world.arguments(next, products: true))
            #expect(fromRepository.status == 66, "\(fromRepository.status) \(fromRepository.errors)")
            #expect(fromRepository.errors.contains(current.path), "\(fromRepository.errors)")

            // The installed copy: past provenance (against the installed commit's blobs), to the link check.
            let fromCurrent = try await world.install(try world.arguments(next, products: true), script: current)
            #expect(fromCurrent.status == 69, "\(fromCurrent.status) \(fromCurrent.errors)")
            #expect(fromCurrent.output.contains("checked out \(next) "), "\(fromCurrent.output)")

            // The installed copy changed: refused.
            try ScratchNode.script(installedScript + "# changed\n", at: resources.appendingPathComponent("install-node.sh"))
            let changed = try await world.install(try world.arguments(next, products: true), script: current)
            #expect(changed.status == 66, "\(changed.status) \(changed.errors)")
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: world.prefix.path)) == [world.base, "current"])
        }

        @Test func theTestFlagsNeedAScratchPrefix() async throws {
            let world = try await world()
            // A dirty --repo: were a prefix let through, the run would stop at the courtesy check (65), writing nothing.
            try "planted\n".write(to: world.clone.appendingPathComponent("planted"), atomically: true, encoding: .utf8)
            let origin = "file://" + world.origin.path
            let products = try world.debugProducts().path
            let flags = [["--gh", world.gh.path], ["--test-origin", origin], ["--test-products", products]]
            for flag in flags {
                let bare = try await world.install([world.base, "--repo", world.clone.path] + flag)
                #expect(bare.status == 64, "\(flag[0]) without --prefix: \(bare.status) \(bare.errors)")
                // With a scratch prefix, the same flag passes the arguments.
                let scratchPrefix = try await world.install([world.base, "--repo", world.clone.path, "--prefix", world.prefix.path] + flag)
                #expect(scratchPrefix.status == 65, "\(flag[0]) with a scratch prefix: \(scratchPrefix.status) \(scratchPrefix.errors)")
            }
            // The account's default prefix through a link to it, and a prefix inside the account's .vibeswitcher.
            let account = Self.accountHome()
            let link = world.root.appendingPathComponent("default-builds")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: account + "/.vibeswitcher/v2/builds")
            let inside = account + "/.vibeswitcher/v2/install-test-\(UUID().uuidString)"
            for prefix in [link.path, inside] {
                for flag in flags {
                    let refused = try await world.install([world.base, "--repo", world.clone.path, "--prefix", prefix] + flag)
                    #expect(refused.status == 64, "\(prefix) \(flag[0]): \(refused.status) \(refused.errors)")
                }
            }
            #expect(!FileManager.default.fileExists(atPath: inside))
            #expect(try world.calls().isEmpty)
        }

        @Test func nothingInTheUsersCloneOrConfigShapesTheBuild() async throws {
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

        @Test func aBinaryWithARunpathIsRefused() async throws {
            let world = try await world()
            let ran = try await world.install(try world.arguments(world.base, products: true))
            #expect(ran.status == 69, "\(ran.status) \(ran.errors)")
            // The first product checked, and the entry: the toolchain's library folder.
            #expect(ran.errors.contains("vibeswitcher-host") && ran.errors.contains("RUNPATH"), "\(ran.errors)")
            #expect(ran.errors.contains("/usr/lib/swift/linux"), "\(ran.errors)")
            #expect(!FileManager.default.fileExists(atPath: world.prefix.path))
        }
    }
}
