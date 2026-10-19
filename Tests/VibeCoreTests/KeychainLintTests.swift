import Foundation
import Testing

/// No test reaches the real Keychain unless asked to (VIBESWITCHER_KEYCHAIN_LIVE=1). 2026-10-19: every worker's and
/// verifier's `swift test` runs with HOME and CFFIXED_USER_HOME on a scratch folder, where there's no login keychain,
/// and macOS answered each SecItem call for the app's key with "Keychain Not Found: a keychain cannot be found to
/// store "app"" (Cancel / Reset To Defaults) in the user's face, dozens of times an hour.
struct KeychainLintTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Each Swift file under `folder` (relative to the repository), by its path there, with its lines of code
    /// (comments left out).
    static func code(in folder: String) -> [(path: String, lines: [String])] {
        let root = repo.appendingPathComponent(folder)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return files.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }.map { file in
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let lines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            return (String(file.path.dropFirst(repo.path.count + 1)), lines)
        }
    }

    static func files(in folder: String, matching pattern: String) -> [String] {
        let regex = try! Regex(pattern)
        return code(in: folder).filter { $0.lines.contains { $0.contains(regex) } }.map(\.path)
    }

    /// The Keychain is called from two places only: the app's key store and the host's vault key.
    @Test func onlyTheKeyStoresCallTheKeychain() {
        #expect(Self.files(in: "Sources", matching: #"\bSec(Item|Keychain)\w*\("#)
            == ["Sources/VibeCore/LeadVaultAppProof.swift", "Sources/VibeHost/VaultStorage.swift"])
    }

    /// The app's Keychain store is made by the app alone (its one client); every other client, a default one too, has
    /// its own key or none. The host's vault key is read only by the user's own host (`ownsLaunchers`).
    @Test func onlyTheAppMakesItsKeychainStore() throws {
        #expect(Self.files(in: "Sources", matching: #"KeychainStore\("#) == ["Sources/VibeSwitcher/AppDelegate.swift"])
        let host = try #require(Self.code(in: "Sources").first { $0.path == "Sources/VibeSwitcher/HostClient.swift" })
        #expect(host.lines.contains { $0.contains("appKey: @escaping () -> SymmetricKey? = { nil }") })
        #expect(Self.files(in: "Sources", matching: #"VaultStorage\.keychainKey\("#) == ["Sources/vibeswitcher-host/main.swift"])
        let main = try #require(Self.code(in: "Sources").first { $0.path == "Sources/vibeswitcher-host/main.swift" })
        #expect(main.lines.filter { $0.contains("VaultStorage.keychainKey(") }.allSatisfy { $0.contains("ownsLaunchers ?") })
    }

    /// In the tests, only the live test touches the Keychain or the app's store, and it runs only when asked for.
    @Test func onlyTheGatedLiveTestReachesTheKeychain() throws {
        let reaching = Self.files(in: "Tests", matching: #"\bSec(Item|Keychain)\w*\(|KeychainStore\(|VaultStorage\.keychainKey\(|removeKeychainKey\(|AppDelegate\("#)
        #expect(reaching.filter { !$0.hasSuffix("/KeychainLintTests.swift") } == ["Tests/VibeCoreTests/KeychainLiveTests.swift"])
        let live = try #require(Self.code(in: "Tests").first { $0.path.hasSuffix("/KeychainLiveTests.swift") }).lines
        let gate = try #require(live.firstIndex { $0.hasPrefix("@Suite(.enabled(if: ProcessInfo.processInfo.environment[\"VIBESWITCHER_KEYCHAIN_LIVE\"] == \"1\"))") })
        let firstTest = try #require(live.firstIndex { $0.contains("@Test") })
        let firstType = try #require(live.firstIndex { $0.hasPrefix("struct ") || $0.hasPrefix("final class ") || $0.hasPrefix("enum ") || $0.hasPrefix("extension ") })
        // The gate is on the file's one suite, which holds every test.
        #expect(gate + 1 == firstType && firstType < firstTest)
        #expect(live.filter { $0.hasPrefix("struct ") || $0.hasPrefix("final class ") || $0.hasPrefix("enum ") || $0.hasPrefix("extension ") }.count == 1)
    }

    /// A host a test starts has a lock of its own: on the user's lock (the default) it's the user's host, which reads
    /// its vault key from the Keychain.
    @Test func everyHostATestStartsHasItsOwnLock() {
        for file in Self.code(in: "Tests") where !file.path.hasSuffix("/KeychainLintTests.swift") {
            for line in file.lines where line.contains(#""--socket""#) {
                #expect(line.contains(#""--lock""#), "\(file.path): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    /// Nothing sets the live gate but you: not the load harness, not the lead's worker and verifier prompts.
    @Test func nothingButYouSetsTheLiveGate() throws {
        for folder in ["Sources", "scripts"] {
            let root = Self.repo.appendingPathComponent(folder)
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
            for file in files {
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                #expect(!text.contains("VIBESWITCHER_KEYCHAIN_LIVE"), "\(file.path)")
            }
        }
        let readme = try String(contentsOf: Self.repo.appendingPathComponent("README.md"), encoding: .utf8)
        #expect(readme.contains("VIBESWITCHER_KEYCHAIN_LIVE=1"))
    }
}
