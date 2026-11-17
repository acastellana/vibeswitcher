import Foundation
import Testing
@testable import VibePlatform

/// Where the session sandbox's calls may be made (the session sandbox plan's SB1, Step 6), read from the source tree:
/// the namespace and mount calls only in the shim, `Platform.Sandbox.enter` only from a launcher, and the shim's
/// mutation switch never in a build.
struct SandboxLintTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The portable targets' sources: every one but the Mac app's.
    static func sources(_ extensions: Set<String>) -> [(path: String, text: String)] {
        let root = repo.appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var found: [(String, String)] = []
        for case let url as URL in walker where extensions.contains(url.pathExtension) {
            let path = String(url.path.dropFirst(repo.path.count + 1))
            guard !path.hasPrefix("Sources/VibeSwitcher/"), let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            found.append((path, text))
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

    @Test func onlyThePlatformCallsTheNamespaceAndMountCalls() {
        var found: [String] = []
        for (path, text) in Self.sources(["swift", "c", "h"]) where !Self.shim.contains(path) {
            for (number, line) in Self.code(text) where line.contains(Self.namespaceCall) { found.append("\(path):\(number): \(line)") }
        }
        #expect(found.isEmpty, "a namespace or mount call outside the shim: \(found)")
        // The lint sees one where there is one.
        #expect(Self.code("    if (fork() == 0) {").contains { $0.line.contains(Self.namespaceCall) })
        #expect(!Self.code("    sys_mount_setattr(fd)").contains { $0.line.contains(Self.namespaceCall) })
        #expect(!Self.code("    // unshare(CLONE_NEWUSER)").contains { $0.line.contains(Self.namespaceCall) })
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
        for folder in ["Package.swift", "Sources", "scripts", "Tests", ".github"] {
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
