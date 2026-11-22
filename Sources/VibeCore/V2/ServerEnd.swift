import Foundation

extension HostNotes {
    /// How the host's server child last ended on its own (not a replacement for a new build's server, nor the host's
    /// stop): when, how long it had run, and its wait status in words (the app's crash reports, which a node hasn't:
    /// the parity table's health row). The host's log has each end as a line too (`ServerChild.ended`).
    public struct ServerEnd: Codable, Equatable, Sendable {
        public var at: Date
        /// Seconds it ran.
        public var ran: Double
        /// "killed by signal 11 (SIGSEGV), core dumped", "exited with code 1".
        public var cause: String

        public init(at: Date, ran: Double, cause: String) {
            self.at = at
            self.ran = ran
            self.cause = cause
        }

        /// A wait status in words.
        public static func cause(status: Int32) -> String {
            let signal = status & 0x7f
            guard signal != 0 else { return "exited with code \((status >> 8) & 0xff)" }
            return "killed by signal \(signal) (\(HostSession.Exit.signalName(signal)))" + (status & 0x80 != 0 ? ", core dumped" : "")
        }
    }
}
