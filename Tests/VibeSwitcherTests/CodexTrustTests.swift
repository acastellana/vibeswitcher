import Foundation
import Testing
@testable import VibeSwitcher

/// E-02: the app doesn't ignore SIGPIPE, so a Codex app-server that quits mid-handshake used to take VibeSwitcher
/// down with it on the next write. Each stand-in runs under `zsh -f` (no startup files).
struct CodexTrustTests {
    private func failure(_ script: String) -> Error? {
        do {
            try CodexTrust.trustOurHooks(timeout: hangGuard, arguments: ["-fc", script])
            return nil
        } catch { return error }
    }

    @Test func anAppServerThatQuitsAfterInitializeIsAnErrorNotACrash() {
        // Stops reading, answers `initialize`, quits: the next write finds no reader.
        let error = failure(#"exec 0<&-; print -r -- '{"jsonrpc":"2.0","id":1,"result":{}}'"#)
        #expect(error as? CodexTrust.Failure == .quit)
        #expect(error?.localizedDescription == "codex app-server quit before it was done")
    }

    @Test func anAppServerThatExitsAtOnceIsAnErrorNotACrash() {
        for _ in 0..<5 {
            let error = failure("exit 0")
            #expect(error as? CodexTrust.Failure == .quit || error as? CodexTrust.Failure == .timeout, "\(String(describing: error))")
        }
    }
}
