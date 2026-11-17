import Foundation

extension Platform {
    /// TCP sockets on a numeric address, for the node's web listener and whatever connects to it: a listener, a
    /// connection, and what an accepted connection is given. No name is ever resolved: an address is IPv4's dotted
    /// form or IPv6's, as `inet_pton` reads them, and anything else is `.notAnAddress`.
    ///
    /// Each system makes the socket in a file of its own (TCP+Linux.swift, TCP+Darwin.swift), close-on-exec: Linux from
    /// the call that makes it (`SOCK_CLOEXEC`), the Mac right after it. A connection taken from a listener comes
    /// through `Platform.Sockets.accept`, close-on-exec the same way.
    public enum TCP {
        public enum Family: Sendable, Equatable {
            case ipv4, ipv6

            var domain: Int32 { self == .ipv4 ? AF_INET : AF_INET6 }
        }

        public enum Failure: Error, Equatable, CustomStringConvertible {
            /// Not a numeric address of the family.
            case notAnAddress
            /// The call that failed and its errno.
            case system(String, Int32)

            public var description: String {
                switch self {
                case .notAnAddress: return "not a numeric address"
                case .system(let call, let code): return "\(call): \(String(cString: strerror(code)))"
                }
            }
        }

        /// Whether `address` is a numeric address of `family` on this machine's loopback: 127.0.0.0/8, or ::1 alone
        /// (an IPv4 address written as IPv6, `::ffff:127.0.0.1`, is not). False for what isn't an address.
        public static func isLoopback(family: Family, address: String) -> Bool {
            switch family {
            case .ipv4:
                var parsed = in_addr()
                guard inet_pton(AF_INET, address, &parsed) == 1 else { return false }
                // Network order: the first byte in memory is the first number written.
                return withUnsafeBytes(of: &parsed) { $0[0] == 127 }
            case .ipv6:
                var parsed = in6_addr()
                guard inet_pton(AF_INET6, address, &parsed) == 1 else { return false }
                return withUnsafeBytes(of: &parsed) { bytes in bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1 }
            }
        }

