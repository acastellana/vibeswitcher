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
/// `node` is the real one behind a wrapper that records each call (the guards read the checkout's NETWORKS.testnet
/// through it). Every refusal must come before curl or npm runs and before the run makes its scratch folder; the
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

    /// src/networks.ts as the Wallet Manager's commit 6621d7a lays it out (each field on its own line in
    /// Object.freeze({ … }), the testnet explorer at scan.testnet-chain), with `testnet`'s fields replaceable.
    static func networks(chainId: String = "4221", rpcUrl: String = #""https://rpc.testnet-chain.genlayer.com""#,
                         explorerUrl: String = #""https://scan.testnet-chain.genlayer.com""#) -> String {
        """
        export type NetworkName = "testnet" | "mainnet";
        const GEN = { name: "GEN", symbol: "GEN", decimals: 18 } as const;

        export const NETWORKS: Readonly<Record<NetworkName, unknown>> = Object.freeze({
          testnet: Object.freeze({
            name: "testnet",
            title: "GenLayer Testnet",
            chainId: \(chainId),
            rpcUrl: \(rpcUrl),
            explorerUrl: \(explorerUrl),
            nativeCurrency: GEN,
          }),
          mainnet: Object.freeze({
            name: "mainnet",
            title: "GenLayer Mainnet",
            chainId: 42424242,
            rpcUrl: "https://rpc.chain.genlayer.com",
            explorerUrl: "https://scan.chain.genlayer.com",
            nativeCurrency: GEN,
          }),
        });

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
            // The explorer is the checkout's NETWORKS.testnet's, read through node.
            #expect(ran.output.hasSuffix("the Wallet Manager's testnet: 4221 at https://rpc.testnet-chain.genlayer.com, explorer https://scan.testnet-chain.genlayer.com\n"), "\(ran.output)")
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
    /// The checkout's NETWORKS.testnet decides, whatever its layout: the 6621d7a one above, or all on one line.
    @Test func theWalletManagersTestnetIsReadThroughNodeInAnyLayout() throws {
        let setup = try Setup(scratch)
        try (Self.networks().split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ") + "\n")
            .write(to: setup.networks, atomically: true, encoding: .utf8)
        let ran = try setup.run(["--real-testnet", "--check-guards"])
        #expect(ran.status == 0, "\(ran.output)")
        #expect(ran.output.contains("explorer https://scan.testnet-chain.genlayer.com"), "\(ran.output)")
        #expect(setup.networkCalls.isEmpty, "\(setup.toolCalls)")
    }

    /// A Wallet Manager whose testnet isn't 4221 at GenLayer's testnet RPC with an https explorer, or whose
    /// src/networks.ts can't be read through node: refused (2), fail-closed, before any network or scratch folder.
    @Test(arguments: [
        (networks(chainId: "42424242"), "NETWORKS.testnet is chain 42424242 at https://rpc.testnet-chain.genlayer.com, not 4221 at"),
        (networks(chainId: #""4221""#), "NETWORKS.testnet is chain - at"),
        (networks(rpcUrl: #""https://rpc.chain.genlayer.com""#), "is chain 4221 at https://rpc.chain.genlayer.com, not 4221 at https://rpc.testnet-chain.genlayer.com"),
        (networks(rpcUrl: #""http://127.0.0.1:8545""#), "not 4221 at https://rpc.testnet-chain.genlayer.com"),
        (networks(explorerUrl: #""http://scan.testnet-chain.genlayer.com""#), "has no https explorer (http://scan.testnet-chain.genlayer.com)"),
        (networks(explorerUrl: #""https://scan.testnet-chain.genlayer.com/x y""#), "has no https explorer (-)"),
        (networks(explorerUrl: "undefined"), "has no https explorer (-)"),
        ("export const NETWORKS = Object.freeze({ testnet: Object.freeze({ chainId: 4221, \n", "src/networks.ts couldn't be read through node"),
        ("export const NETWORKS = {};\n", "NETWORKS.testnet is chain - at -"),
        ("export const OTHER = 1;\n", "src/networks.ts couldn't be read through node"),
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
