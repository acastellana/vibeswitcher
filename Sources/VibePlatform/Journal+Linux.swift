#if os(Linux)
import Foundation
// Linux's journal: one datagram on a Unix socket of its own, close-on-exec from its making, to journald's socket path.
extension Platform.Journal {
    enum System {
        static func send(_ datagram: Data, to socket: String) -> Bool {
            guard var address = Platform.Sockets.unixAddress(socket) else { return false }
            #if canImport(Glibc)
            let datagramType = Int32(SOCK_DGRAM.rawValue)
            #else
            let datagramType = SOCK_DGRAM
            #endif
            let fd = Platform.Sockets.makeSocket(type: datagramType)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            let sent = datagram.withUnsafeBytes { bytes in
                withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes.baseAddress, bytes.count, Int32(MSG_NOSIGNAL), $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
            }
            return sent == datagram.count
        }
    }
}
#endif
