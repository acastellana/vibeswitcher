import Foundation

extension Platform {
    /// A key kept in the user's login Keychain, for the session host's vault: given without asking only to the binary
    /// that made it.
    ///
    /// The Mac's forms are the `SecItem` calls of the host's `VaultStorage`, moved here unchanged (Keychain+Darwin.swift).
    /// Linux has no Keychain: `key` is nil and `remove` does nothing (Keychain+Linux.swift), so the vault lives in the
    /// host's memory only (the stage 2 plan's S2-D3, the user's decision 3).
    public enum Keychain {
        /// The key of `size` bytes kept as the generic password `service`/`account`; the first time, `make`'s bytes,
        /// added under `label`. Never asks the user: nil when the Keychain won't give it without asking, or when one
        /// of another size is kept there. Linux: nil, and `make` isn't called.
        public static func key(service: String, account: String, label: String, size: Int, make: () -> Data) -> Data? {
            System.key(service: service, account: account, label: label, size: size, make: make)
        }

        /// Removes the generic password `service`/`account`, if there is one. Linux: nothing to remove.
        public static func remove(service: String, account: String) {
            System.remove(service: service, account: account)
        }
    }
}
