import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// The session on a wallet request's card is the one the session host tells the filing process runs in: a real
/// process in a session asks a scratch host over its socket, as `vs-wallet request` (or any script of an agent's) would.
extension LeadVaultHostTests {
    @Test func aWalletRequestIsStampedOnlyForTheSessionItsProcessRunsIn() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let book = LeadVault.Book()
        let host = try TestHost(vault: book, appExecutable: try #require(HostServer.executable(of: getpid())))
        let app = try TestClient(host)
        let other = try app.spawn("sleep 30")
        let script = folder.appendingPathComponent("agent.sh").path
        let requests = folder.appendingPathComponent("requests.bin")
        let answers = folder.appendingPathComponent("answers.bin")
        try """
        while [ ! -f '\(folder.path)/go' ]; do sleep 0.05; done
        \(nc(host, requests, answers, until: folder.appendingPathComponent("stop")))
        touch '\(folder.path)/done'
        sleep 30
        """.write(toFile: script, atomically: true, encoding: .utf8)
        let agent = try app.spawn("VIBESWITCHER_SESSION=\(other.id.uuidString) sh '\(script)'")
        let digest = WalletStamp.digest(Data("a wallet request's bytes".utf8))
        let mine = agent.id.uuidString.lowercased(), theirs = other.id.uuidString.lowercased()
        // The session the agent starts (labelled as it likes) asks for a stamp of its own once told to (`go2`).
        let childScript = folder.appendingPathComponent("child.sh").path
        let childRequests = folder.appendingPathComponent("child-requests.bin")
        let childAnswers = folder.appendingPathComponent("child-answers.bin")
        try """
        while [ ! -f '\(folder.path)/go2' ]; do sleep 0.05; done
        \(nc(host, childRequests, childAnswers, until: folder.appendingPathComponent("stop2")))
        sleep 30
        """.write(toFile: childScript, atomically: true, encoding: .utf8)
        let spawn = SpawnRequest(cwd: folder.path, command: "sh '\(childScript)'", env: [:], cols: 80, rows: 24, keepShell: false,
                                 label: "Treasury", agent: nil)
        try frames([.vault(.walletSession),
                    .vault(.sealWalletRequest(session: mine, digest: digest)),
                    .vault(.sealWalletRequest(session: theirs, digest: digest)),
                    .spawn(spawn)]).write(to: requests)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("go").path, contents: nil)
        #expect(eventually { answered(answers, 2...5) })
        FileManager.default.createFile(atPath: folder.appendingPathComponent("stop").path, contents: nil)
        #expect(eventually { FileManager.default.fileExists(atPath: folder.appendingPathComponent("done").path) })
        let got = try replies(Data(contentsOf: answers))

        // Its own session, whatever its environment says; sealed for that session only.
        #expect(got[2] == .vault(.session(mine)), "\(String(describing: got[2]))")
        guard case .vault(.seal(let seal))? = got[3] else { Issue.record("no seal: \(String(describing: got[3]))"); return }
        #expect(refused(got[4]), "\(String(describing: got[4]))")
        // The seal is the host's for that session and those bytes, and for nothing else.
        let stamp = WalletStamp(session: mine, digest: digest, seal: seal)
        #expect(book.answer(.verifyWalletRequests([stamp, WalletStamp(session: theirs, digest: digest, seal: seal),
                                                   WalletStamp(session: mine, digest: WalletStamp.digest(Data()), seal: seal)]), from: .app)
                == .verified([true, false, false]))

        // A session the agent started is the agent's to steer: placed in it, but no seal for it.
        guard case .spawned(let child)? = got[5] else { Issue.record("no child: \(String(describing: got[5]))"); return }
        let childID = child.id.uuidString.lowercased()
        try frames([.vault(.walletSession), .vault(.sealWalletRequest(session: childID, digest: digest))]).write(to: childRequests)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("go2").path, contents: nil)
        #expect(eventually { answered(childAnswers, 2...3) })
        FileManager.default.createFile(atPath: folder.appendingPathComponent("stop2").path, contents: nil)
        let fromChild = try replies(Data(contentsOf: childAnswers))
        #expect(fromChild[2] == .vault(.session(childID)), "\(String(describing: fromChild[2]))")
        #expect(refused(fromChild[3]), "\(String(describing: fromChild[3]))")

        // A process outside every session is placed in none, and gets no seal.
        let outside = folder.appendingPathComponent("outside.bin")
        try frames([.vault(.walletSession), .vault(.sealWalletRequest(session: mine, digest: digest))]).write(to: outside)
        let fromOutside = try ask(host, outside, expecting: 2...3)
        #expect(refused(fromOutside[2]) && refused(fromOutside[3]))
    }
}
