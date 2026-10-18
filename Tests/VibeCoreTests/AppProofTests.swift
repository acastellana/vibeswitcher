import CryptoKit
import Foundation
import Security
import Testing
@testable import VibeCore

/// The app's key and its answers (see `AppProof`), with the Keychain item in a scratch keychain, never the login one.
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

    /// Only this program's code reads the item without macOS asking: its access lists one application, never none
    /// (none would be any application). `security find-generic-password -w` in a worker's shell is another program,
    /// so macOS asks you first.
    @Test func theKeychainItemIsTheAppsAlone() throws {
        let folder = scratchRoot.appendingPathComponent("app-proof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let password = UUID().uuidString
        var made: SecKeychain?
        let path = folder.appendingPathComponent("scratch.keychain-db").path
        guard SecKeychainCreate(path, UInt32(password.utf8.count), password, false, nil, &made) == errSecSuccess, let keychain = made else {
            Issue.record("no scratch keychain"); return
        }
        defer { SecKeychainDelete(keychain) }
        let service = "dev.vibeswitcher.app-proof.test-\(UUID().uuidString.prefix(8))"
        let key = try #require(AppProof.keychainKey(service: service, keychain: keychain))
        // The same key the next time.
        #expect(AppProof.keychainKey(service: service, keychain: keychain)?.data == key.data)

        var found: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecMatchSearchList as String: [keychain], kSecReturnRef as String: true]
        #expect(SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess)
        // swiftlint:disable:next force_cast
        let item = found as! SecKeychainItem
        var access: SecAccess?
        #expect(SecKeychainItemCopyAccess(item, &access) == errSecSuccess)
        let acls = (SecAccessCopyMatchingACLList(try #require(access), kSecACLAuthorizationDecrypt) as? [SecACL]) ?? []
        #expect(!acls.isEmpty)
        let me = try #require(HostServerPaths.executable(of: getpid()))
        for acl in acls {
            var applications: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            #expect(SecACLCopyContents(acl, &applications, &description, &prompt) == errSecSuccess)
            let trusted = try #require(applications as? [SecTrustedApplication], "an ACL open to any application")
            let paths = trusted.compactMap { app -> String? in
                var data: CFData?
                guard SecTrustedApplicationCopyData(app, &data) == errSecSuccess, let data = data as Data? else { return nil }
                return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
            }
            #expect(paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == [URL(fileURLWithPath: me).resolvingSymlinksInPath().path])
        }
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
