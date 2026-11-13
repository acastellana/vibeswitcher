// What Swift can't reach through Glibc's or Musl's module on Linux, because the C library shows it only under
// `_GNU_SOURCE` or has no wrapper for it: renameat2, statx, struct ucred, pidfd_open, ptsname_r, POSIX_SPAWN_SETSID;
// and what C reaches only through macros: siginfo_t's fields, a message's control data.
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

// recvmsg(2) on a Unix socket, with who sent what it read: the credentials the kernel put on those bytes as they were
// sent (SCM_CREDENTIALS), which it does while the receiving socket has SO_PASSCRED. What recvmsg returns (-1 and
// errno); `sender->pid` is 0 when the bytes came with none. Here because a message's control data is walked with
// macros (CMSG_FIRSTHDR, CMSG_NXTHDR, CMSG_DATA), which Swift doesn't see. Descriptors a peer sends along (SCM_RIGHTS)
// are closed, never kept.
ssize_t vibe_receive_credentials(int fd, void *buffer, size_t length, struct vibe_ucred *sender);

// pidfd_open(2): glibc has it from 2.36, musl not at all. -1 and errno, as the call.
int vibe_pidfd_open(pid_t pid, unsigned int flags);

// ptsname_r(3): the error number, 0 when `buffer` holds the name.
int vibe_ptsname_r(int fd, char *buffer, size_t length);

// POSIX_SPAWN_SETSID, for posix_spawnattr_setflags.
#define VIBE_POSIX_SPAWN_SETSID 0x80

// statfs(2)'s f_type: the kind of file system that holds `path`, one of <linux/magic.h>'s numbers. Swift's Glibc module
// has no statfs. 0 and `type` filled; -1 and errno, as the call.
int vibe_filesystem_type(const char *path, unsigned long *type);
// V9FS_MAGIC: 9p, as a Windows drive under WSL is mounted.
#define VIBE_9P_MAGIC 0x01021997

// siginfo_t's si_pid, the process that sent a signal: `info` is the siginfo_t a handler installed with SA_SIGINFO is
// given. In glibc and in musl `si_pid` is a macro over unions each names its own way, and Swift imports no such
// macro. The pointer is untyped so that this header needs no <signal.h>.
pid_t vibe_signal_sender(const void *info);

#endif
// Outside the __linux__ block, as every header of this umbrella must be: on the Mac it comes out empty (its own
// __linux__ guard), and the module's umbrella has no header it leaves out (-Wincomplete-umbrella).
#include "CVibePlatform_descriptors.h"
#endif
