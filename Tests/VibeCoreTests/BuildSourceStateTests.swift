import Foundation
import Testing

/// scripts/build-app.sh's check that the checkout didn't move while the app compiled (`source_state`, read before the
/// compile and after it): a move marks the build `VSSourceChanged`, and status then can't compare the installed build's
/// gate code with main (`LeadToolset.gateLag`). 2026-11-15: the lead's record commit 65325752 (docs/lead only) landed
/// on main during an install's compile, and the build of 64a97228 was marked not matching: status said "couldn't be
/// compared … taken as not installed yet". A commit touching nothing the build reads keeps the build's commit; one
/// touching Sources/ (or Package.swift, the build script, the app's resources), or Sources/ edits not committed, don't.
struct BuildSourceStateTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let temp = Scratch()

    /// Runs `script` with build-app.sh's `source_state` defined, in `dir`; its output.
    func bash(_ script: String, in dir: URL) throws -> String {
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "set -euo pipefail; eval \"$(sed -n '/^source_state() {$/,/^}$/p' \"$1\")\"; cd \"$2\"; " + script,
                             "bash", Self.repo.appendingPathComponent("scripts/build-app.sh").path, dir.path]
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_AUTHOR_NAME"] = "t"; env["GIT_AUTHOR_EMAIL"] = "t@example.invalid"
        env["GIT_COMMITTER_NAME"] = "t"; env["GIT_COMMITTER_EMAIL"] = "t@example.invalid"
        process.environment = env
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, Comment(rawValue: script + "\n" + error))
        return output
    }

    /// A scratch checkout like the app's: sources, the package, the build script, resources, and the lead's records.
    func checkout() throws -> URL {
        let dir = temp.url("source-state")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try bash("""
            git init -q -b main .
            mkdir -p Sources/VibeCore scripts/lib Resources/bin Web docs/lead
            echo 'let a = 1' > Sources/VibeCore/A.swift
            echo '// swift-tools-version:5.9' > Package.swift
            echo '{}' > Package.resolved
            echo '#!/bin/bash' > scripts/build-app.sh
            echo '# lib' > scripts/lib/swift-jobs.sh
            echo '<plist/>' > Resources/Info.plist
            echo '<html>' > Web/index.html
            echo '# decisions' > docs/lead/decisions.md
            git add -A
            git commit -q -m start
            """, in: dir)
        return dir
    }

    /// The state before and after `change`.
    func states(around change: String, in dir: URL) throws -> (before: String, after: String) {
        let before = try bash("source_state | shasum", in: dir)
        _ = try bash(change, in: dir)
        return (before, try bash("source_state | shasum", in: dir))
    }

    @Test func aCommitTouchingOnlyTheLeadsRecordsKeepsTheBuildsCommit() throws {
        let dir = try checkout()
        let state = try states(around: "echo '- more' >> docs/lead/decisions.md; git commit -q -am 'Lead: decisions and progress'", in: dir)
        #expect(state.before == state.after, "a docs/lead commit during the compile marked the build as not matching")
        // Two of them, and one adding a file outside what the build reads.
        let more = try states(around: """
            echo x >> docs/lead/decisions.md; git commit -q -am 'Lead: one'
            echo y > NOTES.md; git add NOTES.md; git commit -q -m 'Lead: two'
            """, in: dir)
        #expect(more.before == more.after)
    }

    @Test func aCommitTouchingWhatTheBuildReadsMarksItNotMatching() throws {
        for path in ["Sources/VibeCore/A.swift", "Sources/VibeCore/New.swift", "Package.swift", "Package.resolved",
                     "scripts/build-app.sh", "scripts/lib/swift-jobs.sh", "Resources/Info.plist", "Web/index.html"] {
            let dir = try checkout()
            let state = try states(around: "echo '// changed' >> \(path); git add -A; git commit -q -m change", in: dir)
            #expect(state.before != state.after, "a commit changing \(path) during the compile kept the build's commit")
        }
        // A commit removing a source file.
        let dir = try checkout()
        let state = try states(around: "git rm -q Sources/VibeCore/A.swift; git commit -q -m remove", in: dir)
        #expect(state.before != state.after)
    }

    @Test func sourcesEditsNotCommittedStillMarkItNotMatching() throws {
        let dir = try checkout()
        let edited = try states(around: "echo '// edit' >> Sources/VibeCore/A.swift", in: dir)
        #expect(edited.before != edited.after, "a Sources/ edit during the compile kept the build's commit")
        let added = try states(around: "echo 'let b = 2' > Sources/VibeCore/B.swift", in: dir)
        #expect(added.before != added.after, "a new Sources/ file during the compile kept the build's commit")
        // An edit made, then committed with a lead record alongside: the build read the edit, so it still isn't the start commit.
        let committed = try states(around: "echo '// edit 2' >> Sources/VibeCore/A.swift; echo z >> docs/lead/decisions.md; git commit -q -am both", in: dir)
        #expect(committed.before != committed.after)
    }

    /// build-app.sh compares that state across the compile, and the uncommitted-changes check before it still reads
    /// Sources/ and Package.swift.
    @Test func buildAppComparesTheStateAcrossTheCompile() throws {
        let script = try String(contentsOf: Self.repo.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        #expect(script.contains("SOURCE_STATE=\"$(source_state | shasum)\""))
        #expect(script.contains("if [[ \"$(source_state | shasum)\" != \"$SOURCE_STATE\" ]]; then"))
        #expect(script.contains("if ! git diff --quiet HEAD -- Sources Package.swift || [[ -n \"$(git ls-files --others --exclude-standard -- Sources Package.swift)\" ]]; then"))
    }
}
