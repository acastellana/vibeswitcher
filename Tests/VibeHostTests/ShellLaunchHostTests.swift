import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// The shell a Run starts (`ShellAsk.spawnRequest`), in a scratch session host, as the app starts it: its shell runs
/// the command it was given at launch, in the request's folder, then stays an interactive shell; and in it, a wallet
/// request is placed in that new session and stamped for it, as the host does for any session the user opened, so its
/// card shows under that session (`WalletAsk.filed` gives it, for that session, and the stamp is the host's).
extension LeadVaultHostTests {
    @Test func aRunShellRunsItsCommandStaysOpenAndItsWalletRequestsAreStampedForIt() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = folder.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let book = LeadVault.Book()
        let host = try TestHost(vault: book, appExecutable: try #require(HostServer.executable(of: getpid())))
        let app = try TestClient(host)
        let requests = folder.appendingPathComponent("requests.bin")
        let answers = folder.appendingPathComponent("answers.bin")
        let script = folder.appendingPathComponent("program.sh").path
        // The program the agent asked for: says where it runs, then (told to) asks the host as vs-wallet would.
        try """
        pwd -P > '\(folder.path)/ran-in'
        while [ ! -f '\(folder.path)/go' ]; do sleep 0.05; done
        \(nc(host, requests, answers, until: folder.appendingPathComponent("stop")))
        touch '\(folder.path)/done'
        """.write(toFile: script, atomically: true, encoding: .utf8)
        let asker = "aaaaaaaa-2222-4333-8444-555555555555"
        // A trailing comment: given at launch, it can't swallow what keeps the shell open.
        let request = ShellRequest(session: asker, cwd: String(cString: realpath(project.path, nil)),
                                   command: "sh '\(script)' && echo program-ended # done", label: "Program", createdAt: Date())
        let seq = app.send(.spawn(ShellAsk.spawnRequest(request, cols: 80, rows: 24)))
        #expect(eventually { app.reply(to: seq) != nil })
        guard case .spawned(let shell)? = app.reply(to: seq) else { Issue.record("not spawned: \(String(describing: app.reply(to: seq)))"); return }
        #expect(shell.label == "Shell: Program" && shell.agent == nil)
        #expect(eventually { (try? String(contentsOfFile: folder.path + "/ran-in", encoding: .utf8)) == request.cwd + "\n" })

        // From inside it: placed in the new session, and sealed for it.
        let mine = shell.id.uuidString.lowercased()
        let wallet = try WalletAsk.request(["--workspace", "example", "--from", "example-hardware", "--chain", "42424242",
                                            "--to", "0x0000000000000000000000000000000000000001", "--amount", "1", "--reason", "Pay it."],
                                           session: mine, cwd: request.cwd)
        let digest = WalletStamp.digest(try wallet.encoded())
        try frames([.vault(.walletSession), .vault(.sealWalletRequest(session: mine, digest: digest))]).write(to: requests)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("go").path, contents: nil)
        #expect(eventually { answered(answers, 2...3) })
        FileManager.default.createFile(atPath: folder.appendingPathComponent("stop").path, contents: nil)
        let got = try replies(Data(contentsOf: answers))
        #expect(got[2] == .vault(.session(mine)), "\(String(describing: got[2]))")
        guard case .vault(.seal(let seal))? = got[3] else { Issue.record("no seal: \(String(describing: got[3]))"); return }
        let asked = folder.appendingPathComponent("wallet-asked", isDirectory: true)
        try WalletAsk.file(wallet, stamp: WalletStamp(session: mine, digest: digest, seal: seal), in: asked)
        let filed = WalletAsk.filed(in: asked)
        #expect(filed.requests.map(\.requestedBy.session) == [mine] && filed.refused.isEmpty)
        #expect(book.answer(.verifyWalletRequests(filed.requests.compactMap { filed.stamps[$0.id] }), from: .app) == .verified([true]))

        // The command ended; the shell is still there, interactive, taking what's typed into it.
        #expect(eventually { FileManager.default.fileExists(atPath: folder.appendingPathComponent("done").path) })
        #expect(eventually { app.screen(shell.id)?.contains("program-ended") == true })
        app.send(.input(id: shell.id, bytes: Data("echo still-$((40 + 2))\r".utf8), reply: false))
        #expect(eventually { app.screen(shell.id)?.contains("still-42") == true }, "\(app.screen(shell.id) ?? "")")
        #expect(app.latest(shell.id)?.isLive != false)
        app.send(.kill(id: shell.id))
    }
}
