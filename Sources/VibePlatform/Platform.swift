/// Every system call the shared code makes: static functions, each with one implementation per system (the Mac,
/// Linux on glibc and on musl). Outside this module no file of the portable targets imports the C library or an
/// Apple-only framework, or asks which system it is on (`PlatformLintTests`).
public enum Platform {}

extension Platform {
    /// Why a system call failed: its error number (`errno`, or what the call itself returned, as posix_spawn does).
    /// The numbers differ between systems (EAGAIN is 35 on the Mac and 11 on Linux): compare with the constants.
    public struct Errno: Error, Equatable {
        public var code: Int32

        public init(code: Int32) {
            self.code = code
        }
    }
}
