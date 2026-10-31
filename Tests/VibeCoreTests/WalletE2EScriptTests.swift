import Foundation
import Testing
@testable import VibeCore

/// scripts/e2e/wallet-e2e.sh's first steps, on a scratch fake Wallet Manager checkout with a fake `npm` and `node` first
/// on the PATH: it refreshes the checkout's node_modules (`npm ci --ignore-scripts`) when its lockfile is newer, and a
/// failing npm stops the run with one line. A copy of the script runs from a scratch repo, so what the run makes lands
/// there; the fake `node` refuses the vault, so the run stops before anything else starts. Never the real npm, node or
/// ~/dev/wallet-manager. And both scripts' --help print their header comments only.
struct WalletE2EScriptTests {
    let scratch = Scratch()
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    struct Setup {
        let root: URL
        var script: String { root.appendingPathComponent("repo/scripts/e2e/wallet-e2e.sh").path }
        var wm: URL { root.appendingPathComponent("wallet-manager", isDirectory: true) }
        var npmLog: URL { root.appendingPathComponent("npm-calls.log") }
        var nodeLog: URL { root.appendingPathComponent("node-calls.log") }
        var installed: URL { wm.appendingPathComponent("node_modules/.package-lock.json") }
        var lockfile: URL { wm.appendingPathComponent("package-lock.json") }

        init(_ scratch: Scratch) throws {
            root = scratch.url("wallet-e2e")
            let fm = FileManager.default
            for (path, text) in [
                // The script and what it sources, in a scratch repo of their own.
                "repo/scripts/e2e/wallet-e2e.sh": try String(contentsOf: WalletE2EScriptTests.repo.appendingPathComponent("scripts/e2e/wallet-e2e.sh"), encoding: .utf8),
                "repo/scripts/lib/scratch.sh": try String(contentsOf: WalletE2EScriptTests.repo.appendingPathComponent("scripts/lib/scratch.sh"), encoding: .utf8),
                // The fake checkout: what the script looks for, and a lockfile.
                "wallet-manager/src/server/main.ts": "\n", "wallet-manager/src/dev/fake-chain-cli.ts": "\n",
                "wallet-manager/package-lock.json": "{}\n",
                // npm: records its arguments; as npm ci, writes node_modules/.package-lock.json where it runs, or
                // fails with a stack trace when FAKE_NPM_FAIL is set.
                "bin/npm": """
                    #!/bin/bash
                    printf '%s\\n' "$*" >>"$FAKE_NPM_LOG"
                    if [[ -n ${FAKE_NPM_FAIL:-} ]]; then
                        echo "npm error code ERESOLVE" >&2
                        echo "Error: could not resolve" >&2
                        echo "    at Arborist.buildIdealTree (/fake/npm/arborist.js:1:1)" >&2
                        exit 1
                    fi
                    mkdir -p node_modules && echo '{}' >node_modules/.package-lock.json
                    echo "added 1 package"

                    """,
                // node: records its arguments and fails, so the run stops at the vault's check.
                "bin/node": """
                    #!/bin/bash
                    printf '%s\\n' "$*" >>"$FAKE_NODE_LOG"
                    exit 1

                    """,
            ] {
                let url = root.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            for tool in ["npm", "node"] { chmod(root.appendingPathComponent("bin/\(tool)").path, 0o755) }
            try fm.createDirectory(at: root.appendingPathComponent("tmp"), withIntermediateDirectories: true)
            try fm.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
        }

        /// Runs the script copy on the fake checkout: its status and its output and errors together.
        func run(npmFails: Bool = false) throws -> (status: Int32, output: String) {
            var environment = [
                "PATH": root.appendingPathComponent("bin").path + ":/usr/bin:/bin",
                "HOME": root.appendingPathComponent("home").path,
                "TMPDIR": root.appendingPathComponent("tmp").path,
                "FAKE_NPM_LOG": npmLog.path, "FAKE_NODE_LOG": nodeLog.path,
            ]
            if npmFails { environment["FAKE_NPM_FAIL"] = "1" }
            return try HomeIsolationTests.run("/bin/bash", [script, "--wallet-manager", wm.path], environment: environment)
        }

        func npmCalls() -> [String] {
            ((try? String(contentsOf: npmLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        func setModified(_ url: URL, _ date: Date) throws {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }

    @Test func npmCiRunsWhenNodeModulesIsMissingOrOlderThanTheLockfile() throws {
        let setup = try Setup(scratch)

        // No node_modules/.package-lock.json: npm ci --ignore-scripts, in the checkout, said so; then the run goes on.
        var ran = try setup.run()
        #expect(setup.npmCalls() == ["ci --ignore-scripts"], "\(ran.output)")
        #expect(FileManager.default.fileExists(atPath: setup.installed.path), "npm ran in the checkout")
        #expect(ran.output.contains("node_modules is missing or older than its package-lock.json: running `npm ci --ignore-scripts` there"), "\(ran.output)")
        #expect(!ran.output.contains("added 1 package"), "npm's own output goes to its log: \(ran.output)")
        #expect(ran.output.contains("the Wallet Manager's checker refused the synthetic vault"), "went on to the vault: \(ran.output)")

        // Current (installed after the lockfile): no npm.
        let now = Date()
        try setup.setModified(setup.lockfile, now.addingTimeInterval(-3600))
        try setup.setModified(setup.installed, now.addingTimeInterval(-60))
        ran = try setup.run()
        #expect(setup.npmCalls().count == 1, "\(ran.output)")
        #expect(!ran.output.contains("npm ci"), "\(ran.output)")
        #expect(ran.output.contains("the Wallet Manager's checker refused the synthetic vault"), "\(ran.output)")

        // The lockfile changed since (a dependency added): npm ci again.
        try setup.setModified(setup.lockfile, now.addingTimeInterval(-30))
        ran = try setup.run()
        #expect(setup.npmCalls() == ["ci --ignore-scripts", "ci --ignore-scripts"], "\(ran.output)")
        #expect(ran.output.contains("running `npm ci --ignore-scripts` there"), "\(ran.output)")
    }

    @Test func aFailingNpmStopsTheRunWithOneLine() throws {
        let setup = try Setup(scratch)
        let ran = try setup.run(npmFails: true)
        #expect(ran.status == 1)
        #expect(setup.npmCalls() == ["ci --ignore-scripts"])
        let lines = ran.output.split(separator: "\n").map(String.init)
        // The line saying it runs npm ci, then one line saying it failed and where its output is: no trace.
        #expect(lines.count == 2, "\(ran.output)")
        let failure = lines.last ?? ""
        #expect(failure.hasPrefix("wallet-e2e: `npm ci --ignore-scripts` failed in ") && failure.contains("(exit 1); its output: "), "\(failure)")
        #expect(!ran.output.contains("    at ") && !ran.output.contains("ERESOLVE"), "\(ran.output)")
        // Its output is kept where the line says; nothing else ran (no node).
        let log = failure.range(of: "its output: ").map { String(failure[$0.upperBound...]) } ?? ""
        #expect(((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").contains("ERESOLVE"), "\(failure)")
        #expect(!FileManager.default.fileExists(atPath: setup.nodeLog.path))
    }

    /// `--help` prints the script's header comment, line 2 up to its first line that isn't a comment, and nothing else.
    @Test(arguments: ["scripts/e2e/wallet-e2e.sh", "scripts/sandbox-app.sh"])
    func helpPrintsTheHeaderCommentsOnly(_ path: String) throws {
        let script = Self.repo.appendingPathComponent(path).path
        let lines = try String(contentsOfFile: script, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        let header = lines.dropFirst().prefix { $0.hasPrefix("#") }
            .map { $0.hasPrefix("# ") ? String($0.dropFirst(2)) : String($0.dropFirst()) }
        let home = scratch.url("help-home").path   // read (wallet-e2e.sh's default checkout), never made
        let ran = try HomeIsolationTests.run("/bin/bash", [script, "--help"], environment: ["PATH": "/usr/bin:/bin", "HOME": home])
        #expect(ran.status == 0)
        #expect(ran.output == header.joined(separator: "\n") + "\n")
        #expect(header.count > 10)
    }
}
