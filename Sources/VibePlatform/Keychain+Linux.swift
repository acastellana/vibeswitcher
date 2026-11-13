#if os(Linux)
import Foundation

// Linux's Keychain: none. Nothing here keeps a key that only the host is given, so the host's vault lives in its
// memory only (the stage 2 plan's S2-D3): a key file a worker could read comes after the sandbox, in strong mode.
extension Platform.Keychain {
    enum System {
        /// nil: no Keychain to keep it in.
        static func key(service: String, account: String, label: String, size: Int, make: () -> Data) -> Data? { nil }

        /// Nothing: there is nothing kept.
        static func remove(service: String, account: String) {}
    }
}
#endif
