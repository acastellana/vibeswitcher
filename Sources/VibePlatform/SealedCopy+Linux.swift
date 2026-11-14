#if os(Linux)
// Linux's sealed copies: a memfd (memfd_create, through the shim), its seals (fcntl's F_ADD_SEALS and F_GET_SEALS,
// through the shim) and its mode. Every descriptor here is close-on-exec from the call that makes it, and an
// inherited one is made so again when it is taken (`takeInheritedImage`) or adopted (`adopt`): it arrives without
// the flag, which `Spawn.keep` clears so that it survives the exec.
extension Platform.ProcessSelf {
    /// The seals every copy carries, and every adopted one must: its bytes can't be written, its size can't change,
    /// and no seal can be taken off or added.
    static let allSeals = VIBE_F_SEAL_WRITE | VIBE_F_SEAL_SHRINK | VIBE_F_SEAL_GROW | VIBE_F_SEAL_SEAL

    /// The mode of an ELF image's copy: executable by its owner, readable by nobody, so that its child is
    /// non-dumpable from its exec.
    static let imageMode: mode_t = 0o111
    /// The mode of a script's copy, which its interpreter must read.
    static let scriptMode: mode_t = 0o555

    /// The file at `path`, read once through one descriptor into a new memfd named `name` (`/memfd:<name>` in
    /// /proc's links), sealed (`allSeals`), and made `0111` for an ELF image or `0555` for anything else. The copy
    /// is what was read, whatever the file's size said and whatever is written to the file afterwards.
    ///
    /// `MFD_EXEC` is asked for where the kernel knows it (6.3 and up, with `vm.memfd_noexec`), and left out where it
    /// doesn't (EINVAL): this machine's 5.15 has no such switch, and executes any memfd.
    ///
    /// Fails with the call's errno, with nothing left open: the file can't be opened or read (ENOENT, EACCES), isn't
    /// a regular file (EINVAL), or the memfd can't be made, filled or sealed.
    ///
    /// The file is opened `O_NONBLOCK`, so that a FIFO put where an image was is refused at once rather than waited
    /// on until something writes to it (a worker could hold the host's start or its handover so); the flag changes
    /// nothing in reading a regular file.
    public static func sealedCopy(of path: String, name: String) -> Result<SealedCopy, Platform.Errno> {
        let source = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard source >= 0 else { return .failure(Platform.Errno(code: errno)) }
        defer { close(source) }
        var info = stat()
        guard fstat(source, &info) == 0 else { return .failure(Platform.Errno(code: errno)) }
        guard info.st_mode & S_IFMT == S_IFREG else { return .failure(Platform.Errno(code: EINVAL)) }
        return sealed(name) { pour(source, into: $0) }
    }

    /// A second, separate copy of `copy`'s bytes, named `name`: read through `copy`'s own descriptor
    /// (`withBytes`), so its holder can copy a copy it can't open by path, sealed the same way and given the same mode.
    /// For a holder that starts two kinds of children from one image and must keep what one kind can reach away from
    /// the other (the host's sessions' launchers and its parsers). Fails as `sealedCopy(of:name:)` does, nothing
    /// left open.
    public static func sealedCopy(of copy: SealedCopy, name: String) -> Result<SealedCopy, Platform.Errno> {
        sealed(name) { target in
            copy.withBytes { bytes -> Result<Int, Platform.Errno> in
                guard let base = bytes.baseAddress else { return .success(0) }
                var written = 0
                while written < bytes.count {
                    let wrote = write(target, base + written, bytes.count - written)
                    if wrote < 0, errno == EINTR { continue }
                    guard wrote > 0 else { return .failure(Platform.Errno(code: wrote < 0 ? errno : EIO)) }
                    written += wrote
                }
                return .success(written)
            }
        }
    }

    /// A new memfd named `name`, filled by `fill` (how many bytes), sealed (`allSeals`) and made `0111` for an ELF
    /// image or `0555` for anything else, as read back from the copy itself.
    private static func sealed(_ name: String, fill: (Int32) -> Result<Int, Platform.Errno>) -> Result<SealedCopy, Platform.Errno> {
        var copy = vibe_memfd_create(name, VIBE_MFD_CLOEXEC | VIBE_MFD_ALLOW_SEALING | VIBE_MFD_EXEC)
        if copy < 0, errno == EINVAL { copy = vibe_memfd_create(name, VIBE_MFD_CLOEXEC | VIBE_MFD_ALLOW_SEALING) }
        guard copy >= 0 else { return .failure(Platform.Errno(code: errno)) }
        func failed(_ code: Int32) -> Result<SealedCopy, Platform.Errno> {
            close(copy)
            return .failure(Platform.Errno(code: code))
        }

        let size: Int
        switch fill(copy) {
        case .failure(let error): return failed(error.code)
        case .success(let count): size = count
        }
        guard vibe_add_seals(copy, UInt32(allSeals)) == 0 else { return failed(errno) }
        // Read back from the copy itself: what runs, not what the file holds by now.
        var first = [UInt8](repeating: 0, count: 4)
        let read = pread(copy, &first, first.count, 0)
        guard read >= 0 else { return failed(errno) }
        let isScript = !isELF(first.prefix(read))
        guard fchmod(copy, isScript ? scriptMode : imageMode) == 0 else { return failed(errno) }
        return .success(SealedCopy(fd: copy, size: size, isScript: isScript))
    }

