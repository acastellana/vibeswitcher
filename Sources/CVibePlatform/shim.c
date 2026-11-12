// CVibePlatform.h's names, tied to the system's own. Compiled under `_GNU_SOURCE`, which shows what they wrap, on
// glibc and on musl; a name or a layout that stops matching the system's fails here.
#ifdef __linux__
#define _GNU_SOURCE
#include "CVibePlatform.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/vfs.h>
#include <unistd.h>
#if __has_include(<linux/magic.h>)
#include <linux/magic.h>
#endif

_Static_assert(VIBE_POSIX_SPAWN_SETSID == POSIX_SPAWN_SETSID, "POSIX_SPAWN_SETSID");
#ifdef RENAME_NOREPLACE
_Static_assert(VIBE_RENAME_NOREPLACE == RENAME_NOREPLACE, "RENAME_NOREPLACE");
#endif
#ifdef V9FS_MAGIC
_Static_assert(VIBE_9P_MAGIC == V9FS_MAGIC, "V9FS_MAGIC");
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

int vibe_filesystem_type(const char *path, unsigned long *type) {
    struct statfs info;
    if (statfs(path, &info) != 0) return -1;
    *type = (unsigned long)info.f_type;
    return 0;
}

int vibe_ptsname_r(int fd, char *buffer, size_t length) {
    return ptsname_r(fd, buffer, length);
}

pid_t vibe_signal_sender(const void *info) {
    return ((const siginfo_t *)info)->si_pid;
}

ssize_t vibe_receive_credentials(int fd, void *buffer, size_t length, struct vibe_ucred *sender) {
    // Room for the credentials and nothing after them. Without them (no SO_PASSCRED) the same room would take up to
    // four descriptors a peer sent along: those are closed below.
    union {
        char bytes[CMSG_SPACE(sizeof(struct ucred))];
        struct cmsghdr aligned;
    } control;
    struct iovec piece = { .iov_base = buffer, .iov_len = length };
    struct msghdr message = { .msg_iov = &piece, .msg_iovlen = 1, .msg_control = control.bytes, .msg_controllen = sizeof(control.bytes) };
    sender->pid = 0;
    sender->uid = (uid_t)-1;
    sender->gid = (gid_t)-1;
    ssize_t count = recvmsg(fd, &message, MSG_CMSG_CLOEXEC);
    if (count < 0) return count;
    for (struct cmsghdr *part = CMSG_FIRSTHDR(&message); part != NULL; part = CMSG_NXTHDR(&message, part)) {
        if (part->cmsg_level != SOL_SOCKET) continue;
        if (part->cmsg_type == SCM_CREDENTIALS && part->cmsg_len >= CMSG_LEN(sizeof(struct ucred))) {
            struct ucred from;
            memcpy(&from, CMSG_DATA(part), sizeof(from));
            sender->pid = from.pid;
            sender->uid = from.uid;
            sender->gid = from.gid;
        } else if (part->cmsg_type == SCM_RIGHTS && part->cmsg_len > CMSG_LEN(0)) {
            size_t passed = (part->cmsg_len - CMSG_LEN(0)) / sizeof(int);
            for (size_t index = 0; index < passed; index++) {
                int descriptor;
                memcpy(&descriptor, CMSG_DATA(part) + index * sizeof(int), sizeof(descriptor));
                close(descriptor);
            }
        }
    }
    return count;
}
#endif
