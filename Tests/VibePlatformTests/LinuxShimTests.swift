#if os(Linux)
import Foundation
import Testing
import VibePlatform

/// What Sources/CVibePlatform holds reaches Swift through VibePlatform, and the system answers each call: glibc and
/// musl show Swift none of these without the shim. No file is made or renamed.
struct LinuxShimTests {
    @Test func anExclusiveRenameOfNothingSaysSo() {
        let renamed = vibe_renameat2(AT_FDCWD, "/no-such-folder-a/x", AT_FDCWD, "/no-such-folder-b/x", UInt32(VIBE_RENAME_NOREPLACE))
        let code = errno
        #expect(renamed == -1)
        #expect(code == ENOENT)
    }

    /// A birth time or "this file system keeps none" (tmpfs, 9p), never another error; and none for a missing file.
    @Test func aFilesBirthTimeIsReadOrKnownMissing() {
        var birth = timespec()
        let read = vibe_birth_time(AT_FDCWD, #filePath, 0, &birth)
        let code = errno
        if read == 0 { #expect(birth.tv_sec > 1_500_000_000) } else { #expect(code == ENODATA) }
        #expect(vibe_birth_time(AT_FDCWD, "/no-such-folder-a/x", 0, &birth) == -1)
    }

    @Test func aProcessCanBeOpenedByItsNumber() {
        let own = vibe_pidfd_open(getpid(), 0)
        #expect(own >= 0)
        if own >= 0 { close(own) }
    }

    @Test func aTerminalsNameIsAskedWithoutSharedState() {
        var name = [CChar](repeating: 0, count: 64)
        #expect(vibe_ptsname_r(-1, &name, name.count) != 0)
        let primary = open("/dev/ptmx", O_RDWR | O_NOCTTY)
        #expect(primary >= 0)
        guard primary >= 0 else { return }
        defer { close(primary) }
        #expect(vibe_ptsname_r(primary, &name, name.count) == 0)
        #expect(String(cString: name).hasPrefix("/dev/pts/"))
    }

    @Test func aSocketsPeerIsThisProcess() {
        var ends: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &ends) == 0)
        defer { ends.forEach { close($0) } }
        var peer = vibe_ucred()
        var length = socklen_t(MemoryLayout<vibe_ucred>.size)
        #expect(getsockopt(ends[0], SOL_SOCKET, SO_PEERCRED, &peer, &length) == 0)
        #expect(peer.pid == getpid())
        #expect(peer.uid == geteuid())
        #expect(peer.gid == getegid())
    }

    @Test func theSpawnFlagIsThere() {
        #expect(VIBE_POSIX_SPAWN_SETSID == 0x80)
    }
}
#endif
