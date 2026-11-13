extension Sys {
    /// A pipe whose two ends are close-on-exec, in `fds` (reading end first), as `pipe` fills it: 0, or -1 and errno.
    /// Linux: `pipe2(O_CLOEXEC)`, close-on-exec from the call that makes it, so no program another thread starts in
    /// between holds an end. The Mac, which has no pipe2: `pipe`, then `FD_CLOEXEC` on each end, as its code always
    /// did. `fds` with room for fewer than two is refused (EINVAL), nothing made.
    public static func pipeClosedOnExec(_ fds: inout [Int32]) -> Int32 {
        guard fds.count >= 2 else {
            errno = EINVAL
            return -1
        }
        return fds.withUnsafeMutableBufferPointer { ends in
            #if os(Linux)
            return vibe_pipe_cloexec(ends.baseAddress!)
            #else
            guard pipe(ends.baseAddress!) == 0 else { return -1 }
            _ = fcntl(ends[0], F_SETFD, FD_CLOEXEC)
            _ = fcntl(ends[1], F_SETFD, FD_CLOEXEC)
            return 0
            #endif
        }
    }
}
