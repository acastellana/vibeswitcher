import Foundation
import Testing

/// The keeper's package (docs/superpowers/specs/2026-11-27-v2-mac-keeper-design.md, "Its program", slice K0): root
/// builds `Keeper/` from the commit's own objects with nothing fetched, so the less it names the less there is to
/// review. Read from the source tree, as the other lints are:
/// - `Keeper/Package.swift` names no package (no `.package(`, no product of another package, no binary or system
///   library, no plugin, no flag or setting a build could be steered by), and its sources import only Foundation,
///   Security and the C library;
/// - its program, `vibeswitcher-keeper`, links `VibeKeep` alone, and `VibeKeep` links nothing;
/// - the repository's package names it by path, in the Mac's half and in the Linux half, and `VibePlatform` and
///   `VibeCore` take `VibeKeep` from it (each moved part has one implementation).
struct KeeperLintTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let keeper = repo.appendingPathComponent("Keeper")

    /// The modules the keeper's sources may import: Foundation, Security and the C library.
    static let allowedImports: Set<String> = ["Foundation", "Security", "Darwin", "Glibc", "Musl"]
    /// What would let the keeper's manifest take something from outside its folder, or steer its build.
    static let forbiddenInManifest = [".package(", ".product(", "binaryTarget", "systemLibrary", ".plugin(", "plugins:",
                                      "unsafeFlags", "linkerSettings", "swiftSettings", "cSettings", "cxxSettings",
                                      "pkgConfig", "providers:", "Context.", "ProcessInfo", "#if"]

    // MARK: Reading

    /// `text` without its comments (`//` to the line's end and `/* … */`), so a rule reads code, not words about it;
    /// each string literal's contents kept (`strings`) or blanked.
    static func code(_ text: String, strings: Bool = true) -> String {
        var out = "", index = text.startIndex, quoted = false
        while index < text.endIndex {
            let rest = text[index...]
            if quoted {
                if rest.hasPrefix("\\"), text.index(after: index) < text.endIndex {
                    out += strings ? String(text[index...text.index(after: index)]) : "  "
                    index = text.index(index, offsetBy: 2)
                    continue
                }
                if rest.hasPrefix("\"") { quoted = false }
                out.append(strings || !quoted || text[index] == "\n" ? text[index] : " ")
                index = text.index(after: index)
            } else if rest.hasPrefix("//") {
                index = text[index...].firstIndex(of: "\n") ?? text.endIndex
            } else if rest.hasPrefix("/*") {
                index = text[index...].range(of: "*/")?.upperBound ?? text.endIndex
            } else {
                if rest.hasPrefix("\"") { quoted = true }
                out.append(text[index])
                index = text.index(after: index)
            }
        }
        return out
    }

    /// The modules `text`'s import declarations name (the first part of each: `import struct Foundation.Data` names
    /// Foundation), whatever attributes come before them.
    static func imports(_ text: String) -> [String] {
        let declaration = try! NSRegularExpression(
            pattern: #"^\s*(?:@[\w]+(?:\([^)]*\))?\s+)*import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?([A-Za-z_]\w*)"#,
            options: [.anchorsMatchLines])
        let code = code(text, strings: false)
        return declaration.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap {
            Range($0.range(at: 1), in: code).map { String(code[$0]) }
        }
    }

    /// Every file below `folder`, by its path from the repository.
    static func files(below folder: URL) -> [String] {
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return walk.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { String($0.standardizedFileURL.path.dropFirst(repo.standardizedFileURL.path.count + 1)) }
            .filter { !$0.hasPrefix("Keeper/.build/") && !$0.hasPrefix("Keeper/.swiftpm/") }
            .sorted()
    }

    /// The calls to `function` in `code` (`.executableTarget(`), each its text between the parentheses, string
    /// literals and nested parentheses kept whole.
    static func calls(_ function: String, in code: String) -> [String] {
        var found: [String] = [], search = code.startIndex
        while let start = code.range(of: function + "(", range: search..<code.endIndex) {
            var depth = 1, index = start.upperBound, quoted = false
            while index < code.endIndex, depth > 0 {
                let character = code[index]
                if quoted {
                    if character == "\\" { index = code.index(after: index) } else if character == "\"" { quoted = false }
                } else if character == "\"" {
                    quoted = true
                } else if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth -= 1
                }
                if index < code.endIndex { index = code.index(after: index) }
            }
            found.append(String(code[start.upperBound..<code.index(before: index)]))
            search = index
        }
        return found
    }

    /// The value of `name: "…"` in a call's text.
    static func name(_ call: String) -> String? {
        let pattern = try! NSRegularExpression(pattern: #"^\s*name\s*:\s*"([^"]*)""#)
        return pattern.firstMatch(in: call, range: NSRange(call.startIndex..., in: call)).flatMap { Range($0.range(at: 1), in: call) }
            .map { String(call[$0]) }
    }

    /// What `key: [ … ]` lists in a call's text, each element as written (a quoted name's contents, else the element's
    /// words); nil when the call doesn't say `key:`.
    static func list(_ key: String, in call: String) -> [String]? {
        guard let start = call.range(of: #"\b\#(key)\s*:\s*\["#, options: .regularExpression) else { return nil }
        var depth = 0, quoted = false, end: String.Index?
        for index in call[start.upperBound...].indices {
            let character = call[index]
            if quoted { if character == "\"" { quoted = false }; continue }
            if character == "\"" { quoted = true } else if character == "(" || character == "[" { depth += 1 } else if character == ")" { depth -= 1 }
            else if character == "]" { if depth == 0 { end = index; break }; depth -= 1 }
        }
        guard let end else { return nil }
        return elements(String(call[start.upperBound..<end])).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix("\"") && $0.hasSuffix("\"") && $0.count >= 2 ? String($0.dropFirst().dropLast()) : $0 }
    }

    /// `text` split at its top-level commas (none inside parentheses, brackets or a string).
    static func elements(_ text: String) -> [String] {
        var found: [String] = [], current = "", depth = 0, quoted = false
        for character in text {
            if quoted {
                if character == "\"" { quoted = false }
            } else if character == "\"" {
                quoted = true
            } else if character == "(" || character == "[" {
                depth += 1
            } else if character == ")" || character == "]" {
                depth -= 1
            } else if character == ",", depth == 0 {
                found.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        found.append(current)
        return found
    }

    // MARK: The rules, as text (each test below runs them on the tree; `theRulesKnowAGoodPackageFromABadOne` on samples)

    /// What's wrong with a keeper manifest `manifest` and its sources (`sources`: path → text), one line each.
    static func dependencyProblems(manifest: String?, sources: [String: String]) -> [String] {
        guard let manifest else { return ["Keeper/Package.swift isn't there"] }
        var problems: [String] = []
        let code = code(manifest)
        for word in forbiddenInManifest where code.contains(word) { problems.append("Keeper/Package.swift says \(word)") }
        for module in imports(manifest) where module != "PackageDescription" {
            problems.append("Keeper/Package.swift imports \(module)")
        }
        let swift = sources.keys.filter { $0.hasPrefix("Keeper/Sources/") }
        if swift.isEmpty { problems.append("Keeper/Sources holds no source") }
        for path in sources.keys.sorted() {
            guard path.hasPrefix("Keeper/Sources/") else { continue }
            guard path.hasSuffix(".swift") else { problems.append("\(path): not Swift (a C or other target would be another thing to review)"); continue }
            let target = path.split(separator: "/").dropFirst(2).first.map(String.init) ?? ""
            let allowed = target == "vibeswitcher-keeper" ? allowedImports.union(["VibeKeep"]) : allowedImports
            for module in imports(sources[path]!) where !allowed.contains(module) { problems.append("\(path) imports \(module)") }
        }
        return problems
    }

    /// What's wrong with how the keeper's manifest links its targets, one line each: exactly `VibeKeep` (a library
    /// target naming nothing) and `vibeswitcher-keeper` (an executable naming `VibeKeep` alone), each its own product,
    /// and any test target naming only them.
    static func linkProblems(manifest: String?) -> [String] {
        guard let manifest else { return ["Keeper/Package.swift isn't there"] }
        let code = code(manifest)
        var problems: [String] = []
        let libraries = calls(".target", in: code), executables = calls(".executableTarget", in: code), tests = calls(".testTarget", in: code)
        for kind in [".macro(", ".plugin(", ".binaryTarget(", ".systemLibrary("] where code.contains(kind) {
            problems.append("Keeper/Package.swift has a \(kind.dropFirst().dropLast()) target")
        }
        if libraries.map(name) != ["VibeKeep"] { problems.append("its library targets are \(libraries.map { name($0) ?? "?" }), not [VibeKeep]") }
        if let library = libraries.first, let named = list("dependencies", in: library), !named.isEmpty {
            problems.append("VibeKeep names \(named)")
        }
        if executables.map(name) != ["vibeswitcher-keeper"] {
            problems.append("its executable targets are \(executables.map { name($0) ?? "?" }), not [vibeswitcher-keeper]")
        }
        if let program = executables.first, list("dependencies", in: program) != ["VibeKeep"] {
            problems.append("vibeswitcher-keeper links \(list("dependencies", in: program) ?? []), not [VibeKeep] alone")
        }
        for test in tests {
            let named = list("dependencies", in: test) ?? []
            if !named.allSatisfy(["VibeKeep", "vibeswitcher-keeper"].contains) { problems.append("\(name(test) ?? "a test target") names \(named)") }
        }
        let products = calls(".library", in: code), programs = calls(".executable", in: code)
        if products.map(name) != ["VibeKeep"] || products.first.flatMap({ list("targets", in: $0) }) != ["VibeKeep"] {
            problems.append("its library products aren't VibeKeep of [VibeKeep] alone")
        }
        if programs.map(name) != ["vibeswitcher-keeper"] || programs.first.flatMap({ list("targets", in: $0) }) != ["vibeswitcher-keeper"] {
            problems.append("its executable products aren't vibeswitcher-keeper of [vibeswitcher-keeper] alone")
        }
        return problems
    }

    /// What's wrong with how the repository's `manifest` names the keeper, one line each: in each half (Linux's, then
    /// the Mac's: the `#if os(Linux)` and its `#else`), the package by path and `VibePlatform` and `VibeCore` taking
    /// `VibeKeep` from it.
    static func repositoryProblems(manifest: String) -> [String] {
        let code = code(manifest)
        guard let linux = code.range(of: "#if os(Linux)"), let mac = code.range(of: "\n#else", range: linux.upperBound..<code.endIndex) else {
            return ["Package.swift has no Linux half and Mac half"]
        }
        let halves = [("the Linux half", String(code[linux.upperBound..<mac.lowerBound])), ("the Mac's half", String(code[mac.upperBound...]))]
        let shared = String(code[..<linux.lowerBound])
        let byPath = #".package(path: "Keeper")"#
        let product = #".product(name: "VibeKeep", package: "Keeper")"#
        // A constant set before the halves (as `crypto` is) counts by its name.
        func names(_ value: String) -> [String] {
            let pattern = try! NSRegularExpression(pattern: #"let\s+(\w+)\s*(?::\s*[\w.]+)?\s*=\s*"# + NSRegularExpression.escapedPattern(for: value))
            return pattern.matches(in: shared, range: NSRange(shared.startIndex..., in: shared)).compactMap { Range($0.range(at: 1), in: shared) }
                .map { String(shared[$0]) }
        }
        var problems: [String] = []
        for (half, text) in halves {
            let packages = calls("Package", in: text).compactMap { list("dependencies", in: $0) }.first ?? []
            if !packages.contains(where: { $0 == byPath || names(byPath).contains($0) }) {
                problems.append("\(half) doesn't name the keeper's package by path (\(byPath))")
            }
            for target in ["VibePlatform", "VibeCore"] {
                guard let call = calls(".target", in: text).first(where: { name($0) == target }) else {
                    problems.append("\(half) has no \(target)")
                    continue
                }
                let named = list("dependencies", in: call) ?? []
                if !named.contains(where: { $0 == product || names(product).contains($0) }) {
                    problems.append("\(half)'s \(target) doesn't take VibeKeep from the keeper's package")
                }
            }
        }
        return problems
    }

    static func read(_ path: String) -> String? { try? String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8) }

    static func keeperSources() -> [String: String] {
        Dictionary(uniqueKeysWithValues: files(below: keeper.appendingPathComponent("Sources")).map { ($0, read($0) ?? "") })
    }

    // MARK: The tree

    @Test func theKeeperPackageNamesNoDependency() {
        #expect(Self.dependencyProblems(manifest: Self.read("Keeper/Package.swift"), sources: Self.keeperSources()) == [])
    }

    @Test func theKeeperLinksOnlyVibeKeep() {
        #expect(Self.linkProblems(manifest: Self.read("Keeper/Package.swift")) == [])
        // Its program's own sources take nothing but VibeKeep beyond the allowed modules (dependencyProblems' rule),
        // and there is one.
        #expect(Self.keeperSources().keys.contains { $0.hasPrefix("Keeper/Sources/vibeswitcher-keeper/") })
    }

    @Test func theRepositoryNamesTheKeeperByPathInBothHalves() throws {
        #expect(Self.repositoryProblems(manifest: try #require(Self.read("Package.swift"))) == [])
    }

    // MARK: The rules on samples

    static let goodManifest = """
        // swift-tools-version:6.0
        import PackageDescription

        // A comment may say .package( or #if or unsafeFlags: it isn't code.
        let package = Package(
            name: "Keeper",
            platforms: [.macOS(.v14)],
            products: [
                .library(name: "VibeKeep", targets: ["VibeKeep"]),
                .executable(name: "vibeswitcher-keeper", targets: ["vibeswitcher-keeper"]),
            ],
            targets: [
                .target(name: "VibeKeep"),
                .executableTarget(name: "vibeswitcher-keeper", dependencies: ["VibeKeep"]),
            ],
            swiftLanguageModes: [.v5]
        )
        """
    static let goodSources = [
        "Keeper/Sources/VibeKeep/A.swift": "import Foundation\n#if canImport(Security)\nimport Security\n#endif\n// import Network\n",
        "Keeper/Sources/VibeKeep/B.swift": "#if canImport(Glibc)\nimport Glibc\n#endif\n@preconcurrency import Darwin\nlet s = \"import Network\"\n",
        "Keeper/Sources/vibeswitcher-keeper/main.swift": "import Foundation\nimport VibeKeep\n",
    ]

    @Test func theRulesKnowAGoodPackageFromABadOne() {
        #expect(Self.dependencyProblems(manifest: Self.goodManifest, sources: Self.goodSources) == [])
        #expect(Self.linkProblems(manifest: Self.goodManifest) == [])
        #expect(Self.dependencyProblems(manifest: nil, sources: [:]) == ["Keeper/Package.swift isn't there"])
        #expect(Self.linkProblems(manifest: nil) == ["Keeper/Package.swift isn't there"])

        // A package named, by url or by path, at the package's level or as a target's product.
        let fetched = Self.goodManifest.replacingOccurrences(of: "platforms:", with: #"dependencies: [.package(url: "https://example.com/a.git", exact: "1.0.0")], platforms:"#)
        #expect(Self.dependencyProblems(manifest: fetched, sources: Self.goodSources).contains("Keeper/Package.swift says .package("))
        let product = Self.goodManifest.replacingOccurrences(of: #"dependencies: ["VibeKeep"]"#, with: #"dependencies: ["VibeKeep", .product(name: "A", package: "a")]"#)
        #expect(Self.dependencyProblems(manifest: product, sources: Self.goodSources).contains("Keeper/Package.swift says .product("))
        #expect(Self.linkProblems(manifest: product).contains { $0.hasPrefix("vibeswitcher-keeper links") })
        for word in ["unsafeFlags", "linkerSettings", "plugins:", "Context."] {
            let steered = Self.goodManifest.replacingOccurrences(of: ".target(name: \"VibeKeep\")", with: ".target(name: \"VibeKeep\", x: \(word))")
            #expect(Self.dependencyProblems(manifest: steered, sources: Self.goodSources).contains("Keeper/Package.swift says \(word)"), "\(word)")
        }

        // A source importing anything else, however it says it.
        for line in ["import VibePlatform", "@testable import VibeCore", "import struct Network.NWEndpoint", "  @_exported import Dispatch", "import CVibePlatform"] {
            var sources = Self.goodSources
            sources["Keeper/Sources/VibeKeep/C.swift"] = "import Foundation\n\(line)\n"
            let module = line.split(separator: " ").last!.split(separator: ".").first!
            #expect(Self.dependencyProblems(manifest: Self.goodManifest, sources: sources) == ["Keeper/Sources/VibeKeep/C.swift imports \(module)"], "\(line)")
        }
        var library = Self.goodSources
        library["Keeper/Sources/VibeKeep/D.swift"] = "import VibeKeep\n"
        #expect(Self.dependencyProblems(manifest: Self.goodManifest, sources: library) == ["Keeper/Sources/VibeKeep/D.swift imports VibeKeep"])
        var c = Self.goodSources
        c["Keeper/Sources/CKeep/shim.c"] = "#include <stdio.h>\n"
        #expect(Self.dependencyProblems(manifest: Self.goodManifest, sources: c).count == 1)

        // The program linking more than VibeKeep, or another target appearing.
        let more = Self.goodManifest.replacingOccurrences(of: #".executableTarget(name: "vibeswitcher-keeper", dependencies: ["VibeKeep"])"#,
                                                          with: #".executableTarget(name: "vibeswitcher-keeper", dependencies: ["VibeKeep", "Other"]), .target(name: "Other")"#)
        #expect(Self.linkProblems(manifest: more).count == 2, "\(Self.linkProblems(manifest: more))")
        let none = Self.goodManifest.replacingOccurrences(of: #", dependencies: ["VibeKeep"]"#, with: "")
        #expect(Self.linkProblems(manifest: none) == ["vibeswitcher-keeper links [], not [VibeKeep] alone"])
        let linked = Self.goodManifest.replacingOccurrences(of: #".target(name: "VibeKeep")"#, with: #".target(name: "VibeKeep", dependencies: ["Z"])"#)
        #expect(Self.linkProblems(manifest: linked) == [#"VibeKeep names ["Z"]"#])
    }

    @Test func theRepositoryRuleNeedsBothHalves() {
        let half = """
            let package = Package(name: "V", dependencies: [keeper, .package(url: "u", exact: "1")], targets: [
                .target(name: "VibePlatform", dependencies: [vibeKeep]),
                .target(name: "VibeCore", dependencies: ["VibePlatform", .product(name: "VibeKeep", package: "Keeper")]),
            ])
            """
        let shared = """
            let keeper: Package.Dependency = .package(path: "Keeper")
            let vibeKeep: Target.Dependency = .product(name: "VibeKeep", package: "Keeper")

            """
        let both = shared + "#if os(Linux)\n" + half + "\n#else\n" + half + "\n#endif\n"
        #expect(Self.repositoryProblems(manifest: both) == [])
        let macOnly = shared + "#if os(Linux)\n" + half.replacingOccurrences(of: "[keeper, ", with: "[") + "\n#else\n" + half + "\n#endif\n"
        #expect(Self.repositoryProblems(manifest: macOnly) == [#"the Linux half doesn't name the keeper's package by path (.package(path: "Keeper"))"#])
        let core = shared + "#if os(Linux)\n" + half + "\n#else\n" + half.replacingOccurrences(of: #", .product(name: "VibeKeep", package: "Keeper")"#, with: "") + "\n#endif\n"
        #expect(Self.repositoryProblems(manifest: core) == ["the Mac's half's VibeCore doesn't take VibeKeep from the keeper's package"])
    }
}
