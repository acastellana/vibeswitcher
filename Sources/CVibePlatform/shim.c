// CVibePlatform.h's names, tied to the system's own. Compiled under `_GNU_SOURCE`, which shows what they wrap, on
// glibc and on musl; a name or a layout that stops matching the system's fails here.
#ifdef __linux__
#define _GNU_SOURCE
#include "CVibePlatform.h"

#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

_Static_assert(VIBE_POSIX_SPAWN_SETSID == POSIX_SPAWN_SETSID, "POSIX_SPAWN_SETSID");
#ifdef RENAME_NOREPLACE
_Static_assert(VIBE_RENAME_NOREPLACE == RENAME_NOREPLACE, "RENAME_NOREPLACE");
#endif
_Static_assert(sizeof(struct vibe_ucred) == sizeof(struct ucred)
               && offsetof(struct vibe_ucred, pid) == offsetof(struct ucred, pid)
               && offsetof(struct vibe_ucred, uid) == offsetof(struct ucred, uid)
               && offsetof(struct vibe_ucred, gid) == offsetof(struct ucred, gid), "struct ucred");

// The kernel's calls, where a C library has no wrapper. 434 on every architecture, for headers older than Linux 5.3.
#ifndef SYS_pidfd_open
#define SYS_pidfd_open 434
#endif

int vibe_renameat2(int oldfd, const char *oldpath, int newfd, const char *newpath, unsigned int flags) {
    return (int)syscall(SYS_renameat2, oldfd, oldpath, newfd, newpath, flags);
}

int vibe_pidfd_open(pid_t pid, unsigned int flags) {
    return (int)syscall(SYS_pidfd_open, pid, flags);
}

int vibe_birth_time(int dirfd, const char *path, int flags, struct timespec *birth) {
    struct statx info;
    if (statx(dirfd, path, flags, STATX_BTIME, &info) != 0) return -1;
    if (!(info.stx_mask & STATX_BTIME)) {
        errno = ENODATA;
        return -1;
    }
    birth->tv_sec = info.stx_btime.tv_sec;
    birth->tv_nsec = info.stx_btime.tv_nsec;
    return 0;
}

int vibe_ptsname_r(int fd, char *buffer, size_t length) {
    return ptsname_r(fd, buffer, length);
}
#endif