        /// A socket listening on `address`:`port` (0: a port the system picks, `localPort` says which): close-on-exec,
        /// nonblocking, `SO_REUSEADDR` (a listener closed a moment ago doesn't keep its port from the next), and for
        /// IPv6 that family alone (`IPV6_V6ONLY`). The caller closes it.
        public static func listen(family: Family, address: String, port: UInt16, backlog: Int32) -> Result<Int32, Failure> {
            let fd = makeSocket(family)
            guard fd >= 0 else { return .failure(.system("socket", errno)) }
            var on: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
            if family == .ipv6 {
                _ = setsockopt(fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
            }
            let bound = withAddress(family: family, address: address, port: port) { bind(fd, $0, $1) }
            guard let bound else {
                Sys.close(fd)
                return .failure(.notAnAddress)
            }
            guard bound == 0 else {
                let code = errno
                Sys.close(fd)
                return .failure(.system("bind", code))
            }
            guard Sys.listen(fd, backlog) == 0 else {
                let code = errno
                Sys.close(fd)
                return .failure(.system("listen", code))
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            return .success(fd)
        }

        /// A socket connected to `address`:`port`, close-on-exec and blocking, with no SIGPIPE on a write to a peer
        /// that has gone (the Mac's own option; Linux's writes through `Platform.Sockets.send` say so each). The
        /// connect waits as connect(2) does. The caller closes it.
        public static func connect(family: Family, address: String, port: UInt16) -> Result<Int32, Failure> {
            let fd = makeSocket(family)
            guard fd >= 0 else { return .failure(.system("socket", errno)) }
            let result = withAddress(family: family, address: address, port: port) { Sys.connect(fd, $0, $1) }
            var code = errno
            guard let result else {
                Sys.close(fd)
                return .failure(.notAnAddress)
            }
            if result != 0, code == EINTR {
                // A signal came while it waited: the connect goes on, and the socket is writable once it has ended,
                // one way or the other (`SO_ERROR` says which).
                var waiting = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                var ready: Int32
                repeat { ready = poll(&waiting, 1, -1) } while ready < 0 && errno == EINTR
                var length = socklen_t(MemoryLayout<Int32>.size)
                if ready < 0 || getsockopt(fd, SOL_SOCKET, SO_ERROR, &code, &length) != 0 { code = errno }
            } else if result == 0 {
                code = 0
            }
            guard code == 0 else {
                Sys.close(fd)
                return .failure(.system("connect", code))
            }
            Platform.Sockets.noSigPipe(socket: fd)
            return .success(fd)
        }

        /// What a connection taken from a listener is given: nonblocking, no SIGPIPE on a write to a peer that has
        /// gone, and what is written sent at once, not held for more (`TCP_NODELAY`: a key's echo is one small write).
        public static func configure(_ fd: Int32) {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            Platform.Sockets.noSigPipe(socket: fd)
            var on: Int32 = 1
            _ = setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        }

        /// Nothing more is written to `fd`: the peer reads what was sent, then the end (`shutdown(SHUT_WR)`). What
        /// the peer sends is still read.
        public static func endWrites(_ fd: Int32) {
            _ = shutdown(fd, Int32(SHUT_WR))
        }

        /// The port `fd` is bound to on this machine: a listener's, or a connection's own end. Nil when `fd` isn't a
        /// TCP socket (or isn't open).
        public static func localPort(_ fd: Int32) -> UInt16? {
            port(of: fd) { getsockname($0, $1, $2) }
        }

        /// The address `fd` is bound to on this machine, written as numbers ("127.0.0.1", "::1"). Nil when `fd` isn't a
        /// TCP socket.
        public static func localAddress(_ fd: Int32) -> String? {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let answered = withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            guard answered == 0 else { return nil }
            var text = [CChar](repeating: 0, count: 64)
            let size = socklen_t(text.count)
            let written = withUnsafePointer(to: &storage) { stored -> Bool in
                switch Int32(stored.pointee.ss_family) {
                case AF_INET:
                    return stored.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        var address = $0.pointee.sin_addr
                        return inet_ntop(AF_INET, &address, &text, size) != nil
                    }
                case AF_INET6:
                    return stored.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                        var address = $0.pointee.sin6_addr
                        return inet_ntop(AF_INET6, &address, &text, size) != nil
                    }
                default:
                    return false
                }
            }
            return written ? text.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : nil
        }

        /// The port at the other end of the connection `fd`. Nil when `fd` isn't a connected TCP socket.
        public static func peerPort(_ fd: Int32) -> UInt16? {
            port(of: fd) { getpeername($0, $1, $2) }
        }

        /// The port in the address `ask` fills for `fd` (`getsockname`, `getpeername`), of either family.
        private static func port(of fd: Int32, _ ask: (Int32, UnsafeMutablePointer<sockaddr>, UnsafeMutablePointer<socklen_t>) -> Int32) -> UInt16? {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let answered = withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ask(fd, $0, &length) }
            }
            guard answered == 0 else { return nil }
            return withUnsafePointer(to: &storage) { stored -> UInt16? in
                switch Int32(stored.pointee.ss_family) {
                case AF_INET:
                    return stored.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
                case AF_INET6:
                    return stored.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
                default:
                    return nil
                }
            }
        }

        /// Calls `body` with the socket address of `address`:`port`; nil, and no call, when `address` isn't a numeric
        /// address of `family`. The Mac's addresses also hold their own length.
        private static func withAddress<T>(family: Family, address: String, port: UInt16,
                                           _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
            switch family {
            case .ipv4:
                var made = sockaddr_in()
                made.sin_family = sa_family_t(AF_INET)
                made.sin_port = port.bigEndian
                guard inet_pton(AF_INET, address, &made.sin_addr) == 1 else { return nil }
                #if canImport(Darwin)
                made.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                #endif
                return withUnsafePointer(to: &made) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            case .ipv6:
                var made = sockaddr_in6()
                made.sin6_family = sa_family_t(AF_INET6)
                made.sin6_port = port.bigEndian
                guard inet_pton(AF_INET6, address, &made.sin6_addr) == 1 else { return nil }
                #if canImport(Darwin)
                made.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                #endif
                return withUnsafePointer(to: &made) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
                }
            }
        }
    }
}
