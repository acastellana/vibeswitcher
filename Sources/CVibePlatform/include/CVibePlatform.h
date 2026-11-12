// What Swift can't reach through Glibc's or Musl's module on Linux, because the C library shows it only under
// `_GNU_SOURCE` or has no wrapper for it: renameat2, statx, struct ucred, pidfd_open, ptsname_r, POSIX_SPAWN_SETSID.
// Imported only by VibePlatform (its Libc.swift).
//
// Each is here under a name of its own, and shim.c, compiled under `_GNU_SOURCE`, ties it to the system's. This header
// can't define `_GNU_SOURCE` itself: Swift's Glibc module is built without it, and a second module holding the same
// system headers read with it is refused ("'__fds_bits' from module 'SwiftGlibc' is not present in definition of
// 'fd_set' in module 'CVibePlatform'"). So nothing here differs with that macro.
#ifndef CVIBEPLATFORM_H
#define CVIBEPLATFORM_H
#ifdef __linux__

#include <stddef.h>
#include <sys/types.h>
#include <time.h>

// renameat2(2): glibc has it from 2.28, musl 1.2.5 (the static SDK's) doesn't. -1 and errno, as the call.
int vibe_renameat2(int oldfd, const char *oldpath, int newfd, const char *newpath, unsigned int flags);
// RENAME_NOREPLACE: fail with EEXIST when newpath is there.
#define VIBE_RENAME_NOREPLACE 1

// statx(2), for the one thing stat doesn't have: when the file was made. 0 and `birth` filled; -1 and errno, ENODATA
// when the file system keeps no birth time (tmpfs, 9p). `flags` are statx's (AT_SYMLINK_NOFOLLOW).
int vibe_birth_time(int dirfd, const char *path, int flags, struct timespec *birth);

// struct ucred, what getsockopt(SO_PEERCRED) fills.
struct vibe_ucred {
    pid_t pid;
    uid_t uid;
    gid_t gid;
};

// pidfd_open(2): glibc has it from 2.36, musl not at all. -1 and errno, as the call.
int vibe_pidfd_open(pid_t pid, unsigned int flags);

// ptsname_r(3): the error number, 0 when `buffer` holds the name.
int vibe_ptsname_r(int fd, char *buffer, size_t length);

// POSIX_SPAWN_SETSID, for posix_spawnattr_setflags.
#define VIBE_POSIX_SPAWN_SETSID 0x80

#endif
#endif
