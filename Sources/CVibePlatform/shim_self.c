// CVibePlatform_self.h's names, tied to the system's own, as shim.c ties CVibePlatform.h's. Compiled under
// `_GNU_SOURCE`, on glibc and on musl.
#ifdef __linux__
#define _GNU_SOURCE
#include "CVibePlatform.h"

#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

// 438 on every architecture, for headers older than Linux 5.6.
#ifndef SYS_pidfd_getfd
#define SYS_pidfd_getfd 438
#endif

int vibe_set_dumpable(int dumpable) {
    return prctl(PR_SET_DUMPABLE, (unsigned long)dumpable, 0UL, 0UL, 0UL);
}

int vibe_get_dumpable(void) {
    return prctl(PR_GET_DUMPABLE, 0UL, 0UL, 0UL, 0UL);
}

int vibe_pidfd_getfd(int pidfd, int targetfd, unsigned int flags) {
    return (int)syscall(SYS_pidfd_getfd, pidfd, targetfd, flags);
}
#endif
