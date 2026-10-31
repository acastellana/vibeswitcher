import Foundation
import Testing
@testable import VibeCore

/// scripts/e2e/loop-passage, the stand-in for Passage between two Macs that scripts/e2e/wallet-e2e.sh runs on one: its
/// command line as Passage's README gives it (output lines, exit codes, usage errors), and VibeSwitcher's own
/// `PassageLink` driving its dev side against a `passage listen` on its vault side. Everything is in a scratch folder:
/// never the real passage, its Keychain, pairings or inbox.
struct LoopPassageTests {
    let scratch = Scratch()
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let script = repo.appendingPathComponent("scripts/e2e/loop-passage").path
    static let devPeer = "de0e2e01"
    static let vaultPeer = "0a1b2c3d"

    /// A loop root with a `passage` wrapper per side (`<root>/<side>/bin/passage`), as wallet-e2e.sh makes them.
    struct Loop {
        let root: URL
        init(_ scratch: Scratch) throws {
            // Spelled as Foundation spells it (/tmp, not /private/tmp): PassageLink reads paths under its standardized inbox.
            root = scratch.url("loop").standardizedFileURL
            for side in ["dev", "vault"] {
                let bin = root.appendingPathComponent("\(side)/bin", isDirectory: true)
                try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                let wrapper = bin.appendingPathComponent("passage")
                try """
                    #!/bin/bash
                    LOOP_PASSAGE_ROOT=\(RecentProjects.shellQuote(root.path)) LOOP_PASSAGE_SIDE=\(side) exec \(RecentProjects.shellQuote(LoopPassageTests.script)) "$@"

                    """.write(to: wrapper, atomically: true, encoding: .utf8)
                chmod(wrapper.path, 0o755)
            }
        }
        func passage(_ side: String) -> String { root.appendingPathComponent("\(side)/bin/passage").path }
        func inbox(_ side: String) -> URL { root.appendingPathComponent("\(side)/inbox", isDirectory: true) }
        func file(_ path: String) -> URL { root.appendingPathComponent(path) }

