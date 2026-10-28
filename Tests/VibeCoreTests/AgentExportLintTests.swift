import Foundation
import Testing

/// No script or test under scripts/ or Tests/ writes a git tree out into the worktree with its agent files: AGENTS.md,
/// CLAUDE*.md, .claude/ and .mcp.json. The lead's audit (Worktrees.localAgentConfig) counts each one a worktree holds
/// uncommitted, git-ignored folders included, as the worker's own instructions, and its verifier starts on a trust
/// question. 2026-10-28: ui-bench.sh's base export (.build/ui-bench-base/COMMIT) and UpgradeFromLeadHostTests' old-host
/// build (.build/old-hosts/COMMIT/work-*/src) held a commit's AGENTS.md and CLAUDE.md, and a verifier was held on them.
/// The scan stays strict; the writers keep them out.
///
/// An export is a line that extracts an archive (tar -x, unzip, ditto -x) or checks a tree out (git clone, worktree add,
/// checkout-index, --work-tree). Each excludes the agent files on the same statement (all four names in it), or writes
/// into a scratch folder outside the worktree:
/// - a script: its destination (tar's -C, unzip's -d, checkout-index's --prefix, --work-tree, a worktree's path, else
///   the last argument) is under $tool_scratch (scripts/lib/scratch.sh), $TMPDIR, /tmp, a `mktemp` folder, or a
///   variable only ever set from one;
/// - a Swift, Python or JavaScript test: the file never locates this checkout (#filePath, #file, the current directory,
///   __file__, import.meta): its git calls run in the scratch repositories it makes, under its scratch folder.
struct AgentExportLintTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let this = "Tests/VibeCoreTests/AgentExportLintTests.swift"
    let temp = Scratch()

    /// Where a shell command starts: a line's start, after `;`, `&`, `|`, `(` or `$(`, or a keyword. "run git clone" in
    /// a message isn't one.
    static let start = #"(^|[;&|(]|\b(then|do|else|exec|command|env|time|xcrun))\s*"#
    /// A shell command: tar -x (or tar x), unzip, ditto -x, git clone, checkout-index, worktree add or --work-tree.
    static let shellExports = [
        #"(bsd|g)?tar\s+(x[A-Za-z]*\b|([^|;&]*\s)?(-[A-Za-z]*x[A-Za-z]*|--extract)\b)"#,
        #"unzip\b"#,
        #"ditto\s+([^|;&]*\s)?-x"#,
        #"git\s+([^|;&]*\s)?(clone|checkout-index|worktree\s+add|--work-tree)\b"#,
    ].map { try! Regex(start + $0).wordBoundaryKind(.simple) }
    /// The same as a program's arguments (Swift's, Python's, JavaScript's), or as a command line in a string.
    static let argumentExports = [
        #"\btar["'].*["'](-[A-Za-z]*x[A-Za-z]*|--extract|x[A-Za-z]*)["']"#,
        #"\bunzip["']"#,
        #"\bditto["'].*["']-x"#,
        #"\b[Gg]it\b.*["'](clone|checkout-index|--work-tree[^"']*)["']"#,
        #"["']worktree["'],\s*["']add["']"#,
        #"\b(bsd|g)?tar\s+(x[A-Za-z]*\b|([^"'|;&]*\s)?(-[A-Za-z]*x[A-Za-z]*|--extract)\b)"#,
        #"\bunzip\s"#,
        #"\bgit\s+([^"'|;&]*\s)?(clone|checkout-index|worktree\s+add|--work-tree)\b"#,
    ].map { try! Regex($0).wordBoundaryKind(.simple) }
    static let agentFiles = ["AGENTS.md", "CLAUDE", ".claude", ".mcp.json"]
    /// A test that finds this checkout: from its own path, or the current directory (`swift test` runs in the package).
    static let locatesCheckout = try! Regex(#"#filePath|#file\b|currentDirectoryPath|__file__|os\.getcwd|process\.cwd|import\.meta"#)
    static let scratchRoots = ["$tool_scratch", "${tool_scratch}", "$TMPDIR", "${TMPDIR", "/tmp/", "$(mktemp"]
    static let assignment = try! Regex(#"^\s*(?:local\s+|export\s+|readonly\s+)?([A-Za-z_][A-Za-z0-9_]*)=(\S*)"#)

    /// "file:12" for each export under `root`'s scripts/ and Tests/ that neither leaves the agent files out nor writes
    /// into a scratch folder, in order.
    static func flagged(under root: URL) throws -> [String] {
        var flagged: [String] = []
        for folder in ["scripts", "Tests"] {
            let base = root.appendingPathComponent(folder)
            let files = (FileManager.default.subpaths(atPath: base.path) ?? [])
                .filter { file in [".sh", ".swift", ".py", ".mjs"].contains { file.hasSuffix($0) } }.sorted()
            for file in files where "\(folder)/\(file)" != this {
                let path = "\(folder)/\(file)"
                let text = try String(contentsOf: base.appendingPathComponent(file), encoding: .utf8)
                let lines = text.components(separatedBy: "\n")
                let shell = file.hasSuffix(".sh")
                let scratch = shell ? scratchVariables(lines) : []
                let inScratchRepos = !shell && !text.contains(locatesCheckout)
                let exports = shell ? shellExports : argumentExports
                for (index, line) in lines.enumerated() {
                    let code = line.trimmingCharacters(in: .whitespaces)
                    if code.hasPrefix("#") || code.hasPrefix("//") { continue }
                    guard exports.contains(where: { line.contains($0) }) else { continue }
                    let statement = statement(lines, from: index)
                    if agentFiles.allSatisfy({ statement.contains($0) }) || inScratchRepos { continue }
                    if shell, let destination = destination(statement), isScratch(destination, scratch) { continue }
                    flagged.append("\(path):\(index + 1)")
                }
            }
        }
        return flagged
    }

    /// The line at `index` and the lines continuing it: a trailing backslash, or brackets still open (at most 8 more).
    static func statement(_ lines: [String], from index: Int) -> String {
        var text = lines[index], depth = 0, next = index
        while true {
            let line = lines[next]
            for character in line {
                if "([{".contains(character) { depth += 1 } else if ")]}".contains(character) { depth -= 1 }
            }
            next += 1
            guard next < lines.count, next - index <= 8, depth > 0 || line.hasSuffix("\\") else { return text }
            text += "\n" + lines[next]
        }
    }

    /// The shell variables only ever set to a scratch folder, or a folder under another such variable.
    static func scratchVariables(_ lines: [String]) -> Set<String> {
        var values: [String: [String]] = [:]
        for line in lines {
            guard let match = line.firstMatch(of: assignment), let name = match.output[1].substring,
                  let value = match.output[2].substring else { continue }
            values[String(name), default: []].append(String(value))
        }
        var names: Set<String> = []
        while let name = values.keys.first(where: { !names.contains($0) && values[$0]!.allSatisfy { isScratch($0, names) } }) {
            names.insert(name)
        }
        return names
    }

    /// `word` (quotes dropped) names a folder under a scratch root or a scratch variable's folder.
    static func isScratch(_ word: String, _ variables: Set<String>) -> Bool {
        let path = word.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
        if scratchRoots.contains(where: { path.hasPrefix($0) }) { return true }
        return variables.contains { path == "$\($0)" || path.hasPrefix("$\($0)/") || path.hasPrefix("${\($0)}") }
    }

    /// Where the export in `statement` writes: tar's -C, unzip's -d, checkout-index's --prefix, --work-tree, a
    /// worktree's path, else (a clone, ditto) its last argument. Nil for a tar or unzip into the current directory.
    static func destination(_ statement: String) -> String? {
        let joined = statement.replacingOccurrences(of: "\\\n", with: " ")
        let segments = joined.components(separatedBy: CharacterSet(charactersIn: "|;&\n"))
        guard let segment = segments.first(where: { part in shellExports.contains { part.contains($0) } }) else { return nil }
        let words = segment.split(whereSeparator: \.isWhitespace).map(String.init)
        func after(_ flags: [String]) -> String? {
            for (index, word) in words.enumerated() {
                for flag in flags {
                    if word == flag, index + 1 < words.count { return words[index + 1] }
                    if flag.hasPrefix("--"), word.hasPrefix(flag + "=") { return String(word.dropFirst(flag.count + 1)) }
                }
            }
            return nil
        }
        if segment.contains(shellExports[0]) { return after(["-C", "--directory"]) }
        if segment.contains(shellExports[1]) { return after(["-d"]) }
        if segment.contains("checkout-index") { return after(["--prefix"]) }
        if segment.contains("--work-tree") { return after(["--work-tree"]) }
        // git worktree add [OPTIONS] PATH [COMMIT]: -b, -B and --reason take a value.
        if let add = words.firstIndex(of: "add"), add > 0, words[add - 1] == "worktree" {
            var index = add + 1
            while index < words.count, words[index].hasPrefix("-") { index += ["-b", "-B", "--reason"].contains(words[index]) ? 2 : 1 }
            return index < words.count ? words[index] : nil
        }
        return words.last { !$0.hasPrefix(">") && !$0.hasPrefix("2>") && $0 != "{" }
    }

    @Test func noScriptOrTestExportsAgentFilesIntoTheWorktree() throws {
        let flagged = try Self.flagged(under: Self.repo)
        #expect(flagged == [], """
            these write a git tree or an archive into the worktree with its AGENTS.md, CLAUDE*.md, .claude/ or .mcp.json, \
            which the lead's audit counts as the worker's own uncommitted instructions: exclude all four (tar --exclude) \
            or write into a scratch folder outside the worktree ($tool_scratch from scripts/lib/scratch.sh):
            \(flagged.joined(separator: "\n"))
            """)
    }

    /// Exports into the worktree are named with their line; exports leaving the agent files out, into a scratch
    /// folder, in a test's scratch repositories, and comments aren't.
    @Test func anExportIntoTheWorktreeIsNamedWithItsLine() throws {
        let root = temp.url("lint")
        for folder in ["scripts", "Tests/A", "Tests/B"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try """
            #!/bin/bash
            source scripts/lib/scratch.sh
            scratch_tmpdir vs-x
            git archive "$commit" | tar -x -C .build/base
            git archive "$commit" | tar -x
            mkdir out && cd out && tar xf ../tree.tar
            git clone --quiet . "$checkout"
            git worktree add --detach .build/wt "$commit"
            git checkout-index -a --prefix=.build/copy/
            git --work-tree=.build/tree checkout "$commit" -- .
            unzip -q tree.zip -d .build/zip
            ditto -x -k tree.zip .build/ditto
            tar -x -f tree.tar \\
                -C .build/next
            # git archive "$commit" | tar -x -C .build/comment
            echo "run git clone to get one"
            folder=$tool_scratch/base
            twice=$tool_scratch/x
            twice=.build/x
            git archive "$commit" | tar -x -C "$twice"
            nested="$folder/deeper"
            home=$(mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX")
            git archive "$commit" | tar -x -C "$folder"
            git archive "$commit" | tar -x -C "$nested"
            git clone --quiet --no-local . "$tool_scratch/clone" || exit 2
            git worktree add --detach "$home/wt" "$commit"
            tar -xf tree.tar -C "${TMPDIR}x"
            unzip -q tree.zip -d /tmp/x
            git archive "$commit" | tar -x -C .build/base --exclude AGENTS.md --exclude 'CLAUDE*.md' --exclude .claude --exclude .mcp.json
            tar -x -f tree.tar -C .build/next \\
                --exclude AGENTS.md --exclude 'CLAUDE*.md' --exclude .claude --exclude .mcp.json
            """.write(to: root.appendingPathComponent("scripts/export.sh"), atomically: true, encoding: .utf8)
        try """
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            try run("/usr/bin/tar", ["-xf", tree.path, "-C", source.path])
            try run("/usr/bin/tar", ["-xf", tree.path, "-C", source.path,
                                     "--exclude", "AGENTS.md", "--exclude", "CLAUDE*.md", "--exclude", ".claude", "--exclude", ".mcp.json"])
            Git.run(["clone", "-q", repo.path, repo.path + "/.build/clone"], in: repo.path)
            Git.run(["worktree", "add", "-q", ".build/wt"], in: repo.path)
            // Git.run(["clone", repo.path, "x"])
            try run("/usr/bin/tar", ["-xf", tree.path, "-C", source.path, "--exclude", "AGENTS.md"])
            """.write(to: root.appendingPathComponent("Tests/A/Located.swift"), atomically: true, encoding: .utf8)
        try """
            let root = temp.url("repo").path
            Git.run(["worktree", "add", "-q", root + "/wt"], in: root)
            Git.run(["clone", "-q", root, root + "-copy"], in: root)
            """.write(to: root.appendingPathComponent("Tests/B/ScratchRepo.swift"), atomically: true, encoding: .utf8)
        let flagged = try Self.flagged(under: root)
        #expect(flagged == (4...13).map { "scripts/export.sh:\($0)" } + ["scripts/export.sh:20", "Tests/A/Located.swift:2", "Tests/A/Located.swift:5",
                                                                          "Tests/A/Located.swift:6", "Tests/A/Located.swift:8"])
    }
}