    /// Every byte `source` gives until its end, written to `target`: how many.
    private static func pour(_ source: Int32, into target: Int32) -> Result<Int, Platform.Errno> {
        let length = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: 16)
        defer { buffer.deallocate() }
        var total = 0
        while true {
            let count = read(source, buffer, length)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return .failure(Platform.Errno(code: errno)) }
            guard count > 0 else { return .success(total) }
            var written = 0
            while written < count {
                let wrote = write(target, buffer + written, count - written)
                if wrote < 0, errno == EINTR { continue }
                guard wrote > 0 else { return .failure(Platform.Errno(code: wrote < 0 ? errno : EIO)) }
                written += wrote
            }
            total += count
        }
    }

    /// The inherited descriptor `fd` as a sealed copy, only when it is one an image's holder made: a memfd with all
    /// four seals (`allSeals`) and mode `0111`, made close-on-exec again. nil for anything else (a plain memfd, a
    /// sealed one left readable, a file on disk, a descriptor that isn't open). A new image after a handover takes
    /// its own copy so (Task 9c); a scratch host whose inherited copy can't be adopted makes a fresh one of
    /// `/proc/self/exe`, and the user's host refuses to start.
    ///
    /// The flag matters because the adopter holds the copy for its whole life: a child it starts without closing
    /// from 3 up (`keep: nil`, or Foundation's `Process`) would otherwise inherit it writable, and a dumpable
    /// session program could `fchmod` it back to readable, so that the next image started from it is dumpable.
    public static func adopt(_ fd: Int32) -> SealedCopy? {
        let seals = vibe_get_seals(fd)
        guard seals >= 0, seals & allSeals == allSeals else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o7777 == imageMode else {
            return nil
        }
        guard markCloseOnExec(fd) else { return nil }
        return SealedCopy(fd: fd, size: Int(info.st_size), isScript: false)
    }

    /// Whether `fd` is a sealed copy (all four seals) with its own mode, `0111` for an ELF image and `0555` for
    /// anything else, once made so again if something changed it: a process of the user that reached the copy through
    /// a link to it (`/proc/<pid>/exe` of a dumpable process started from it) can `chmod` it, and the seals don't stop
    /// that. Its holder calls this before it starts a child from it, so that the child is non-dumpable from its exec
    /// again. False for anything else, or when the mode couldn't be put back.
    public static func restoreMode(of fd: Int32) -> Bool {
        let seals = vibe_get_seals(fd)
        guard seals >= 0, seals & allSeals == allSeals else { return false }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
        var first = [UInt8](repeating: 0, count: 4)
        let read = pread(fd, &first, first.count, 0)
        guard read >= 0 else { return false }
        let mode = isELF(first.prefix(read)) ? imageMode : scriptMode
        return info.st_mode & 0o7777 == mode || fchmod(fd, mode) == 0
    }

    /// The number `imageVariable` names, taken out of the environment, the descriptor left open and made
    /// close-on-exec: for an image that adopts its copy (`adopt`), and so that one it refuses doesn't reach its
    /// children either. nil when it's unset or not an open descriptor above 2.
    public static func takeInheritedImage() -> Int32? {
        guard let value = getenv(imageVariable).map({ String(cString: $0) }) else { return nil }
        unsetenv(imageVariable)
        guard let fd = Int32(value), fd > STDERR_FILENO, markCloseOnExec(fd) else { return nil }
        return fd
    }

    /// Whether `fd` is open and now close-on-exec.
    private static func markCloseOnExec(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFD)
        return flags >= 0 && (flags & FD_CLOEXEC != 0 || fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0)
    }

    /// The first act of every image a sealed copy starts: the copy it was started from, named by `imageVariable`,
    /// taken out of the environment and closed, so that no program it starts in turn (a session's, which is
    /// dumpable) holds it. Its number, or nil when there was none.
    @discardableResult
    public static func closeInheritedImage() -> Int32? {
        guard let fd = takeInheritedImage() else { return nil }
        close(fd)
        return fd
    }

    /// The mode of sealed memory that holds data, not an image: read by its owner only, through its own descriptor or
    /// by reopening `/proc/self/fd/N`, which a `0111` image's copy refuses.
    static let dataMode: mode_t = 0o400

    /// `bytes` in a new memfd named `name`, sealed (`allSeals`: nobody can change it, not even its maker) and made
    /// `0400`, close-on-exec: data a process hands to the image it executes in its place (the host's handover, S8),
    /// read back from offset 0 (`pread`) or by reopening `/proc/self/fd/N`, each from the beginning. Its descriptor,
    /// or the call's errno with nothing left open.
    public static func sealedMemory(_ bytes: UnsafeRawBufferPointer, name: String) -> Result<Int32, Platform.Errno> {
        let memory = vibe_memfd_create(name, VIBE_MFD_CLOEXEC | VIBE_MFD_ALLOW_SEALING)
        guard memory >= 0 else { return .failure(Platform.Errno(code: errno)) }
        func failed(_ code: Int32) -> Result<Int32, Platform.Errno> {
            close(memory)
            return .failure(Platform.Errno(code: code))
        }
        var written = 0
        while written < bytes.count, let base = bytes.baseAddress {
            let wrote = write(memory, base + written, bytes.count - written)
            if wrote < 0, errno == EINTR { continue }
            guard wrote > 0 else { return failed(wrote < 0 ? errno : EIO) }
            written += wrote
        }
        guard vibe_add_seals(memory, UInt32(allSeals)) == 0 else { return failed(errno) }
        guard fchmod(memory, dataMode) == 0 else { return failed(errno) }
        return .success(memory)
    }

    /// Whether `fd` is a memfd carrying every seal (`allSeals`): its bytes and size fixed for good, by anyone.
    public static func isSealed(_ fd: Int32) -> Bool {
        let seals = vibe_get_seals(fd)
        return seals >= 0 && seals & allSeals == allSeals
    }
}
#endif
