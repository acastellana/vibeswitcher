#if canImport(Darwin)
import Foundation
// The Mac has no journald: nothing is sent, and the caller is told so.
extension Platform.Journal {
    enum System {
        static func send(_ datagram: Data, to socket: String) -> Bool { false }
    }
}
#endif
