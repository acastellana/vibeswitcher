// The one place the C library is imported, exported so that every file of this module has it without an import of
// its own. On Linux the shim comes with it: what glibc and musl keep from Swift (Sources/CVibePlatform).
#if canImport(Darwin)
@_exported import Darwin
#elseif canImport(Glibc)
@_exported import Glibc
#elseif canImport(Musl)
@_exported import Musl
#endif
#if os(Linux)
@_exported import CVibePlatform
#endif
