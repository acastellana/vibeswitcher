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
}
#endif
