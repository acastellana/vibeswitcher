import Foundation
import Testing
@testable import VibePlatform

/// `Platform.Approval`: Linux has none, and says so without showing anything; on the Mac whether it could ask is read
/// without a dialog (`canEvaluatePolicy`). No test asks (`ApprovalLintTests`): an ask puts a dialog on the screen of the
/// person at the Mac, and a hosted runner has no one to answer it.
struct ApprovalTests {
    @Test func linuxHasNoneAndTheMacSaysWithoutAsking() {
        if Platform.CodeIdentity.isAvailable {
            // Whatever the runner has (no Touch ID, perhaps a password), the answer comes and nothing is shown.
            _ = Platform.Approval.availability()
        } else {
            let why = Platform.Approval.availability()
            #expect(why?.contains("no LocalAuthentication") == true)
        }
    }

    /// An empty reason is declined before anything is asked, on both systems: the dialog needs one, and a request with
    /// nothing to agree to is no one's.
    @Test func anEmptyReasonIsDeclinedUnasked() {
        #expect(Platform.Approval.ask("", timeout: 1) == .declined("nothing to agree to: the reason is empty"))
    }
}

/// No test asks the person at the Mac (the repository's hard rules: nothing a test does may put a dialog on the
/// user's screen): only `anEmptyReasonIsDeclinedUnasked` calls `Platform.Approval.ask`, with an empty reason, which
/// never reaches the system; no test makes the voice's system authenticator.
struct ApprovalLintTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func noTestAsksThePersonAtTheMac() throws {
        let tests = Self.repo.appendingPathComponent("Tests")
        let files = FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)
        var asking: [String] = []
        for file in files where file.lastPathComponent != "ApprovalTests.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.components(separatedBy: "\n") where line.contains("Approval.ask(") || line.contains("ApprovalVoice.System(")
                || line.contains("LAContext") {
                asking.append("\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(asking.isEmpty, "\(asking)")
        let own = try String(contentsOf: tests.appendingPathComponent("VibePlatformTests/ApprovalTests.swift"), encoding: .utf8)
        // Here, one call: an empty reason, which `ask` declines before the system is reached.
        let needle = "Platform.Approval" + ".ask("
        let calls = own.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.contains(needle) && !$0.hasPrefix("///") }
        #expect(calls.count == 1 && calls.allSatisfy { $0.hasPrefix("#expect(" + needle + "\"\", ") }, "\(calls)")
    }
}
