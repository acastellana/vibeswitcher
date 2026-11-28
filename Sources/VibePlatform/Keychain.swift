import Foundation

extension Platform {
    /// A key kept in the user's login Keychain, for the session host's vault: given without asking only to the binary
    /// that made it.
    ///
    /// The Mac's forms are the `SecItem` calls of the host's `VaultStorage`, moved here unchanged (Keychain+Darwin.swift).
    /// Linux has no Keychain: `key` is nil and `remove` does nothing (Keychain+Linux.swift), so the vault lives in the
    /// host's memory only (the stage 2 plan's S2-D3, the user's decision 3).
    public enum Keychain {
        /// What reading a key came to (`read`).
        public enum Read: Sendable {
            /// The key's bytes; `made`: added on this read, the Keychain holding no such item before.
            case found(Data, made: Bool)
            /// The Keychain's status (an `OSStatus`) that kept it: any answer but the item with its `size` bytes
            /// (`notAKey` for one of another size), or no item and the add failing.
            case unreadable(Int32)
        }

        /// The key of `size` bytes kept as the generic password `service`/`account`; the first time (the Keychain said
        /// it had none), `make`'s bytes, added under `label`. Never asks the user: `unreadable`, with the status, when
        /// the Keychain won't give it without asking, or when one of another size is kept there. Linux: nil (no
        /// Keychain), and `make` isn't called.
        public static func read(service: String, account: String, label: String, size: Int, make: () -> Data) -> Read? {
            System.read(service: service, account: account, label: label, size: size, make: make)
        }

        /// The status `read` gives for an item whose data isn't a key of the size asked for (the Keychain itself said
        /// success): the Mac's `errSecDecode`.
        public static let notAKey: Int32 = System.notAKey

        /// Removes the generic password `service`/`account`, if there is one. Linux: nothing to remove.
        public static func remove(service: String, account: String) {
            System.remove(service: service, account: account)
        }
    }
}
