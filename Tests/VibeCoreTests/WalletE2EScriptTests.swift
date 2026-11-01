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

    /// Case 1's verdict on recorded outcomes (`--judge-case-1 SEEN RECORD`, which runs nothing else): a check that failed
    /// in a record that isn't rejected is a warning, named on a line of its own, and the case passes; a rejection or a
    /// missing answer fails it.
    func judge(_ seen: String, _ record: String) throws -> (status: Int32, output: String) {
        let script = Self.repo.appendingPathComponent("scripts/e2e/wallet-e2e.sh").path
        let home = scratch.url("judge-home").path   // read (the default checkout's path), never made
        return try HomeIsolationTests.run("/bin/bash", [script, "--judge-case-1", seen, record], environment: ["PATH": "/usr/bin:/bin", "HOME": home])
    }

    @Test func case1CountsFailedChecksOutsideARejectionAsWarnings() throws {
        // The Wallet Manager with an address book: received and pending, recipient-known and calldata warn.
        var ran = try judge("waiting → sent → received", "pending true 1 wallet:ok,chain:ok,balance:ok,recipient-known:failed,calldata:failed")
        #expect(ran.status == 0, "\(ran.output)")
        var lines = ran.output.split(separator: "\n").map(String.init)
        #expect(lines.first?.hasPrefix("case 1 valid testnet transfer from a known wallet: pass (") == true, "\(ran.output)")
        #expect(lines.first?.contains("warnings: 2") == true, "\(ran.output)")
        #expect(Array(lines.dropFirst()) == ["  warning: recipient-known (failed, in a result that isn't rejected)",
                                             "  warning: calldata (failed, in a result that isn't rejected)"], "\(ran.output)")

        // Every check ok: a pass with no warning lines; a proposed card passes too.
        for seen in ["waiting → sent → received", "waiting → sent → proposed"] {
            ran = try judge(seen, "pending true 2 wallet:ok,chain:ok,recipient-known:ok")
            lines = ran.output.split(separator: "\n").map(String.init)
            #expect(ran.status == 0 && lines.count == 1 && lines[0].contains(": pass (") && lines[0].contains("warnings: 0"), "\(ran.output)")
        }
    }

    @Test(arguments: [
        // Rejected: by the checks, or declined on the vault Mac.
        ("waiting → sent", "rejected true 2 wallet:failed,chain:ok", "the Wallet Manager's record is rejected"),
        ("waiting → sent → received", "declined true 2 wallet:ok", "the Wallet Manager's record is declined"),
        // No answer: no record, the card never Received, no result, or the checks never finished.
        ("waiting → sent", "", "no answer: the Wallet Manager has no record of the request"),
        ("waiting → sent", "pending true 1 wallet:ok,chain:ok", "no answer on the card"),
        ("waiting → sent → received", "pending true 0 wallet:ok", "the Wallet Manager sent no result"),
        ("waiting → sent → received", "pending false 1 ", "the Wallet Manager didn't finish its checks"),
    ])
    func case1FailsOnARejectionOrAMissingAnswer(_ seen: String, _ record: String, _ why: String) throws {
        let ran = try judge(seen, record)
        #expect(ran.status == 1, "\(ran.output)")
        #expect(ran.output.hasPrefix("case 1 valid testnet transfer from a known wallet: fail (\(why); "), "\(ran.output)")
        #expect(!ran.output.contains("warning:"), "\(ran.output)")
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

/// `wallet-e2e.sh --real-testnet`'s refusals, on a fake ~/.config/wallet-manager-testnet/ (a scratch HOME), a fake
/// Wallet Manager checkout and no network: a fake `curl` and `npm` first on the PATH record any call and fail, and
/// `node` is the real one behind a wrapper that records each call (the guards run the checkout's `node src/networks.ts
/// --json` through it). Every refusal must come before curl or npm runs and before the run makes its scratch folder; the
/// config folder's refusals before node too. The keystore is fake (its address, no key); its marker strings and
/// the passphrase must never be printed. A copy of the script runs from a scratch repo, as above.
struct WalletE2ERealTestnetGuardTests {
    let scratch = Scratch()
    static let throwaway = "0x4c50c0Ae2b75B8C17d999CA2e11118A27867ab99"
    static let passphrase = "fake-passphrase-marker-7d1c"
    static let ciphertextMarker = "fake-ciphertext-marker-93ab"
    /// The real node, from the test's PATH (scripts/test.sh needs it there).
    static let realNode = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        .map { "\($0)/node" }.first { FileManager.default.isExecutableFile(atPath: $0) }

    static let genesis = "0x17d89764d4f4f963158fc4c5e8f2cb670c2837740b35f37081c12860c3df97e4"

    /// `node src/networks.ts --json`'s line as the Wallet Manager's docs/protocol/sign-page.md has it, with `testnet`'s
    /// fields replaceable (raw JSON values; nil leaves the field out).
    static func networksJSON(chainId: String? = "4221", rpcUrl: String? = #""https://rpc.testnet-chain.genlayer.com""#,
                             explorerUrl: String? = #""https://scan.testnet-chain.genlayer.com""#,
                             genesisHash: String? = "\"\(genesis)\"") -> String {
        let testnet = [("chainId", chainId), ("rpcUrl", rpcUrl), ("explorerUrl", explorerUrl), ("genesisHash", genesisHash)]
            .compactMap { name, value in value.map { "\"\(name)\":\($0)" } }.joined(separator: ",")
        return #"{"testnet":{\#(testnet)},"mainnet":{"chainId":42424242,"rpcUrl":"https://rpc.chain.genlayer.com","explorerUrl":"https://scan.chain.genlayer.com","genesisHash":"0xbd18399bbf15d4021ed40eabc6ef5ff00ee4dd94e0543fd5b653cfc659817b68"}}"#
    }

    /// A fake src/networks.ts, run by the real node: with exactly `--json` it writes `stdout` (and `stderr`) and exits
    /// `status`; with any other arguments, its usage and 2, as the contract has it. Its source is nothing like the
    /// Wallet Manager's, so only the command's output can decide.
    static func networks(stdout: String = networksJSON() + "\n", stderr: String = "", status: Int = 0) -> String {
        let b64 = { (text: String) in Data(text.utf8).base64EncodedString() }
        return """
            if (process.argv.slice(2).join(" ") !== "--json") { process.stderr.write("usage: node src/networks.ts --json\\n"); process.exit(2); }
            process.stdout.write(Buffer.from("\(b64(stdout))", "base64").toString());
            process.stderr.write(Buffer.from("\(b64(stderr))", "base64").toString());
            process.exitCode = \(status);

            """
    }

    struct Setup {
        let root: URL
        var script: String { root.appendingPathComponent("repo/scripts/e2e/wallet-e2e.sh").path }
        var config: URL { root.appendingPathComponent("home/.config/wallet-manager-testnet", isDirectory: true) }
        var keystore: URL { config.appendingPathComponent("keystore.json") }
        var passphrase: URL { config.appendingPathComponent("passphrase") }
        var calls: URL { root.appendingPathComponent("calls.log") }
        var tmp: URL { root.appendingPathComponent("tmp", isDirectory: true) }
        var networks: URL { root.appendingPathComponent("wallet-manager/src/networks.ts") }

        init(_ scratch: Scratch) throws {
            root = scratch.url("wallet-e2e-real")
            let fm = FileManager.default
            let node = try #require(WalletE2ERealTestnetGuardTests.realNode, "node isn't on the test's PATH")
            let log = "basename \"$0\" >>\"$FAKE_CALLS\"\n"   // the tool's name, a line a call
            let fake = "#!/bin/bash\n" + log + "exit 1\n"
            for (path, text) in [
                "repo/scripts/e2e/wallet-e2e.sh": try String(contentsOf: WalletE2EScriptTests.repo.appendingPathComponent("scripts/e2e/wallet-e2e.sh"), encoding: .utf8),
                "repo/scripts/lib/scratch.sh": try String(contentsOf: WalletE2EScriptTests.repo.appendingPathComponent("scripts/lib/scratch.sh"), encoding: .utf8),
                "wallet-manager/src/server/main.ts": "\n", "wallet-manager/src/dev/fake-chain-cli.ts": "\n",
                "wallet-manager/src/networks.ts": WalletE2ERealTestnetGuardTests.networks(),
                "bin/curl": fake, "bin/npm": fake, "bin/node": "#!/bin/bash\n" + log + "exec \(node) \"$@\"\n",
            ] {
                let url = root.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            for tool in ["curl", "node", "npm"] { chmod(root.appendingPathComponent("bin/\(tool)").path, 0o755) }
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            try fm.createDirectory(at: config, withIntermediateDirectories: true)
            chmod(config.path, 0o700)
            try writeKeystore(address: String(WalletE2ERealTestnetGuardTests.throwaway.dropFirst(2)).lowercased())
            try write(passphrase, WalletE2ERealTestnetGuardTests.passphrase + "\n")
        }

        func write(_ url: URL, _ text: String, mode: mode_t = 0o600) throws {
            try text.write(to: url, atomically: true, encoding: .utf8)
            chmod(url.path, mode)
        }

        /// A v3 keystore's shape with `address` (and a second one when given): no key, a marker for its ciphertext.
        func writeKeystore(address: String, second: String? = nil, version: Int = 3) throws {
            let extra = second.map { #","address":"\#($0)""# } ?? ""
            try write(keystore, #"{"version":\#(version),"id":"00000000-0000-4000-8000-000000000000","address":"\#(address)"\#(extra),"crypto":{"ciphertext":"\#(WalletE2ERealTestnetGuardTests.ciphertextMarker)"}}"# + "\n")
        }

        func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
            try HomeIsolationTests.run("/bin/bash", [script, "--wallet-manager", root.appendingPathComponent("wallet-manager").path] + arguments, environment: [
                "PATH": root.appendingPathComponent("bin").path + ":/usr/bin:/bin",
                "HOME": root.appendingPathComponent("home").path,
                "TMPDIR": tmp.path,
                "FAKE_CALLS": calls.path,
            ])
        }

        /// What curl, node and npm were asked: nothing, for a refusal of the config folder.
        var toolCalls: String { (try? String(contentsOf: calls, encoding: .utf8)) ?? "" }
        /// The calls that could reach the network or change the checkout: curl's and npm's.
        var networkCalls: [Substring] { toolCalls.split(separator: "\n").filter { $0 != "node" } }
        var tmpEntries: [String] { (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] }
    }

    func expectNoSecret(_ output: String) {
        #expect(!output.contains(Self.passphrase) && !output.contains(Self.ciphertextMarker), "\(output)")
    }

    @Test func theGuardsPassOnlyForTheThrowawayWalletsSelfTransferAndTouchNothing() throws {
        let setup = try Setup(scratch)
        for arguments in [["--real-testnet", "--check-guards"],
                          ["--real-testnet", "--check-guards", "--amount", "1", "--from", Self.throwaway.lowercased(), "--to", Self.throwaway, "--chain", "4221"]] {
            let ran = try setup.run(arguments)
            #expect(ran.status == 0, "\(arguments): \(ran.output)")
            #expect(ran.output.hasPrefix("wallet-e2e --real-testnet: guards pass: chain 4221, a self-transfer of "), "\(ran.output)")
            // The explorer and genesis are the checkout's `node src/networks.ts --json`'s.
            #expect(ran.output.hasSuffix("the Wallet Manager's testnet: 4221 at https://rpc.testnet-chain.genlayer.com, explorer https://scan.testnet-chain.genlayer.com, genesis \(Self.genesis)\n"), "\(ran.output)")
            expectNoSecret(ran.output)
        }
        #expect(setup.networkCalls.isEmpty, "\(setup.toolCalls)")
        #expect(setup.tmpEntries.isEmpty, "\(setup.tmpEntries)")
    }

    /// Without --real-testnet, its options are refused (usage, 64) and the synthetic run never starts with them.
    @Test(arguments: [["--check-guards"], ["--dry-run"], ["--amount", "1000"], ["--from", throwaway], ["--chain", "4221"],
                      ["--real-testnet", "--dry-run", "--check-guards"]])
    func realTestnetOptionsNeedTheFlag(_ arguments: [String]) throws {
        let setup = try Setup(scratch)
        let ran = try setup.run(arguments)
        #expect(ran.status == 64, "\(ran.output)")
        #expect(setup.toolCalls.isEmpty && setup.tmpEntries.isEmpty, "\(setup.toolCalls) \(setup.tmpEntries)")
    }

    /// Each refusal on the real run (no --check-guards, no --dry-run): exit 2 with its reason, before any network.
    @Test(arguments: [
        (["--chain", "42424242"], "", "chain 42424242: only GenLayer testnet, 4221"),
        (["--chain", "1"], "", "chain 1: only GenLayer testnet"),
        (["--from", "0x00000000000000000000000000000000000E2e01", "--to", "0x00000000000000000000000000000000000E2e01"], "", "only the throwaway testnet wallet"),
        (["--to", "0x00000000000000000000000000000000000e2E02"], "", "only a self-transfer"),
        (["--amount", "1001"], "", "amount 1001: 1 to 1000 wei"),
        (["--amount", "0"], "", "amount 0: 1 to 1000 wei"),
        (["--amount", "01000"], "", "amount 01000: 1 to 1000 wei"),
        (["--amount", "1e3"], "", "amount 1e3: 1 to 1000 wei"),
        (["--amount", "1000000000000000000"], "", "1 to 1000 wei"),
        ([], "no-folder", "wallet-manager-testnet) is missing"),
        ([], "folder-0755", "the throwaway wallet's folder ("),
        ([], "folder-link", "is a link"),
        ([], "keystore-0644", "the throwaway keystore ("),
        ([], "keystore-link", "the throwaway keystore ("),
        ([], "passphrase-0640", "the throwaway passphrase ("),
        ([], "passphrase-missing", "wallet-manager-testnet/passphrase) is missing"),
        ([], "passphrase-empty", "the throwaway passphrase file holds no passphrase"),
        ([], "keystore-other-address", "the throwaway keystore isn't the throwaway wallet's"),
        ([], "keystore-two-addresses", "doesn't name exactly one address"),
        ([], "keystore-version-1", "isn't a version 3 keystore"),
    ])
    func refusesBeforeAnyNetwork(_ arguments: [String], _ fault: String, _ why: String) throws {
        let setup = try Setup(scratch)
        let fm = FileManager.default
        switch fault {
        case "no-folder": try fm.removeItem(at: setup.config)
        case "folder-0755": chmod(setup.config.path, 0o755)
        case "folder-link":
            let real = setup.root.appendingPathComponent("elsewhere")
            try fm.moveItem(at: setup.config, to: real)
            try fm.createSymbolicLink(at: setup.config, withDestinationURL: real)
        case "keystore-0644": chmod(setup.keystore.path, 0o644)
        case "keystore-link":
            let real = setup.root.appendingPathComponent("keystore-elsewhere.json")
            try fm.moveItem(at: setup.keystore, to: real)
            try fm.createSymbolicLink(at: setup.keystore, withDestinationURL: real)
        case "passphrase-0640": chmod(setup.passphrase.path, 0o640)
        case "passphrase-missing": try fm.removeItem(at: setup.passphrase)
        case "passphrase-empty": try setup.write(setup.passphrase, "\n")
        case "keystore-other-address": try setup.writeKeystore(address: "00000000000000000000000000000000000e2e01")
        case "keystore-two-addresses": try setup.writeKeystore(address: "4c50c0ae2b75b8c17d999ca2e11118a27867ab99", second: "00000000000000000000000000000000000e2e01")
        case "keystore-version-1": try setup.writeKeystore(address: "4c50c0ae2b75b8c17d999ca2e11118a27867ab99", version: 1)
        default: break
        }
        let ran = try setup.run(["--real-testnet"] + arguments)
        #expect(ran.status == 2, "\(ran.output)")
        #expect(ran.output.hasPrefix("wallet-e2e --real-testnet: refused: "), "\(ran.output)")
        #expect(ran.output.contains(why), "\(ran.output)")
        #expect(ran.output.split(separator: "\n").count == 1, "\(ran.output)")
        expectNoSecret(ran.output)
        #expect(setup.toolCalls.isEmpty, "no curl, node or npm before the refusal: \(setup.toolCalls)")
        #expect(setup.tmpEntries.isEmpty, "no scratch folder before the refusal: \(setup.tmpEntries)")
    }
    /// The command's line decides, its keys in any order, a trailing newline or none.
    @Test func theWalletManagersTestnetIsReadFromNetworksJson() throws {
        let setup = try Setup(scratch)
        let reordered = #"{"mainnet":{},"testnet":{"genesisHash":"\#(Self.genesis)","explorerUrl":"https://scan.testnet-chain.genlayer.com","rpcUrl":"https://rpc.testnet-chain.genlayer.com","chainId":4221}}"#
        for line in [reordered, reordered + "\n"] {
            try Self.networks(stdout: line).write(to: setup.networks, atomically: true, encoding: .utf8)
            let ran = try setup.run(["--real-testnet", "--check-guards"])
            #expect(ran.status == 0, "\(ran.output)")
            #expect(ran.output.contains("explorer https://scan.testnet-chain.genlayer.com, genesis \(Self.genesis)"), "\(ran.output)")
        }
        #expect(setup.networkCalls.isEmpty, "\(setup.toolCalls)")
        #expect(setup.tmpEntries.isEmpty, "\(setup.tmpEntries)")
    }

    /// A Wallet Manager whose `node src/networks.ts --json` fails, says anything but its one JSON line, leaves a field
    /// out, or whose testnet isn't 4221 at GenLayer's testnet RPC with an https explorer and a pinned genesis hash:
    /// refused (2), fail-closed, before any network or scratch folder.
    @Test(arguments: [
        (networks(stdout: networksJSON(chainId: "42424242") + "\n"), "testnet is chain 42424242 at https://rpc.testnet-chain.genlayer.com, not 4221 at"),
        (networks(stdout: networksJSON(chainId: #""4221""#) + "\n"), "testnet is chain - at"),
        (networks(stdout: networksJSON(chainId: nil) + "\n"), "testnet is chain - at"),
        (networks(stdout: networksJSON(rpcUrl: #""https://rpc.chain.genlayer.com""#) + "\n"), "is chain 4221 at https://rpc.chain.genlayer.com, not 4221 at https://rpc.testnet-chain.genlayer.com"),
        (networks(stdout: networksJSON(rpcUrl: #""http://127.0.0.1:8545""#) + "\n"), "not 4221 at https://rpc.testnet-chain.genlayer.com"),
        (networks(stdout: networksJSON(rpcUrl: nil) + "\n"), "is chain 4221 at -, not"),
        (networks(stdout: networksJSON(explorerUrl: #""http://scan.testnet-chain.genlayer.com""#) + "\n"), "has no https explorer (http://scan.testnet-chain.genlayer.com)"),
        (networks(stdout: networksJSON(explorerUrl: #""https://scan.testnet-chain.genlayer.com/x y""#) + "\n"), "has no https explorer (-)"),
        (networks(stdout: networksJSON(explorerUrl: nil) + "\n"), "has no https explorer (-)"),
        (networks(stdout: networksJSON(genesisHash: nil) + "\n"), "testnet has no genesisHash"),
        (networks(stdout: networksJSON(genesisHash: "\"\(genesis.uppercased())\"") + "\n"), "testnet has no genesisHash"),
        (networks(stdout: networksJSON(genesisHash: #""0x17d8""#) + "\n"), "testnet has no genesisHash"),
        // Not exactly one JSON line, or not only that: extra stdout before or after, two lines, nothing, not JSON.
        (networks(stdout: "loading networks\n" + networksJSON() + "\n"), "didn't print one JSON line, and only that"),
        (networks(stdout: networksJSON() + "\nextra\n"), "didn't print one JSON line, and only that"),
        (networks(stdout: networksJSON() + "\n\n"), "didn't print one JSON line, and only that"),
        (networks(stdout: ""), "didn't print one JSON line, and only that"),
        (networks(stdout: "{\"testnet\": \n"), "didn't print one JSON line, and only that"),
        (networks(stdout: "[]\n"), "testnet is chain - at -"),
        // A non-zero exit, even with the line; anything on stderr; a crash; an old checkout without --json.
        (networks(status: 1), "`node src/networks.ts --json` failed (1)"),
        (networks(stderr: "(node:1) ExperimentalWarning: something\n"), "`node src/networks.ts --json` failed (it wrote to stderr)"),
        ("throw new Error(\"boom\");\n", "`node src/networks.ts --json` failed ("),
        ("export const NETWORKS = { testnet: { chainId: 4221 } };\n", "didn't print one JSON line, and only that"),
        ("", "no src/networks.ts in a Wallet Manager checkout at "),
    ])
    func refusesAWalletManagerWhoseTestnetIsntGenLayers(_ networks: String, _ why: String) throws {
        let setup = try Setup(scratch)
        if networks.isEmpty { try FileManager.default.removeItem(at: setup.networks) }
        else { try networks.write(to: setup.networks, atomically: true, encoding: .utf8) }
        for arguments in [["--real-testnet"], ["--real-testnet", "--check-guards"], ["--real-testnet", "--dry-run"]] {
            let ran = try setup.run(arguments)
            #expect(ran.status == 2, "\(arguments): \(ran.output)")
            #expect(ran.output.hasPrefix("wallet-e2e --real-testnet: refused: the Wallet Manager's ") || ran.output.hasPrefix("wallet-e2e --real-testnet: refused: no src/networks.ts"), "\(ran.output)")
            #expect(ran.output.contains(why), "\(arguments): \(ran.output)")
            #expect(ran.output.split(separator: "\n").count == 1, "\(ran.output)")
        }
        #expect(setup.networkCalls.isEmpty, "\(setup.toolCalls)")
        #expect(setup.tmpEntries.isEmpty, "\(setup.tmpEntries)")
    }
}

/// `--real-testnet`'s page check before its sign POST (`--judge-sign-page PAGE [--amount WEI]`, which runs nothing
/// else), on a signing page recorded from the Wallet Manager (946ad67, a `--real-testnet --dry-run`: the hot wallet's
/// page for the throwaway wallet's 1000 wei self-transfer, csrf, token and scratch path redacted) and on variants of it. Only the
/// page's data-sign-field / data-value and data-sign-warnings hooks (the Wallet Manager's docs/protocol/sign-page.md)
/// decide: the page's text, rows and form don't. A mismatch, a field it doesn't expect, or any warning refuses (2).
struct WalletE2ESignPageTests {
    let scratch = Scratch()
    static let recorded = WalletE2EScriptTests.repo.appendingPathComponent("scripts/e2e/testdata/sign-page-hot-self-transfer.html")
    static let throwaway = WalletE2ERealTestnetGuardTests.throwaway
    static let hooks = #"<div hidden data-sign-warnings=""><span data-sign-field="from" data-value="0x4c50c0Ae2b75B8C17d999CA2e11118A27867ab99"></span><span data-sign-field="chain" data-value="4221"></span><span data-sign-field="to" data-value="0x4c50c0Ae2b75B8C17d999CA2e11118A27867ab99"></span><span data-sign-field="value" data-value="1000"></span><span data-sign-field="call" data-value="none"></span></div>"#

    /// Judges `page` (the recorded page with `edit` applied): its status and output.
    func judge(_ edit: (String) -> String = { $0 }, _ arguments: [String] = []) throws -> (status: Int32, output: String) {
        let page = try String(contentsOf: Self.recorded, encoding: .utf8)
        #expect(page.contains(Self.hooks), "the recorded page carries its hooks as recorded")
        let file = scratch.url("page.html")
        try edit(page).write(to: file, atomically: true, encoding: .utf8)
        let node = try #require(WalletE2ERealTestnetGuardTests.realNode, "node isn't on the test's PATH")
        let path = URL(fileURLWithPath: node).deletingLastPathComponent().path + ":/usr/bin:/bin"
        let script = WalletE2EScriptTests.repo.appendingPathComponent("scripts/e2e/wallet-e2e.sh").path
        return try HomeIsolationTests.run("/bin/bash", [script, "--judge-sign-page", file.path] + arguments,
                                          environment: ["PATH": path, "HOME": scratch.url("judge-home").path])
    }

    static func replacing(_ old: String, _ new: String) -> (String) -> String {
        { page in
            precondition(page.contains(old), "the recorded page has \(old)")
            return page.replacingOccurrences(of: old, with: new)
        }
    }

    @Test func theRecordedPageSignsTheSelfTransferWithNoWarnings() throws {
        let ran = try judge()
        #expect(ran.status == 0, "\(ran.output)")
        #expect(ran.output == "wallet-e2e: the signing page signs a self-transfer of 1000 wei on 4221 from \(Self.throwaway), with no warnings\n", "\(ran.output)")
    }

    /// Only the hooks count: the hooks moved, reordered, in other tags, single-quoted, with other text and rows around
    /// them, still pass; the visible rows saying something else don't matter.
    @Test(arguments: [
        replacing(hooks, ""), // moved: put back at the top below
        replacing(#"<dt>Chain</dt><dd>GenLayer Testnet <span class="sub">(4221)</span></dd>"#, "<dt>Chain</dt><dd>Something else (1)</dd>"),
        replacing(#"<span data-sign-field="from""#, #"<p class="x" data-sign-field='from'"#),
        replacing("data-sign-warnings=\"\"", "data-sign-warnings"),
        replacing(#"<div hidden data-sign-warnings="">"#, #"<section data-sign-warnings="  " hidden>"#),
    ] as [(String) -> String])
    func otherMarkupAroundTheHooksDoesntMatter(_ edit: @escaping (String) -> String) throws {
        let moved = { (page: String) -> String in
            let edited = edit(page)
            return edited.contains("data-sign-warnings") ? edited : edited.replacingOccurrences(of: "<main class=\"signing\">", with: "<main class=\"signing\">\n" + Self.hooks.replacingOccurrences(of: "></span><span", with: "></span>\n<span"))
        }
        let ran = try judge(moved)
        #expect(ran.status == 0, "\(ran.output)")
    }

    @Test(arguments: [
        // Not a signing page (a refusal has no hooks), or two lists.
        (replacing(hooks, ""), "the page has no data-sign-warnings element: it isn't a page that can sign"),
        (replacing(hooks, hooks + hooks), "the page has 2 data-sign-warnings elements, not one"),
        (replacing(hooks, "<!-- " + hooks + " -->"), "the page has no data-sign-warnings element"),
        (replacing(hooks, "<script>const x = '" + hooks + "';</script>"), "the page has no data-sign-warnings element"),
        // Warnings: known, unknown, on a warning's own element, several.
        (replacing("data-sign-warnings=\"\"", "data-sign-warnings=\"stale\""), "the page shows warnings: stale"),
        (replacing("data-sign-warnings=\"\"", "data-sign-warnings=\"blind-call\""), "the page shows warnings: blind-call"),
        (replacing("data-sign-warnings=\"\"", "data-sign-warnings=\"lookalike resembles\""), "the page shows warnings: lookalike resembles"),
        (replacing("data-sign-warnings=\"\"", "data-sign-warnings=\"something-new\""), "the page shows warnings: something-new"),
        (replacing("<h1>Review and sign</h1>", "<h1>Review and sign</h1><p class=\"warn\" data-sign-warning=\"stale\">Over an hour old</p>"), "the page shows warnings: stale"),
        // Each value differs from the request.
        (replacing(#"data-value="4221""#, #"data-value="42424242""#), "the page doesn't sign what was asked: chain 42424242, not 4221"),
        (replacing(#"<span data-sign-field="from" data-value="0x4c50c0Ae2b75B8C17d999CA2e11118A27867ab99">"#, #"<span data-sign-field="from" data-value="0x00000000000000000000000000000000000E2e01">"#), "from 0x00000000000000000000000000000000000E2e01, not \(throwaway)"),
        (replacing(#"<span data-sign-field="to" data-value="0x4c50c0Ae2b75B8C17d999CA2e11118A27867ab99">"#, #"<span data-sign-field="to" data-value="0x00000000000000000000000000000000000e2E02">"#), "to 0x00000000000000000000000000000000000e2E02, not \(throwaway)"),
        (replacing(#"<span data-sign-field="to" data-value="0x4c50c0Ae2b75B8C17d999CA2e11118A27867ab99">"#, #"<span data-sign-field="to" data-value="0x4c50c0ae2b75b8c17d999ca2e11118a27867ab99">"#), "to 0x4c50c0ae2b75b8c17d999ca2e11118a27867ab99, not"),
        (replacing(#"data-value="1000""#, #"data-value="999""#), "value 999, not 1000"),
        (replacing(#"data-value="1000""#, #"data-value="01000""#), "value 01000, not 1000"),
        (replacing(#"data-value="none""#, #"data-value="0xa9059cbb""#), "call 0xa9059cbb, not none"),
        // Missing, twice, without a value, or a field this run doesn't sign (a token's, a Safe's).
        (replacing(#"<span data-sign-field="call" data-value="none"></span>"#, ""), "call missing, not none"),
        (replacing(#"<span data-sign-field="value" data-value="1000"></span>"#, #"<span data-sign-field="value" data-value="1000"></span><span data-sign-field="value" data-value="1000"></span>"#), "the page names its value twice"),
        (replacing(#"<span data-sign-field="value" data-value="1000">"#, #"<span data-sign-field="value">"#), "the page's value has no data-value"),
        (replacing(#"<span data-sign-field="call" data-value="none"></span>"#, #"<span data-sign-field="call" data-value="none"></span><span data-sign-field="token-amount" data-value="1000"></span>"#), "a field this run doesn't expect: token-amount"),
        (replacing(#"<span data-sign-field="call" data-value="none"></span>"#, #"<span data-sign-field="call" data-value="none"></span><span data-sign-field="safe" data-value="0x4c50c0Ae2b75B8C17d999CA2e11118A27867ab99"></span>"#), "a field this run doesn't expect: safe"),
        // Escaped values aren't unescaped: they don't match.
        (replacing(#"data-value="none""#, #"data-value="&#110;one""#), "call &#110;one, not none"),
    ] as [((String) -> String, String)])
    func aMismatchOrAnyWarningRefusesBeforeThePost(_ edit: @escaping (String) -> String, _ why: String) throws {
        let ran = try judge(edit)
        #expect(ran.status == 2, "\(ran.output)")
        #expect(ran.output.hasPrefix("wallet-e2e: refused before the sign POST: "), "\(ran.output)")
        #expect(ran.output.contains(why), "\(ran.output)")
        #expect(ran.output.split(separator: "\n").count == 1, "\(ran.output)")
    }

    /// The amount asked decides `value`: the recorded 1000 wei page is refused for 999.
    @Test func theAmountAskedIsTheValueExpected() throws {
        var ran = try judge({ $0 }, ["--amount", "999"])
        #expect(ran.status == 2 && ran.output.contains("value 1000, not 999"), "\(ran.output)")
        ran = try judge({ $0 }, ["--amount", "1000"])
        #expect(ran.status == 0, "\(ran.output)")
        ran = try judge({ $0 }, ["--chain", "4221"])
        #expect(ran.status == 64, "\(ran.output)")
    }
}

/// `--real-testnet`'s judgement after its sign POST (`--judge-real-results DIR ID`, which runs nothing else): the results
/// the card took for the request, from the dev side's inbox folder, in `sequence` order (not the files' names), must read
/// received → proposed → signed → submitted, numbered 1 to 4, the submitted one with its txHash. `proposed` now comes
/// with the POST, not with opening the page, but the order is the same; a missing or extra step, or a final `failed`,
/// fails (1).
struct WalletE2ERealResultsTests {
    let scratch = Scratch()
    static let id = "6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b"
    static let other = "0e1d2c3b-4a59-4687-9a6b-5c4d3e2f1a0b"
    static let tx = "0x" + String(repeating: "ab", count: 32)

    /// Writes each (sequence, status, txHash) as a result for `id` under a made-up name (the names' order deliberately not
    /// the sequence's), runs the judge on the folder: its status and output.
    func judge(_ results: [(Int, String, String?)], id: String = id, extra: [String] = []) throws -> (status: Int32, output: String) {
        let dir = scratch.url("inbox/0a1b2c3d")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (index, (sequence, status, tx)) in results.enumerated() {
            let txField = tx.map { #","txHash":"\#($0)","explorerURL":"https://explorer-asimov.genlayer.com/tx/\#($0)""# } ?? ""
            let json = #"{"type":"wallet-result","version":1,"id":"\#(id)","sequence":\#(sequence),"createdAt":"2026-11-01T10:00:0\#(sequence)Z","status":"\#(status)","checks":[]\#(txField)}"#
            try json.write(to: dir.appendingPathComponent("20261101T100000Z-\(results.count - index)-wallet-result-\(id).json"), atomically: true, encoding: .utf8)
        }
        let node = try #require(WalletE2ERealTestnetGuardTests.realNode, "node isn't on the test's PATH")
        let path = URL(fileURLWithPath: node).deletingLastPathComponent().path + ":/usr/bin:/bin"
        let script = WalletE2EScriptTests.repo.appendingPathComponent("scripts/e2e/wallet-e2e.sh").path
        return try HomeIsolationTests.run("/bin/bash", [script, "--judge-real-results", dir.path, Self.id] + extra,
                                          environment: ["PATH": path, "HOME": scratch.url("judge-home").path])
    }

    @Test func receivedProposedSignedSubmittedPassesInSequenceOrder() throws {
        let ran = try judge([(3, "signed", nil), (1, "received", nil), (4, "submitted", Self.tx), (2, "proposed", nil)])
        #expect(ran.status == 0, "\(ran.output)")
        #expect(ran.output == "wallet-e2e: the results read received → proposed → signed → submitted\n", "\(ran.output)")
    }

    @Test func anotherRequestsResultsDontCount() throws {
        let ran = try judge([(1, "received", nil), (2, "proposed", nil), (3, "signed", nil), (4, "submitted", Self.tx)], id: Self.other)
        #expect(ran.status == 1 && ran.output == "wallet-e2e: the results read none, not received → proposed → signed → submitted\n", "\(ran.output)")
    }

    @Test(arguments: [
        // No `proposed` (the Wallet Manager never sent it with the POST), or it came twice.
        ([(1, "received", nil), (2, "signed", nil), (3, "submitted", tx)], "the results read received → signed → submitted, not "),
        ([(1, "received", nil), (2, "proposed", nil), (3, "proposed", nil), (4, "signed", nil), (5, "submitted", tx)], "the results read received → proposed → proposed → signed → submitted, not "),
        // Ended failed (a mined cancel answers `failed` with its txHash), or stopped short of submitted.
        ([(1, "received", nil), (2, "proposed", nil), (3, "signed", nil), (4, "failed", tx)], "the results read received → proposed → signed → failed, not "),
        ([(1, "received", nil), (2, "proposed", nil), (3, "signed", nil)], "the results read received → proposed → signed, not "),
        // Numbered wrong, or submitted without its transaction.
        ([(1, "received", nil), (2, "proposed", nil), (4, "signed", nil), (5, "submitted", tx)], "the results are numbered 1, 2, 4, 5, not 1 to 4"),
        ([(1, "received", nil), (2, "proposed", nil), (3, "signed", nil), (4, "submitted", nil)], "the submitted result has no txHash (none)"),
    ] as [([(Int, String, String?)], String)])
    func anyOtherOrderFails(_ results: [(Int, String, String?)], _ why: String) throws {
        let ran = try judge(results)
        #expect(ran.status == 1, "\(ran.output)")
        #expect(ran.output.hasPrefix("wallet-e2e: \(why)"), "\(ran.output)")
        #expect(ran.output.split(separator: "\n").count == 1, "\(ran.output)")
    }

    @Test func takesNoOtherOption() throws {
        let ran = try judge([(1, "received", nil)], extra: ["--amount", "1000"])
        #expect(ran.status == 64, "\(ran.output)")
    }
}
