import Foundation
import Testing

/// Outside the platform layer, no file of the targets that build on every system imports the C library or an
/// Apple-only framework, or asks which system it is on: what differs between systems is in Sources/VibePlatform, and
/// what only the Mac has in Sources/VibeCore/MacOnly. The files that still break the rule are listed in
/// PlatformLintPending.txt, one path a line; a file leaves the list in the change that cleans it, and the list only
/// gets shorter.
struct PlatformLintTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The portable targets' folders.
    static let folders = ["Sources/VibeCore", "Sources/VibeHost", "Sources/vibeswitcher-host", "Sources/vibeswitcher-hook",
                          "Sources/vibeswitcher-mcp"]
    /// The Mac's own files, each wrapped whole in `#if canImport(Darwin)`.
    static let macOnly = "Sources/VibeCore/MacOnly/"
    /// VibeCore's one file of exported imports: the platform layer, and what a system names differently.
    static let exempt: Set<String> = ["Sources/VibeCore/PlatformExport.swift"]

    /// A word ends at a "." too (`import IOKit.ps`), which Regex's own word boundary doesn't hold.
    static let systemImport = try! Regex(#"^\s*(@_exported\s+)?import\s+(Darwin|Glibc|Musl|CryptoKit|Security|Network|CoreGraphics|ImageIO|UniformTypeIdentifiers|AppKit|SwiftUI|Combine|IOKit)\b"#)
        .wordBoundaryKind(.simple)
    static let systemCondition = try! Regex(#"^\s*#(if|elseif)\s+.*\b(os|canImport)\("#).wordBoundaryKind(.simple)

    /// Whether `line` is code only the platform layer may have.
    static func breaksTheRule(_ line: String) -> Bool {
        line.contains(systemImport) || line.contains(systemCondition)
    }

    /// Each Swift file the rule covers, by its path in the repository, with the lines that break it ("12: import Darwin").
    static func files() -> [(path: String, violations: [String])] {
        var found: [(path: String, violations: [String])] = []
        for folder in folders {
            for file in (FileManager.default.subpaths(atPath: repo.appendingPathComponent(folder).path) ?? []).sorted() where file.hasSuffix(".swift") {
                let path = "\(folder)/\(file)"
                guard !path.hasPrefix(macOnly), !exempt.contains(path),
                      let text = try? String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8) else { continue }
                let violations = text.components(separatedBy: "\n").enumerated()
                    .filter { breaksTheRule($0.element) }
                    .map { "\($0.offset + 1): \($0.element.trimmingCharacters(in: .whitespaces))" }
                found.append((path, violations))
            }
        }
        return found
    }

    /// PlatformLintPending.txt's paths, in its order.
    static func pending() throws -> [String] {
        let list = try String(contentsOf: repo.appendingPathComponent("Tests/VibePlatformTests/PlatformLintPending.txt"), encoding: .utf8)
        return list.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    @Test func noSystemCodeOutsideThePlatform() throws {
        let files = Self.files()
        #expect(files.contains { $0.path == "Sources/VibeCore/Paths.swift" }, "the rule's folders weren't read")
        let pending = Set(try Self.pending())
        let breaking = files.filter { !$0.violations.isEmpty && !pending.contains($0.path) }
            .flatMap { file in file.violations.map { "\(file.path):\($0)" } }
        #expect(breaking == [], """
            system code outside the platform layer: call it through VibePlatform (Sources/VibePlatform), or move what \
            only the Mac has to Sources/VibeCore/MacOnly:
            \(breaking.joined(separator: "\n"))
            """)
    }

    @Test func thePendingListHoldsOnlyFilesThatStillBreakTheRule() throws {
        let pending = try Self.pending()
        let breaking = Set(Self.files().filter { !$0.violations.isEmpty }.map(\.path))
        let clean = pending.filter { !breaking.contains($0) }
        #expect(clean == [], """
            listed in Tests/VibePlatformTests/PlatformLintPending.txt and not breaking the rule (cleaned, moved or \
            gone): take the line out:
            \(clean.joined(separator: "\n"))
            """)
        #expect(pending == Set(pending).sorted(), "PlatformLintPending.txt is sorted, each path once")
    }

    @Test func theRuleKnowsSystemCodeFromTheRest() {
        for line in ["import Darwin", "import Glibc", "  import Musl", "@_exported import CryptoKit", "import Security", "import Network",
                     "import CoreGraphics", "import ImageIO", "import UniformTypeIdentifiers", "import AppKit", "import SwiftUI",
                     "import Combine", "import IOKit.ps", "#if os(Linux)", "    #if canImport(Darwin)", "#elseif canImport(Glibc)",
                     "#if DEBUG && os(macOS)", "#if !canImport(Darwin)"] {
            #expect(Self.breaksTheRule(line), "\(line)")
        }
        for line in ["import Foundation", "import Dispatch", "import VibeCore", "import SwiftTerm", "@_exported import VibePlatform",
                     "import NetworkExtras", "// import Darwin", "let text = \"import Darwin\"", "#if DEBUG", "#else", "#endif",
                     "if Platform.canImport(x) {}"] {
            #expect(!Self.breaksTheRule(line), "\(line)")
        }
    }
}