        /// Runs one side's passage; stdin from `input` when given.
        func run(_ side: String, _ arguments: [String], input: String? = nil) throws -> (status: Int32, out: String, err: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: passage(side))
            process.arguments = arguments
            let out = Pipe(), err = Pipe(), stdin = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = stdin
            try process.run()
            if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
            try stdin.fileHandleForWriting.close()
            let output = out.fileHandleForReading.readDataToEndOfFile(), errors = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: output, as: UTF8.self), String(decoding: errors, as: UTF8.self))
        }

        /// Whether a `listen` has marked `side` listening.
        func listening(_ side: String) -> Bool {
            !((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("\(side)/listening").path)) ?? []).isEmpty
        }
    }

    @Test func versionPeersAndUsageAreAsTheReadmeSays() throws {
        let loop = try Loop(scratch)
        #expect(try loop.run("dev", ["version"]) == (0, "passage 1.0\n", ""))
        #expect(try loop.run("dev", ["peers", "--no-discovery"]).out == "\(Self.vaultPeer)\tpaired\tLoop vault Mac\n")
        #expect(try loop.run("vault", ["peers", "--no-discovery", "--json"]).out
                == #"{"name":"Loop dev Mac","pairedAt":"2026-10-31T00:00:00Z","peerID":"de0e2e01","reachable":null}"# + "\n")
        // Nobody listens on the vault side: unreachable, after the --wait.
        #expect(try loop.run("dev", ["peers", "--wait", "0"]).out == "\(Self.vaultPeer)\tunreachable\tLoop vault Mac\n")
        // Usage: an unknown command or option, --yes (neither app passes it), a bad number, a missing or extra argument.
        for arguments in [["unpair", Self.vaultPeer], ["frob"], [], ["inbox", "--bogus"], ["send", Self.vaultPeer, "f", "--yes"],
                          ["send", Self.vaultPeer, "f", "--timeout", "soon"], ["send", Self.vaultPeer], ["listen", "extra"],
                          ["peers", "--name", "x"], ["send", Self.vaultPeer, "f", "--name", ""]] {
            let ran = try loop.run("dev", arguments)
            #expect(ran.status == 2, "\(arguments)")
            #expect(ran.err.hasPrefix("passage: ") && ran.err.contains("usage: passage"), "\(arguments): \(ran.err)")
        }
        // No such peer: 3, by ID or name.
        #expect(try loop.run("dev", ["send", "0d0d0d0d", "-"], input: "x").status == 3)
        #expect(try loop.run("dev", ["inbox", "someone"]).status == 3)
        // An unpaired peer's folder may still be listed by ID: empty.
        #expect(try loop.run("dev", ["inbox", "0d0d0d0d"]) == (0, "", ""))
        // Not listening: 4, with Passage's message, and nothing lands.
        let unreachable = try loop.run("dev", ["send", "loop VAULT mac", "-", "--timeout", "0"], input: "x")
        #expect(unreachable.status == 4)
        #expect(unreachable.err == "passage: Loop vault Mac (0a1b2c3d) is not reachable on the local network. Is `passage listen` running there?\n")
        #expect(try loop.run("vault", ["inbox"]).out.isEmpty)
        // The file: 1.
        #expect(try loop.run("dev", ["send", Self.vaultPeer, loop.file("missing").path]).err.hasPrefix("passage: no such file: "))
        #expect(try loop.run("dev", ["send", Self.vaultPeer, loop.root.path]).status == 1)
        // Without its environment it refuses to guess a side.
        let bare = Process()
        bare.executableURL = URL(fileURLWithPath: Self.script)
        bare.arguments = ["version"]
        bare.environment = ["PATH": "/usr/bin:/bin"]
        bare.standardError = FileHandle.nullDevice
        try bare.run()
        bare.waitUntilExit()
        #expect(bare.terminationStatus == 1)
    }

    /// VibeSwitcher's link on the dev side sends to a `passage listen` on the vault side: the file lands in the vault's
    /// inbox under the dev peer, 0600, never over another; `inbox --json` lists it where the Wallet Manager reads it;
    /// the listener prints a line per arrival and stops cleanly on SIGTERM.
    @Test func devSendsToAListeningVault() throws {
        let loop = try Loop(scratch)
        let heard = DispatchSemaphore(value: 0)
        let vault = try #require(PassageLink(executable: loop.passage("vault"), walletPeer: Self.devPeer, inboxFolder: loop.inbox("vault")))
        let listener = try vault.listen { heard.signal() }
        #expect(eventually { loop.listening("vault") })
        #expect(try loop.run("dev", ["peers", "--json"]).out.contains(#""reachable":true"#))

        let dev = try #require(PassageLink(executable: loop.passage("dev"), walletPeer: Self.vaultPeer, inboxFolder: loop.inbox("dev")))
        let request = loop.file("request.json")
        try Data(#"{"made":"up"}"#.utf8).write(to: request)
        let id = "3f2b8c1e-5d4a-4b6f-9e0c-7a1d2e3f4a5d"
        #expect(dev.send(file: request, id: id) == .sent)
        #expect(dev.send(file: request, id: id) == .sent)
        #expect(heard.wait(timeout: .now() + hangGuard) == .success)
        #expect(heard.wait(timeout: .now() + hangGuard) == .success)

        // Both copies, under two names (the second never replaces the first), listed where the vault's inbox is.
        let entries = try vault.inbox().get()
        #expect(entries.count == 2)
        let folder = loop.inbox("vault").appendingPathComponent(Self.devPeer).path + "/"
        for entry in entries {
            #expect(entry.peerID == Self.devPeer && entry.name == WalletRequest.fileName(id) && entry.path.hasPrefix(folder))
            #expect(try vault.read(entry) == Data(#"{"made":"up"}"#.utf8))
            let mode = try #require(FileManager.default.attributesOfItem(atPath: entry.path)[.posixPermissions] as? Int)
            #expect(mode == 0o600)
        }
        #expect(Set(entries.map(\.path)).count == 2)
        // The text listing: peer, received UTC, bytes, path.
        let lines = try loop.run("vault", ["inbox", "Loop dev Mac"]).out.split(separator: "\n")
        #expect(lines.count == 2 && lines.allSatisfy { $0.split(separator: "\t").count == 4 && $0.hasPrefix("\(Self.devPeer)\t") })
        // Nothing went to the dev side.
        #expect(try dev.inbox().get().isEmpty)

        listener.stop()
        #expect(listener.exitStatus == 0)
        #expect(!loop.listening("vault"))
    }

    /// The faults a run sets: a send that delivers and then fails (exit 1, the link's `failed`: it may have arrived),
    /// one that can't reach the other side (4), and a hold that makes every send unreachable until it's lifted.
    @Test func faultsDeliverThenFailAndHold() throws {
        let loop = try Loop(scratch)
        let vault = try #require(PassageLink(executable: loop.passage("vault"), walletPeer: Self.devPeer, inboxFolder: loop.inbox("vault")))
        let listener = try vault.listen {}
        defer { listener.stop() }
        #expect(eventually { loop.listening("vault") })
        let dev = try #require(PassageLink(executable: loop.passage("dev"), walletPeer: Self.vaultPeer, inboxFolder: loop.inbox("dev")))
        let request = loop.file("request.json")
        try Data("{}".utf8).write(to: request)
        let id = "3f2b8c1e-5d4a-4b6f-9e0c-7a1d2e3f4a5e"

        try "deliver-then-fail\n".write(to: loop.file("dev/fault"), atomically: true, encoding: .utf8)
        guard case .failed(let said) = dev.send(file: request, id: id) else { Issue.record("not failed"); return }
        #expect(said.contains("the peer closed the connection"))
        #expect(try vault.inbox().get().count == 1)
        // Taken once: the next send goes through.
        #expect(!FileManager.default.fileExists(atPath: loop.file("dev/fault").path))
        #expect(dev.send(file: request, id: id) == .sent)

        try "unreachable\n".write(to: loop.file("dev/fault"), atomically: true, encoding: .utf8)
        guard case .peerNotListening = dev.send(file: request, id: id) else { Issue.record("not unreachable"); return }

        FileManager.default.createFile(atPath: loop.file("dev/hold").path, contents: nil)
        for _ in 0..<2 { guard case .peerNotListening = dev.send(file: request, id: id) else { Issue.record("held, but went"); return } }
        try FileManager.default.removeItem(at: loop.file("dev/hold"))
        #expect(dev.send(file: request, id: id) == .sent)
        #expect(try vault.inbox().get().count == 3)
        // Each run's arguments are logged on its side: never --yes.
        let calls = try String(contentsOf: loop.file("dev/calls"), encoding: .utf8)
        #expect(calls.split(separator: "\n").filter { $0.hasPrefix("send ") }.count == 6)
        #expect(!calls.contains("--yes"))
    }
}
