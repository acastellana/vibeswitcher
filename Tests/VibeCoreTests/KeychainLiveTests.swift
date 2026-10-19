import CryptoKit
import Foundation
import Security
import Testing
@testable import VibeCore

/// The one test of the real Keychain (`AppProof.KeychainStore`), in your own HOME's login keychain, run only when you
/// ask for it: `VIBESWITCHER_KEYCHAIN_LIVE=1 swift test --filter KeychainLiveTests`. Every other run skips it: under a
/// scratch HOME (every worker's and verifier's `swift test`, the load harness) there's no login keychain, and macOS
/// answers a SecItem call for one with a "Keychain Not Found" dialog, not an error. It makes an item of its own
/// service (never the app's), and deletes it.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VIBESWITCHER_KEYCHAIN_LIVE"] == "1"))
struct KeychainLiveTests {
    /// The key is made the first time and the same one comes back; only this program's code reads the item without
    /// macOS asking: its access lists one application, never none (none would be any application).
    /// `security find-generic-password -w` in a worker's shell is another program, so macOS asks you first.
    @Test func theKeychainItemIsTheAppsAlone() throws {
        let service = "dev.vibeswitcher.app-proof.test-\(UUID().uuidString.prefix(8))"
        let store = AppProof.KeychainStore(service: service)
        defer {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                           kSecAttrAccount as String: store.account] as CFDictionary)
        }
        let key = try #require(store.key())
        #expect(key.data.count == AppProof.keySize)
        #expect(store.key()?.data == key.data)

        var found: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnRef as String: true]
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
