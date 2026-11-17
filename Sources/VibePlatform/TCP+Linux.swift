#if os(Linux)
// Linux's TCP for the egress proxy: getaddrinfo, and sockets close-on-exec from the call that makes them
// (SOCK_CLOEXEC; the accept is the shim's accept4, which takes any family).
extension Platform.TCP {
    /// The addresses `name` resolves to through the system's resolver (getaddrinfo, any family, stream sockets), each
    /// once, in the order given: 4 bytes for IPv4, 16 for IPv6. Fails with EHOSTUNREACH when the resolver has no
    /// answer (its own error isn't an errno), or with the call's errno.
    public static func resolve(_ name: String) -> Result<[[UInt8]], Platform.Errno> {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
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
        let fd = socket(family, Int32(SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue | SOCK_NONBLOCK.rawValue), 0)
        guard fd >= 0 else { return .failure(Platform.Errno(code: errno)) }
        func failed(_ code: Int32) -> Result<Int32, Platform.Errno> {
            close(fd)
            return .failure(Platform.Errno(code: code))
        }
        var started: Int32
        if address.count == 4 {
            var inet = sockaddr_in()
            inet.sin_family = sa_family_t(AF_INET)
            inet.sin_port = port.bigEndian
            withUnsafeMutableBytes(of: &inet.sin_addr) { $0.copyBytes(from: address) }
            started = withUnsafePointer(to: &inet) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        } else {
            var inet = sockaddr_in6()
            inet.sin6_family = sa_family_t(AF_INET6)
            inet.sin6_port = port.bigEndian
            withUnsafeMutableBytes(of: &inet.sin6_addr) { $0.copyBytes(from: address) }
            started = withUnsafePointer(to: &inet) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
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

    /// A listener on 127.0.0.1 at `port` (0: one the kernel picks), close-on-exec, with its port. Fails with the
    /// call's errno, nothing left open.
    public static func listenOnLoopback(port: UInt16 = 0) -> Result<(fd: Int32, port: UInt16), Platform.Errno> {
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue), 0)
        guard fd >= 0 else { return .failure(Platform.Errno(code: errno)) }
        var inet = sockaddr_in()
        inet.sin_family = sa_family_t(AF_INET)
        inet.sin_port = port.bigEndian
        inet.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        let bound = withUnsafePointer(to: &inet) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 64) == 0, let given = localPort(fd) else {
            let code = errno
            close(fd)
            return .failure(Platform.Errno(code: code))
        }
        return .success((fd, given))
    }

    /// The local port of the TCP socket `fd`; nil when it has none or isn't one.
    public static func localPort(_ fd: Int32) -> UInt16? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return nil }
        switch Int32(storage.ss_family) {
        case AF_INET: return withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) } }
        case AF_INET6: return withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) } }
        default: return nil
        }
    }
}
#endif
