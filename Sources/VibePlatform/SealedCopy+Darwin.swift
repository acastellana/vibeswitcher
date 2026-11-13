#if canImport(Darwin)
// The Mac has no sealed copies: no memfd, and its code signature, not an unreadable image, is what keeps a process's
// memory from the user's other processes. Every caller keeps today's path to the file.
extension Platform.ProcessSelf {
    /// `ENOTSUP`: the Mac has no sealed copies, and the caller starts the file at `path` as it does today.
    public static func sealedCopy(of path: String, name: String) -> Result<SealedCopy, Platform.Errno> {
        .failure(Platform.Errno(code: ENOTSUP))
    }

    /// nil: nothing on the Mac is a sealed copy.
    public static func adopt(_ fd: Int32) -> SealedCopy? {
        nil
    }

    /// nil, and the environment left as it is: nothing on the Mac starts an image from a sealed copy.
    public static func takeInheritedImage() -> Int32? {
        nil
    }

    /// Nothing, and nil: nothing on the Mac starts an image from a sealed copy, so there is none to close.
    @discardableResult
    public static func closeInheritedImage() -> Int32? {
        nil
    }
}
#endif
