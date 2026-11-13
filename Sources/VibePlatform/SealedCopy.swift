extension Platform.ProcessSelf {
    /// An image read once into memory and sealed there (the security document's S6 and S9): what the host starts
    /// instead of a path on disk, so that nothing written to the file after the read is ever run, and so that the
    /// process started from it is non-dumpable from its exec on.
    ///
    /// The second is the kernel's own rule: `execve` leaves a process dumpable only when it may read the image it
    /// runs. A copy of an ELF image is made `0111`, executable by its owner and readable by nobody, so its child is
    /// out of reach of the user's other processes (`ptrace`, `/proc/<pid>/mem`, `pidfd_getfd`) from its first
    /// instruction. Nobody but the process that made it holds the copy, and that process is non-dumpable, so nobody
    /// else can `chmod` it back: the seals keep its bytes, the mode keeps it unreadable.
    ///
    /// A script can't be run from an unreadable copy (its interpreter reads it by path and is refused, "cannot open
    /// /proc/self/fd/3: Permission denied"), so a script's copy is `0555` and `isScript`; only tests run scripts.
    ///
    /// **How one is started.** As a child, through `Platform.Spawn` with `executable: copy.path` and
    /// `keep: [copy.fd]`, and `VIBESWITCHER_IMAGE_FD` (`imageVariable`) set to its number: Linux's spawn closes
    /// every descriptor from 3 up before `execve` resolves the path, so a copy not kept makes its path vanish. In
    /// place, through `Platform.Spawn(…).replaceProcess()`, kept the same way when the new image needs it. Either
    /// way the first act of the image it starts is `closeInheritedImage()`, so no program after it (a session's,
    /// which stays dumpable) ever holds a copy.
    ///
    /// The Mac has none: `sealedCopy(of:name:)` fails with `ENOTSUP` there, and every caller keeps its path.
    public struct SealedCopy: Equatable, Sendable {
        /// The copy's descriptor, close-on-exec: the copy's holder closes it.
        public let fd: Int32
        /// Its bytes' count: what was read, not what the file's size said.
        public let size: Int
        /// Whether it is anything but an ELF image (its first bytes aren't `\x7fELF`), and so was left `0555`.
        public let isScript: Bool

        init(fd: Int32, size: Int, isScript: Bool) {
            self.fd = fd
            self.size = size
            self.isScript = isScript
        }

        /// The path to start it by: this process's link to its descriptor, `/proc/self/fd/<fd>`, which names the
        /// same copy in a child that kept the descriptor.
        public var path: String { "/proc/self/fd/\(fd)" }

        /// `body` given the copy's bytes, read through its own descriptor (a read-only private mapping), so that a
        /// hash taken here is of the bytes that run. A copy that can't be mapped (an empty one) is read instead.
        public func withBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
            if size > 0, let mapped = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), mapped != MAP_FAILED {
                defer { munmap(mapped, size) }
                return try body(UnsafeRawBufferPointer(start: mapped, count: size))
            }
            var bytes = [UInt8](repeating: 0, count: size)
            var done = 0
            while done < size {
                let count = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + done, size - done, off_t(done)) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                done += count
            }
            return try bytes.withUnsafeBytes { try body(UnsafeRawBufferPointer(rebasing: $0[0..<done])) }
        }
    }

    /// The environment variable that names, to an image started from a sealed copy, the descriptor of its copy.
    public static let imageVariable = "VIBESWITCHER_IMAGE_FD"

    /// Whether `bytes` begin an ELF image (`\x7fELF`): the copies that are made unreadable.
    static func isELF(_ bytes: some Collection<UInt8>) -> Bool {
        Array(bytes.prefix(4)) == [0x7f, 0x45, 0x4c, 0x46]
    }
}
