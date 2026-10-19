import CryptoKit
import Foundation
import Testing
@testable import VibeCore

/// The app's answers (see `AppProof`). Its Keychain item is `KeychainLiveTests`' alone, run only when asked for.
struct AppProofTests {
    @Test func anAnswerHoldsOnlyForItsChallengeAndKey() {
        let key = SymmetricKey(size: .bits256)
        let challenge = AppProof.challenge(), another = AppProof.challenge()
        #expect(challenge != another && challenge.count == 32)
        let answer = AppProof.answer(challenge, key: key)
        #expect(AppProof.isValid(answer, to: challenge, key: key))
        #expect(!AppProof.isValid(answer, to: another, key: key))
        #expect(!AppProof.isValid(answer, to: challenge, key: SymmetricKey(size: .bits256)))
        #expect(!AppProof.isValid(challenge, to: challenge, key: key))
    }
}

/// The executable a process runs.
enum HostServerPaths {
    static func executable(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
