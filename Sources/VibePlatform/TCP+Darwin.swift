#if canImport(Darwin)
// The Mac's TCP for the egress proxy: none. The Mac has no session sandbox, so no proxy runs there (the session sandbox
// plan's "The Mac"); each form fails with ENOTSUP and makes nothing.
extension Platform.TCP {
    public static func resolve(_ name: String) -> Result<[[UInt8]], Platform.Errno> { .failure(Platform.Errno(code: ENOTSUP)) }

    public static func connect(to address: [UInt8], port: UInt16, timeout: Double) -> Result<Int32, Platform.Errno> {
        .failure(Platform.Errno(code: ENOTSUP))
    }

    public static func listenOnLoopback(port: UInt16 = 0) -> Result<(fd: Int32, port: UInt16), Platform.Errno> {
        .failure(Platform.Errno(code: ENOTSUP))
    }

    public static func localPort(_ fd: Int32) -> UInt16? { nil }
}
#endif
