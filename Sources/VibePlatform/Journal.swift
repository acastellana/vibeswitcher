import Foundation

extension Platform {
    /// Entries for the journal, in journald's native form: one datagram to its socket, each field `NAME=value` and a
    /// newline, or, for a value that holds a newline, `NAME`, a newline, the value's length (8 bytes, little-endian),
    /// the value and a newline (systemd's `JOURNAL_NATIVE_PROTOCOL`). journald stamps the fields it trusts itself
    /// (`_UID`, `_PID`, `_SYSTEMD_CGROUP`, …) from the sender's credentials, so a field the sender names may not start
    /// with `_`: such an entry is refused here, as journald would drop the field (the engine plan's EN-D15: an entry
    /// counts for what journald's own fields say, never for an identifier it carries).
    ///
    /// The command line writes its entries this way (a start, a stop, an acknowledgment, an accepted request: ids and
    /// hashes only), to `systemSocket`, or a scratch node's `<root>/v2/test/journal.sock` (the engine plan's Global
    /// Constraints: a scratch node never writes to the user's journal). Linux's form is Journal+Linux.swift; the Mac's
    /// does nothing (no journald there).
    public enum Journal {
        /// journald's own socket for native entries.
        public static let systemSocket = "/run/systemd/journal/socket"

        /// The longest datagram `send` makes (journald takes larger ones only through a memory file).
        public static let largest = 64 * 1024

        /// Whether `name` is a field a sender may name: 1 to 64 of `A`–`Z`, `0`–`9` and `_`, not starting with `_` (a
        /// trusted field, journald's own) or a digit.
        public static func mayName(_ name: String) -> Bool {
            guard (1...64).contains(name.utf8.count), let first = name.utf8.first,
                  first != UInt8(ascii: "_"), !(UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first) else { return false }
            return name.utf8.allSatisfy {
                (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || $0 == UInt8(ascii: "_")
            }
        }

        /// The datagram for `fields`, in their order; nil when a name isn't one a sender may use (`mayName`), or the
        /// whole is longer than `largest`.
        public static func encode(_ fields: [(name: String, value: String)]) -> Data? {
            var data = Data()
            for (name, value) in fields {
                guard mayName(name) else { return nil }
                let bytes = Data(value.utf8)
                if bytes.contains(UInt8(ascii: "\n")) {
                    data.append(contentsOf: Array(name.utf8) + [UInt8(ascii: "\n")])
                    var length = UInt64(bytes.count).littleEndian
                    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
                    data.append(bytes)
                } else {
                    data.append(contentsOf: Array(name.utf8) + [UInt8(ascii: "=")])
                    data.append(bytes)
                }
                data.append(UInt8(ascii: "\n"))
            }
            return data.count <= largest ? data : nil
        }

        /// The fields of a datagram in the native form, in order; nil when it isn't one. For a stand-in of journald
        /// (a test's recording socket).
        public static func decode(_ datagram: Data) -> [(name: String, value: String)]? {
            let bytes = [UInt8](datagram)
            var fields: [(name: String, value: String)] = []
            var index = 0
            while index < bytes.count {
                guard let end = bytes[index...].firstIndex(where: { $0 == UInt8(ascii: "\n") || $0 == UInt8(ascii: "=") }) else { return nil }
                let name = String(decoding: bytes[index..<end], as: UTF8.self)
                if bytes[end] == UInt8(ascii: "=") {
                    let stop = bytes[(end + 1)...].firstIndex(of: UInt8(ascii: "\n")) ?? bytes.count
                    fields.append((name, String(decoding: bytes[(end + 1)..<stop], as: UTF8.self)))
                    index = stop + 1
                } else {
                    guard end + 9 <= bytes.count else { return nil }
                    var length: UInt64 = 0
                    for (shift, byte) in bytes[(end + 1)..<(end + 9)].enumerated() { length |= UInt64(byte) << (8 * UInt64(shift)) }
                    let start = end + 9
                    guard length < UInt64(bytes.count - start), bytes[start + Int(length)] == UInt8(ascii: "\n") else { return nil }
                    fields.append((name, String(decoding: bytes[start..<(start + Int(length))], as: UTF8.self)))
                    index = start + Int(length) + 1
                }
            }
            return fields
        }

        /// Sends one entry of `fields` to the journal's socket at `socket` (`systemSocket`, or a scratch node's
        /// stand-in). True when the datagram went; false when `encode` refused it, the socket isn't there or the send
        /// failed, and always on the Mac.
        @discardableResult
        public static func send(_ fields: [(name: String, value: String)], to socket: String = systemSocket) -> Bool {
            guard let datagram = encode(fields) else { return false }
            return System.send(datagram, to: socket)
        }
    }
}
