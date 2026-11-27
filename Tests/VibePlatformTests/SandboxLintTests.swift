import Foundation
import Testing
@testable import VibePlatform

/// Where the session sandbox's calls may be made (the session sandbox plan's SB1, Step 6), read from the source tree:
/// the namespace and mount calls only in the shim, `Platform.Sandbox.enter` only from a launcher, and the shim's
/// mutation switch never in a build.
struct SandboxLintTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The portable targets' sources: every one but the Mac app's, and the keeper's package's (`Keeper/Sources`, slice
    /// K0's), in the repository or in `tree`, a test's.
    static func sources(_ extensions: Set<String>, tree: URL = repo) -> [(path: String, text: String)] {
        var found: [(String, String)] = []
        for folder in ["Sources", "Keeper/Sources"] {
            let root = tree.appendingPathComponent(folder)
            // Relative to the folder as the walk gives them (a test's tree under a linked TMPDIR is walked resolved).
            guard let walker = FileManager.default.enumerator(atPath: root.path) else { continue }
            for case let relative as String in walker where extensions.contains((relative as NSString).pathExtension) {
                let url = root.appendingPathComponent(relative)
                let path = "\(folder)/\(relative)"
                guard !path.hasPrefix("Sources/VibeSwitcher/"), let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                found.append((path, text))
            }
        }
        return found.sorted { $0.0 < $1.0 }
    }

    /// The lines of `text` that aren't only a comment.
    static func code(_ text: String) -> [(number: Int, line: String)] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") ? nil : (index + 1, String(line))
        }
    }

    /// A call to one of the namespace or mount calls (`unshare(`, `fork(`, `clone(`, `mount(`, …), not a longer
    /// name ending in one (`sys_mount(`, `vibe_fork(`).
    static let namespaceCall = try! Regex(#"(^|[^A-Za-z0-9_.])(unshare|fork|vfork|clone|clone3|mount|umount2?|pivot_root|setns|open_tree|move_mount|fsopen|fsmount|mount_setattr)\("#)

    /// The only files that may make them: the shim's box.
    static let shim: Set<String> = ["Sources/CVibePlatform/shim_sandbox.c"]

    /// Each namespace or mount call outside the shim in the sources of `tree` (the repository, or a test's), as
    /// "PATH:LINE: the line".
    static func namespaceCalls(tree: URL = repo) -> [String] {
        var found: [String] = []
        for (path, text) in sources(["swift", "c", "h"], tree: tree) where !shim.contains(path) {
            for (number, line) in code(text) where line.contains(namespaceCall) { found.append("\(path):\(number): \(line)") }
        }
        return found
    }

    @Test func onlyThePlatformCallsTheNamespaceAndMountCalls() {
        let found = Self.namespaceCalls()
        #expect(Self.sources(["swift"]).contains { $0.path == "Keeper/Sources/VibeKeep/Keep.swift" }, "the keeper's package wasn't read")
        #expect(found.isEmpty, "a namespace or mount call outside the shim: \(found)")
        // The lint sees one where there is one.
        #expect(Self.code("    if (fork() == 0) {").contains { $0.line.contains(Self.namespaceCall) })
        #expect(!Self.code("    sys_mount_setattr(fd)").contains { $0.line.contains(Self.namespaceCall) })
        #expect(!Self.code("    // unshare(CLONE_NEWUSER)").contains { $0.line.contains(Self.namespaceCall) })
    }

    /// The keeper's package is read: a `fork(` planted in a sample tree's `Keeper/Sources` is found by the same scan.
    @Test func theKeepersSourcesAreCovered() throws {
        let tree = try TestScriptLinuxTests.scratch("sandbox-keeper")
        defer { try? FileManager.default.removeItem(at: tree) }
        let planted = tree.appendingPathComponent("Keeper/Sources/VibeKeep/Planted.swift")
        try FileManager.default.createDirectory(at: planted.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "import Foundation\nif fork() == 0 { _exit(0) }\n".write(to: planted, atomically: true, encoding: .utf8)
        #expect(Self.namespaceCalls(tree: tree) == ["Keeper/Sources/VibeKeep/Planted.swift:2: if fork() == 0 { _exit(0) }"])
    }

    /// The launchers, each a fresh process with one thread whose first statements enter its plan: the session's
    /// launcher (SB3) and a branch run's (SB6). No other file may call `Platform.Sandbox.enter`.
    static let launchers: Set<String> = ["Sources/VibeHost/V2/SessionSandbox.swift", "Sources/VibeCore/V2/Sandbox/BranchRun.swift"]

    @Test func enterIsCalledOnlyFromALaunchersFirstStatements() {
        var found: [String] = []
        for (path, text) in Self.sources(["swift"]) where !path.hasPrefix("Sources/VibePlatform/") && !Self.launchers.contains(path) {
            for (number, line) in Self.code(text) where line.contains("Sandbox.enter(") { found.append("\(path):\(number)") }
        }
        #expect(found.isEmpty, "Platform.Sandbox.enter outside a launcher: \(found)")
    }

    /// The mutation switch (shim_sandbox.c's `VIBE_SANDBOX_MUTATION`, which lets a test run skip a step) is named
    /// only by the shim, the mutation script, this lint and the docs: never by the package, a build script or a test
    /// target's settings.
    @Test func theShimsMutationSwitchIsNeverBuilt() throws {
        let allowed: Set<String> = ["Sources/CVibePlatform/shim_sandbox.c", "scripts/sandbox-mutation.sh",
                                    "Tests/VibePlatformTests/SandboxLintTests.swift"]
        var listed: [String] = []
        for folder in ["Package.swift", "Sources", "Keeper", "scripts", "Tests", ".github"] {
            let url = Self.repo.appendingPathComponent(folder)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            let files = isFolder.boolValue
                ? (FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []) : [url]
            for file in files {
                guard let text = try? String(contentsOf: file, encoding: .utf8), text.contains("VIBE_SANDBOX_MUTATION") else { continue }
                listed.append(String(file.path.dropFirst(Self.repo.path.count + 1)))
            }
        }
        let named = listed.filter { !allowed.contains($0) }
        #expect(named.isEmpty, "the mutation switch named in \(named)")
        #expect(listed.contains("Sources/CVibePlatform/shim_sandbox.c"))
        // The shim reads its skip variable only under the switch.
        let shim = try String(contentsOf: Self.repo.appendingPathComponent("Sources/CVibePlatform/shim_sandbox.c"), encoding: .utf8)
        let uses = shim.components(separatedBy: "getenv(\"VIBE_SANDBOX_SKIP\")").count - 1
        #expect(uses == 1)
        let guarded = shim.range(of: "#ifdef VIBE_SANDBOX_MUTATION").map { shim[$0.upperBound...] }
        #expect(guarded.map { $0.prefix(400).contains("getenv(\"VIBE_SANDBOX_SKIP\")") } == true)
    }
}
