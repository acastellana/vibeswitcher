#if os(Linux)
// Linux's TCP socket, close-on-exec from the call that makes it (`SOCK_CLOEXEC`), so no program another thread starts
// in between holds it. glibc's socket types are an enum to Swift, musl's are numbers.
extension Platform.TCP {
    /// `socket(family, SOCK_STREAM | SOCK_CLOEXEC, 0)`: -1 and errno, as the call.
    static func makeSocket(_ family: Family) -> Int32 {
        #if canImport(Glibc)
        socket(family.domain, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        #else
        socket(family.domain, SOCK_STREAM | SOCK_CLOEXEC, 0)
        #endif
    }

    // The egress proxy's two forms (the session sandbox plan's SB9): the one place a name is resolved, and a connect
    // with a bound on its wait. What may be connected to is judged above this layer (`EgressRules`), on bytes.

    /// The addresses `name` resolves to through the system's resolver (getaddrinfo, any family, stream sockets), each
    /// once, in the order given: 4 bytes for IPv4, 16 for IPv6. Fails with EHOSTUNREACH when the resolver has no
    /// answer (its own error isn't an errno), or with the call's errno.
    public static func resolve(_ name: String) -> Result<[[UInt8]], Platform.Errno> {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(name, nil, &hints, &list)
        guard status == 0 else { return .failure(Platform.Errno(code: status == EAI_SYSTEM ? errno : EHOSTUNREACH)) }
        defer { freeaddrinfo(list) }
        var found: [[UInt8]] = []
        var entry = list
        while let here = entry {
            if let address = here.pointee.ai_addr {
                var bytes: [UInt8] = []
                if here.pointee.ai_family == AF_INET {
                    address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inet in
                        bytes = withUnsafeBytes(of: inet.pointee.sin_addr) { Array($0) }
                    }
                } else if here.pointee.ai_family == AF_INET6 {
                    address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { inet in
                        bytes = withUnsafeBytes(of: inet.pointee.sin6_addr) { Array($0) }
                    }
                }
                if !bytes.isEmpty, !found.contains(bytes) { found.append(bytes) }
            }
            entry = here.pointee.ai_next
        }
        return .success(found)
    }

    /// A stream socket of `address`'s family (4 or 16 bytes), close-on-exec, connected to `address` at `port` within
    /// `timeout`, and left blocking. Fails with the call's errno (ETIMEDOUT past the wait, EINVAL for an address of
    /// another length), nothing left open.
    public static func connect(to address: [UInt8], port: UInt16, timeout: Double) -> Result<Int32, Platform.Errno> {
        guard address.count == 4 || address.count == 16 else { return .failure(Platform.Errno(code: EINVAL)) }
        let family = address.count == 4 ? AF_INET : AF_INET6
        #if canImport(Glibc)
        let fd = socket(family, Int32(SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue | SOCK_NONBLOCK.rawValue), 0)
        #else
        let fd = socket(family, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0)
        #endif
        guard fd >= 0 else { return .failure(Platform.Errno(code: errno)) }
        func failed(_ code: Int32) -> Result<Int32, Platform.Errno> {
            Sys.close(fd)
            return .failure(Platform.Errno(code: code))
        }
        var started: Int32
        if address.count == 4 {
            var inet = sockaddr_in()
            inet.sin_family = sa_family_t(AF_INET)
            inet.sin_port = port.bigEndian
            withUnsafeMutableBytes(of: &inet.sin_addr) { $0.copyBytes(from: address) }
            started = withUnsafePointer(to: &inet) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Sys.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        } else {
            var inet = sockaddr_in6()
            inet.sin6_family = sa_family_t(AF_INET6)
            inet.sin6_port = port.bigEndian
            withUnsafeMutableBytes(of: &inet.sin6_addr) { $0.copyBytes(from: address) }
            started = withUnsafePointer(to: &inet) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Sys.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        }
        if started != 0 {
            guard errno == EINPROGRESS else { return failed(errno) }
            var waiting = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&waiting, 1, Int32(max(0, min(timeout * 1_000, Double(Int32.max)))))
            guard ready > 0 else { return failed(ready == 0 ? ETIMEDOUT : errno) }
            var problem: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &problem, &length) == 0 else { return failed(errno) }
            guard problem == 0 else { return failed(problem) }
        }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else { return failed(errno) }
        return .success(fd)
    }
}
#endif
