import Foundation
import Testing

/// What a build is made of stays what was checked (the user's word of 2026-11-26: "we need to be careful here";
/// docs/process/v2-locked-versions.md says what is locked and what isn't):
/// - every `.package(` in Package.swift names its version `exact:`, and Package.resolved is tracked and pins each of
///   those packages at that version; but for one named by a path inside the repository (`.package(path: "Keeper")`,
///   the keeper's package), which is the commit's own files and gets no pin;
/// - every SwiftPM command in scripts/, Resources/bin and the workflows takes Package.resolved as it is
///   (`--only-use-versions-from-resolved-file`, given by `swiftpm_options` or on its line), so a stale lock file fails
///   the build instead of being re-resolved and rewritten; a command's words inside a message (a double-quoted string
///   outside a `$(…)`) and comments aren't commands;
/// - every download (a `curl` or `wget` that writes a file) is checked against its SHA-256 within the next three lines;
/// - every action a workflow uses is pinned by its commit (scripts/ci/check-workflows.sh's rule, run here, not restated);
/// - every workflow job that runs the tests checks its Swift against .swift-version and Node's major against
///   scripts/ci/checked-versions.txt (scripts/ci/check-versions.sh), and one checks Chrome's too, where the browser
///   checks run; a Mac job, on the image's Xcode, checks its Swift as well;
/// - a workflow that puts swiftly's bin on GITHUB_PATH also gives the steps after it SWIFTLY_HOME_DIR, SWIFTLY_BIN_DIR
///   and SWIFTLY_TOOLCHAINS_DIR (GITHUB_ENV): swiftly's `swift` finds its folder by them or by HOME, and scripts/test.sh
///   runs on a scratch HOME (v2 linux, platform, 1e377af0: a runner whose image lacked Swift 6.4.2 ran no Swift test).
/// A finding that is no such thing is listed in `allowed` with its reason; a listing that matches nothing fails.
struct DependencyLockLintTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Findings left as they are: the file, a piece of the line, and why.
    static let allowed: [(path: String, piece: String, reason: String)] = [
        ("scripts/e2e/wallet-e2e.sh", "requests.html", "the local wallet manager's page, read for a link; nothing fetched from outside, nothing run"),
        ("scripts/e2e/wallet-e2e.sh", "-o page.html", "the local wallet manager's signing page, read for its form; nothing fetched from outside, nothing run"),
        ("scripts/e2e/wallet-e2e.sh", "-o reply.html", "the local wallet manager's answer to the form, read; nothing fetched from outside, nothing run"),
    ]

    /// The options that make SwiftPM take Package.resolved as it is (one flag, three spellings), or the scripts' helper
    /// that gives it.
    static let locked = try! NSRegularExpression(pattern: #"\$\(swiftpm_options\)|--only-use-versions-from-resolved-file|--force-resolved-versions|--disable-automatic-resolution"#)
    static let swiftCommand = try! NSRegularExpression(pattern: #"(?<![\w-])swift\s+(build|test|run|package)\b"#)
    static let download = try! NSRegularExpression(pattern: #"(?<![\w-])(curl|wget)(\s|$)"#)
    static let checksum = try! NSRegularExpression(pattern: #"sha256sum\s+(-c|--check)|shasum\s+(-a\s*256\s+)?(-c|--check)"#)

    struct Finding: Equatable, CustomStringConvertible {
        var path: String, line: Int, text: String
        var description: String { "\(path):\(line): \(text)" }
    }

    // MARK: Reading

    /// `line` with what's inside double quotes blanked, but for a `$(…)` in them (a command, not a message's words):
    /// each blanked character a space for each of its UTF-16 units, so a match's position is the line's.
    static func code(_ line: String) -> String {
        var out = "", quoted = false, depth = 0, escaped = false, previous: Character = " "
        func keep(_ character: Character, _ kept: Bool) {
            if kept { out.append(character) } else { out += String(repeating: " ", count: character.utf16.count) }
        }
        for character in line {
            defer { previous = character }
            if escaped { escaped = false; keep(character, !quoted || depth > 0); continue }
            switch character {
            case "\\": escaped = true; keep(character, !quoted || depth > 0)
            case "(" where previous == "$": depth += 1; keep(character, true)
            case ")" where depth > 0: depth -= 1; keep(character, true)
            case "\"" where depth == 0: quoted.toggle(); keep(character, false)
            default: keep(character, !quoted || depth > 0)
            }
        }
        return out
    }

    /// `text`'s lines as the shell reads them, a line ending in `\\` joined to the next, each with its first line's number.
    static func logicalLines(_ text: String) -> [(line: Int, text: String)] {
        var found: [(line: Int, text: String)] = [], current = "", start = 0
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if current.isEmpty { start = index + 1 }
            if line.hasSuffix("\\") { current += line.dropLast() + " "; continue }
            found.append((start, current + line))
            current = ""
        }
        if !current.isEmpty { found.append((start, current)) }
        return found
    }

    static func matches(_ regex: NSRegularExpression, _ text: String) -> [NSTextCheckingResult] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// The lines of `text` (a script or a workflow) that run a SwiftPM command without the lock flag on the rest of
    /// their line.
    static func unlockedSwift(_ text: String) -> [(line: Int, text: String)] {
        logicalLines(text).compactMap { number, line in
            guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") else { return nil }
            for match in matches(swiftCommand, code(line)) {
                let rest = String(line.utf16.dropFirst(match.range.location)) ?? line
                if matches(locked, rest).isEmpty { return (number, line.trimmingCharacters(in: .whitespaces)) }
            }
            return nil
        }
    }

    /// Whether `line` (a `curl` or `wget`) writes a file: wget unless to standard output, curl with `-o FILE` (not
    /// /dev/null), `-O`, `--output` or `--remote-name`, a short flag group holding `o` or `O` included.
    static func writesAFile(_ line: String, tool: String) -> Bool {
        let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        if tool == "wget" { return !(words.contains("-O-") || words.contains("-qO-") || zip(words, words.dropFirst()).contains { $0 == "-O" && $1 == "-" }) }
        for (index, word) in words.enumerated() {
            if word == "--remote-name" || word == "--remote-name-all" { return true }
            let output = word == "--output" || (word.hasPrefix("-") && !word.hasPrefix("--") && word.dropFirst().last == "o")
            if output, index + 1 < words.count, words[index + 1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) != "/dev/null" { return true }
            if word.hasPrefix("--output=") { return !word.hasSuffix("/dev/null") }
            if word.hasPrefix("-"), !word.hasPrefix("--"), word.contains("O") { return true }
        }
        return false
    }

    /// The lines of `text` that download a file with no SHA-256 check in the three lines after.
    static func unchecked(_ text: String) -> [(line: Int, text: String)] {
        let lines = logicalLines(text)
        return lines.enumerated().compactMap { index, entry in
            let line = entry.text
            guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("#"),
                  let match = matches(download, code(line)).first, let range = Range(match.range(at: 1), in: line) else { return nil }
            guard writesAFile(line, tool: String(line[range])) else { return nil }
            let after = lines[(index + 1)..<min(lines.count, index + 4)].map(\.text).joined(separator: "\n")
            return matches(checksum, after).isEmpty ? (entry.line, line.trimmingCharacters(in: .whitespaces)) : nil
        }
    }

    /// The lines of `workflow` that put swiftly's bin on GITHUB_PATH without the three variables of swiftly's own
    /// folders in GITHUB_ENV in the six lines after.
    static func swiftlyWithoutItsFolders(_ workflow: String) -> [Int] {
        let lines = workflow.components(separatedBy: "\n")
        return lines.enumerated().compactMap { index, line in
            guard line.contains("swiftly/bin"), line.contains("GITHUB_PATH"), !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") else { return nil }
            let after = lines[(index + 1)..<min(lines.count, index + 7)].filter { $0.contains("GITHUB_ENV") }.joined(separator: "\n")
            let given = ["SWIFTLY_HOME_DIR=", "SWIFTLY_BIN_DIR=", "SWIFTLY_TOOLCHAINS_DIR="].allSatisfy { after.contains($0) }
            return given ? nil : index + 1
        }
    }

    /// Package.swift's packages: each `.package(` with its url and its exact version (nil: not `exact:`).
    static func packages(_ manifest: String) -> [(url: String, exact: String?, text: String)] {
        let package = try! NSRegularExpression(pattern: #"\.package\(([^)]*)\)"#)
        return matches(package, manifest).compactMap { match in
            guard let range = Range(match.range(at: 1), in: manifest) else { return nil }
            let inside = String(manifest[range])
            func value(_ key: String) -> String? {
                let regex = try! NSRegularExpression(pattern: key + #"\s*:\s*"([^"]+)""#)
                return matches(regex, inside).first.flatMap { Range($0.range(at: 1), in: inside) }.map { String(inside[$0]) }
            }
            return (value("url") ?? inside, value("exact"), inside)
        }
    }

    /// Package.resolved's pins: location (lower-cased, no `.git`) → version.
    static func pins(_ resolved: Data) -> [String: String] {
        guard let object = (try? JSONSerialization.jsonObject(with: resolved)) as? [String: Any],
              let pins = object["pins"] as? [[String: Any]] else { return [:] }
        var found: [String: String] = [:]
        for pin in pins {
            guard let location = pin["location"] as? String, let state = pin["state"] as? [String: Any], let version = state["version"] as? String else { continue }
            found[normalized(location)] = version
        }
        return found
    }

    static func normalized(_ url: String) -> String {
        let lower = url.lowercased()
        return lower.hasSuffix(".git") ? String(lower.dropLast(4)) : lower
    }

    /// Whether a `.package(`'s text names only a path inside the repository: relative, no `..`, nothing else said.
    static func inRepository(_ text: String) -> Bool {
        let path = try! NSRegularExpression(pattern: #"^\s*path\s*:\s*"([A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*)"\s*$"#)
        return !matches(path, text).isEmpty
    }

    /// What's wrong with `manifest` against `resolved`, one line each.
    static func lockProblems(manifest: String, resolved: Data?) -> [String] {
        var problems: [String] = []
        let pins = resolved.map(Self.pins) ?? [:]
        if resolved == nil { problems.append("Package.resolved isn't there") }
        let found = packages(manifest)
        if found.isEmpty { problems.append("Package.swift names no .package(") }
        for package in found {
            if inRepository(package.text) { continue }
            guard let exact = package.exact else {
                problems.append("\(package.url) isn't exact: (\(package.text.trimmingCharacters(in: .whitespaces)))")
                continue
            }
            guard let pinned = pins[normalized(package.url)] else {
                problems.append("\(package.url) \(exact) has no pin in Package.resolved")
                continue
            }
            if pinned != exact { problems.append("\(package.url): Package.swift says exact \(exact), Package.resolved pins \(pinned)") }
        }
        return problems
    }

    /// The version ranges scripts/ci/checked-versions.txt gives: tool → (low, high).
    static func ranges(_ text: String) -> [String: (Int, Int)] {
        var found: [String: (Int, Int)] = [:]
        for line in text.components(separatedBy: "\n") where !line.hasPrefix("#") {
            let words = line.split(separator: " ")
            let ends = words.count == 2 ? words[1].split(separator: "-").compactMap { Int($0) } : []
            if ends.count == 2, ends[0] <= ends[1] { found[String(words[0])] = (ends[0], ends[1]) }
        }
        return found
    }

    /// A workflow's jobs, each its lines from its `  name:` line on.
    static func jobs(_ workflow: String) -> [String] {
        var jobs: [String] = [], current: [String]?, inside = false
        for line in workflow.components(separatedBy: "\n") {
            if line == "jobs:" { inside = true; continue }
            guard inside else { continue }
            if line.range(of: #"^  [A-Za-z0-9_-]+:\s*$"#, options: .regularExpression) != nil {
                if let current { jobs.append(current.joined(separator: "\n")) }
                current = [line]
            } else if !line.isEmpty, !line.hasPrefix(" "), !line.hasPrefix("#") {
                break
            } else {
                current?.append(line)
            }
        }
        if let current { jobs.append(current.joined(separator: "\n")) }
        return jobs
    }

    /// The files read: tracked scripts and workflows (and Resources/bin's programs), with their text.
    static func scripts() throws -> [(path: String, text: String)] {
        let listed = try run("/usr/bin/env", ["git", "-C", repo.path, "ls-files", "scripts", "Resources/bin", ".github/workflows"])
        return listed.split(separator: "\n").map(String.init).filter { path in
            path.hasPrefix("Resources/bin/") || [".sh", ".bash", ".yml", ".yaml"].contains { path.hasSuffix($0) }
        }.compactMap { path in
            (try? String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)).map { (path, $0) }
        }
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:], expect status: Int32? = 0) throws -> String {
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardOutput = out
        process.standardError = out
        try process.run()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(waitForEnd(process), "\(executable) \(arguments) didn't end")
        if let status { #expect(process.terminationStatus == status, "\(executable) \(arguments): \(output)") }
        return output
    }

    // MARK: The rules on examples

    @Test func anUnlockedSwiftCommandIsFoundAndALockedOneIsnt() {
        #expect(Self.unlockedSwift("swift build -c release").map(\.line) == [1])
        #expect(Self.unlockedSwift("x\nBIN=\"$(swift build -c release --show-bin-path)\"").map(\.line) == [2])
        #expect(Self.unlockedSwift("vs-heavy bash -c 'swift test --filter X'").map(\.line) == [1])
        #expect(Self.unlockedSwift("swift package resolve").map(\.line) == [1])
        #expect(Self.unlockedSwift("swift build $(swiftpm_options) -c release").isEmpty)
        #expect(Self.unlockedSwift("swift build --only-use-versions-from-resolved-file").isEmpty)
        #expect(Self.unlockedSwift("BIN=\"$(swift build $(swiftpm_options) --show-bin-path)\"").isEmpty)
        #expect(Self.unlockedSwift("heavy_swift build").isEmpty, "heavy_swift gives swiftpm_options (checked below)")
        #expect(Self.unlockedSwift("echo \"run swift build --product x\"").isEmpty, "a message's words")
        #expect(Self.unlockedSwift("# swift build in a comment").isEmpty)
        #expect(Self.unlockedSwift("swift scripts/app-icon.swift iconset x").isEmpty, "a script, no package")
    }

    @Test func aDownloadWithNoChecksumIsFound() {
        #expect(Self.unchecked("curl -fsSLO https://example.com/tool.tar.gz\ntar zxf tool.tar.gz").map(\.line) == [1])
        #expect(Self.unchecked("wget https://example.com/tool.tar.gz").map(\.line) == [1])
        #expect(Self.unchecked("curl -fsSL -o tool.tgz https://example.com/t").map(\.line) == [1])
        #expect(Self.unchecked("curl -fsSLO https://example.com/t.tgz\necho \"abc  t.tgz\" | sha256sum -c -").isEmpty)
        #expect(Self.unchecked("curl -fsSL -o t.tgz https://x/t\nshasum -a 256 -c sums").isEmpty)
        #expect(Self.unchecked("reply=$(curl -sS --max-time 30 http://127.0.0.1:1/x)").isEmpty, "read, not written")
        #expect(Self.unchecked("curl -s -o /dev/null http://127.0.0.1:1/").isEmpty)
        #expect(Self.unchecked("echo \"curl -O is how\"").isEmpty, "a message's words")
    }

    @Test func swiftlyOnThePathWithoutItsFoldersIsFound() {
        let path = #"          echo "$HOME/.local/share/swiftly/bin" >> "$GITHUB_PATH""#
        #expect(Self.swiftlyWithoutItsFolders("x\n" + path + "\n      - name: Versions") == [2])
        #expect(Self.swiftlyWithoutItsFolders(path + "\n" + #"          echo "SWIFTLY_HOME_DIR=$HOME/.local/share/swiftly" >> "$GITHUB_ENV""#) == [1])
        let all = [path, "          # why", #"          echo "SWIFTLY_HOME_DIR=$HOME/.local/share/swiftly" >> "$GITHUB_ENV""#,
                   #"          echo "SWIFTLY_BIN_DIR=$HOME/.local/share/swiftly/bin" >> "$GITHUB_ENV""#,
                   #"          echo "SWIFTLY_TOOLCHAINS_DIR=$HOME/.local/share/swiftly/toolchains" >> "$GITHUB_ENV""#]
        #expect(Self.swiftlyWithoutItsFolders(all.joined(separator: "\n")).isEmpty)
    }

    @Test func aPackageThatIsntExactOrIsPinnedElsewhereIsFound() {
        let resolved = Data(#"{"pins":[{"location":"https://github.com/a/b.git","state":{"version":"1.2.3"}}]}"#.utf8)
        #expect(Self.lockProblems(manifest: #".package(url: "https://github.com/a/b.git", exact: "1.2.3")"#, resolved: resolved).isEmpty)
        #expect(Self.lockProblems(manifest: #".package(url: "https://github.com/a/b.git", exact: "1.2.3") .package(path: "Keeper")"#, resolved: resolved).isEmpty,
                "a path inside the repository")
        for outside in [#".package(path: "../Keeper")"#, #".package(path: "/opt/k")"#, #".package(path: "Keeper", traits: [])"#] {
            #expect(Self.lockProblems(manifest: outside, resolved: resolved).count == 1, "\(outside)")
        }
        #expect(Self.lockProblems(manifest: #".package(url: "https://github.com/a/b", exact: "1.2.3")"#, resolved: resolved).isEmpty, "with or without .git")
        #expect(Self.lockProblems(manifest: #".package(url: "https://github.com/a/b.git", from: "1.2.3")"#, resolved: resolved)
                == [#"https://github.com/a/b.git isn't exact: (url: "https://github.com/a/b.git", from: "1.2.3")"#])
        #expect(Self.lockProblems(manifest: #".package(url: "https://github.com/a/b.git", exact: "1.2.4")"#, resolved: resolved)
                == ["https://github.com/a/b.git: Package.swift says exact 1.2.4, Package.resolved pins 1.2.3"])
        #expect(Self.lockProblems(manifest: #".package(url: "https://github.com/c/d.git", exact: "1.0.0")"#, resolved: resolved)
                == ["https://github.com/c/d.git 1.0.0 has no pin in Package.resolved"])
        #expect(Self.lockProblems(manifest: #".package(url: "https://github.com/a/b.git", exact: "1.2.3")"#, resolved: nil)
                == ["Package.resolved isn't there", "https://github.com/a/b.git 1.2.3 has no pin in Package.resolved"])
    }

    /// The version check fails on a major it wasn't given (a stand-in `node` that says v26).
    @Test func aNodeMajorOutsideTheRangeFailsTheCheck() throws {
        let script = Self.repo.appendingPathComponent("scripts/ci/check-versions.sh").path
        let said = try Self.run("/bin/bash", [script, "node"], environment: ["NODE": "/bin/echo v26.1.0"], expect: 1)
        #expect(said.contains("major 26 isn't one the checks passed on"), "\(said)")
        let fine = try Self.run("/bin/bash", [script, "node"], environment: ["NODE": "/bin/echo v22.23.5"], expect: 0)
        #expect(fine.contains("majors 22 to"), "\(fine)")
    }

    // MARK: The repository

    @Test func everyPackageIsExactAndPinnedAndTheLockFileIsTracked() throws {
        let manifest = try String(contentsOf: Self.repo.appendingPathComponent("Package.swift"), encoding: .utf8)
        let resolved = try? Data(contentsOf: Self.repo.appendingPathComponent("Package.resolved"))
        #expect(Self.lockProblems(manifest: manifest, resolved: resolved) == [])
        try Self.run("/usr/bin/env", ["git", "-C", Self.repo.path, "ls-files", "--error-unmatch", "Package.resolved", ".swift-version"])
    }

    @Test func everySwiftPMCommandTakesTheLockFileAsItIs() throws {
        var found: [String] = []
        for (path, text) in try Self.scripts() {
            found += Self.unlockedSwift(text).map { Finding(path: path, line: $0.line, text: $0.text).description }
        }
        #expect(found.isEmpty, "a SwiftPM command that may re-resolve Package.resolved (give it $(swiftpm_options)): \(found)")
        // What the scripts' commands take: swiftpm_options gives the flag, and heavy_swift gives swiftpm_options.
        let jobs = try String(contentsOf: Self.repo.appendingPathComponent("scripts/lib/swift-jobs.sh"), encoding: .utf8)
        let options = jobs.components(separatedBy: "swiftpm_options() {").dropFirst().first?.components(separatedBy: "\n}").first ?? ""
        #expect(options.contains("echo --only-use-versions-from-resolved-file"), "swiftpm_options: \(options)")
        let heavy = jobs.components(separatedBy: "heavy_swift() {").dropFirst().first?.components(separatedBy: "\n}").first ?? ""
        #expect(heavy.components(separatedBy: #"swift "$verb" $(swiftpm_options)"#).count == 3, "heavy_swift: \(heavy)")
    }

    @Test func everyDownloadIsChecked() throws {
        var found: [Finding] = []
        for (path, text) in try Self.scripts() {
            found += Self.unchecked(text).map { Finding(path: path, line: $0.line, text: $0.text) }
        }
        let left = found.filter { finding in !Self.allowed.contains { $0.path == finding.path && finding.text.contains($0.piece) } }
        #expect(left.isEmpty, "a download with no SHA-256 check after it: \(left)")
        let stale = Self.allowed.filter { entry in !found.contains { $0.path == entry.path && $0.text.contains(entry.piece) } }
        #expect(stale.isEmpty, "allowed downloads that match nothing now: \(stale.map { "\($0.path): \($0.piece)" })")
    }

    @Test func everyActionIsPinnedByItsCommit() throws {
        let script = Self.repo.appendingPathComponent("scripts/ci/check-workflows.sh")
        try Self.run("/bin/bash", [script.path])
        // Its list of the actions allowed: each by a whole commit.
        let text = try String(contentsOf: script, encoding: .utf8)
        let list = text.components(separatedBy: "allowed_actions=(").dropFirst().first?.components(separatedBy: ")").first ?? ""
        let actions = list.split(separator: "\n").map { $0.split(separator: "#").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" }
            .filter { !$0.isEmpty }
        #expect(!actions.isEmpty)
        for action in actions {
            #expect(action.range(of: #"^"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}"$"#, options: .regularExpression) != nil, "\(action)")
        }
    }

    @Test func theWorkflowsCheckSwiftNodeAndChromeAndSwiftlysFolders() throws {
        let ranges = Self.ranges(try String(contentsOf: Self.repo.appendingPathComponent("scripts/ci/checked-versions.txt"), encoding: .utf8))
        #expect(ranges["node"] != nil && ranges["chrome"] != nil, "scripts/ci/checked-versions.txt: \(ranges.keys.sorted())")
        var chrome = false
        for (path, text) in try Self.scripts() where path.hasPrefix(".github/workflows/") {
            let runsTests = text.contains("scripts/test.sh") || text.contains("scripts/ci/macos-tests.sh")
            for job in Self.jobs(text) {
                if job.contains("scripts/test.sh") || job.contains("scripts/ci/macos-tests.sh") {
                    #expect(job.contains("bash scripts/ci/check-versions.sh swift node"),
                            "\(path): a job runs the tests without checking its Swift and Node's major: \(job.prefix(40))")
                }
                if job.contains("DEVELOPER_DIR=") {
                    #expect(job.contains("bash scripts/ci/check-versions.sh swift"), "\(path): a Mac job takes the image's Xcode without checking its Swift: \(job.prefix(40))")
                }
            }
            #expect(Self.swiftlyWithoutItsFolders(text).isEmpty,
                    "\(path): swiftly's bin on GITHUB_PATH, lines \(Self.swiftlyWithoutItsFolders(text)), without SWIFTLY_HOME_DIR, SWIFTLY_BIN_DIR and SWIFTLY_TOOLCHAINS_DIR in GITHUB_ENV")
            #expect(!runsTests || !text.contains("node --version"), "\(path): node --version alone, not checked against its range")
            chrome = chrome || text.contains("check-versions.sh swift node chrome")
        }
        #expect(chrome, "no workflow checks Chrome's major, where the browser checks run")
    }
}
