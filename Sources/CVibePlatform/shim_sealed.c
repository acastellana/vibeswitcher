// CVibePlatform_sealed.h's names, tied to the system's own: memfd_create and a memfd's seals. Compiled under
// `_GNU_SOURCE`, as shim.c is, which shows them on glibc and on musl; a number that stops matching the system's fails
// here.
#ifdef __linux__
#define _GNU_SOURCE
#include "CVibePlatform.h"

#include <fcntl.h>
#include <sys/mman.h>

_Static_assert(VIBE_MFD_CLOEXEC == MFD_CLOEXEC, "MFD_CLOEXEC");
_Static_assert(VIBE_MFD_ALLOW_SEALING == MFD_ALLOW_SEALING, "MFD_ALLOW_SEALING");
#ifdef MFD_EXEC
_Static_assert(VIBE_MFD_EXEC == MFD_EXEC, "MFD_EXEC");
#endif
_Static_assert(VIBE_F_SEAL_SEAL == F_SEAL_SEAL, "F_SEAL_SEAL");
_Static_assert(VIBE_F_SEAL_SHRINK == F_SEAL_SHRINK, "F_SEAL_SHRINK");
_Static_assert(VIBE_F_SEAL_GROW == F_SEAL_GROW, "F_SEAL_GROW");
_Static_assert(VIBE_F_SEAL_WRITE == F_SEAL_WRITE, "F_SEAL_WRITE");

int vibe_memfd_create(const char *name, unsigned int flags) {
    return memfd_create(name, flags);
}

int vibe_add_seals(int fd, unsigned int seals) {
    return fcntl(fd, F_ADD_SEALS, seals);
}

int vibe_get_seals(int fd) {
    return fcntl(fd, F_GET_SEALS);
}
#endif
