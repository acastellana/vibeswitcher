// What a process does to itself, and takes from another, that Swift can't call through Glibc's or Musl's module:
// prctl(2) is variadic, and pidfd_getfd(2) has no wrapper in glibc 2.39 (Ubuntu 24.04's) nor in musl. Included by
// CVibePlatform.h, under its `__linux__`; shim_self.c ties each name to the system's.
#ifndef CVIBEPLATFORM_SELF_H
#define CVIBEPLATFORM_SELF_H
#ifdef __linux__

// prctl(PR_SET_DUMPABLE, dumpable): 0 makes this process non-dumpable (no ptrace, no /proc/<pid>/mem, fd/, environ
// to another process of the same user, and no core), 1 dumpable again. An exec of a file this process can read
// makes it dumpable again. 0, or -1 and errno.
int vibe_set_dumpable(int dumpable);

// prctl(PR_GET_DUMPABLE): 1 dumpable, 0 not, 2 dumpable by root alone (after a set-user-id program, with
// fs.suid_dumpable 2); -1 and errno.
int vibe_get_dumpable(void);

// pidfd_getfd(2), Linux 5.6: a copy, close-on-exec, of the descriptor `targetfd` of the process `pidfd` names,
// allowed as ptrace(PTRACE_MODE_ATTACH_REALCREDS) is. `flags` must be 0. The new descriptor, or -1 and errno.
int vibe_pidfd_getfd(int pidfd, int targetfd, unsigned int flags);

#endif
#endif
