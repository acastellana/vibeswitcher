// Sealed in-memory copies of an image (Platform.ProcessSelf.sealedCopy): memfd_create(2) and a memfd's seals, which
// glibc and musl show only under `_GNU_SOURCE` (<sys/mman.h>'s memfd_create, <fcntl.h>'s F_ADD_SEALS and F_SEAL_*),
// and fcntl's seal commands, which Swift reaches only by those names. Included by CVibePlatform.h; tied to the
// system's own names in shim_sealed.c. As there, nothing here differs with `_GNU_SOURCE`.
#ifndef CVIBEPLATFORM_SEALED_H
#define CVIBEPLATFORM_SEALED_H
#ifdef __linux__

// memfd_create(2): a file in memory, named `name` in /proc/<pid>/fd's links (`/memfd:<name>`). -1 and errno, as the
// call: EINVAL for a flag this kernel doesn't know (VIBE_MFD_EXEC before Linux 6.3).
int vibe_memfd_create(const char *name, unsigned int flags);
// Closed on exec from its making.
#define VIBE_MFD_CLOEXEC 0x0001U
// Takes seals (without it the file is born with F_SEAL_SEAL and takes no other).
#define VIBE_MFD_ALLOW_SEALING 0x0002U
// May be executed, where the kernel has `vm.memfd_noexec` (6.3 and up) and would otherwise refuse or warn.
#define VIBE_MFD_EXEC 0x0010U

// fcntl(F_ADD_SEALS): adds `seals` to the file's, for good. 0, or -1 and errno (EPERM once F_SEAL_SEAL is on it, or
// for F_SEAL_WRITE while a shared writable mapping of it exists; EINVAL for a file that isn't a memfd).
int vibe_add_seals(int fd, unsigned int seals);
// fcntl(F_GET_SEALS): the file's seals, or -1 and errno (EINVAL for a file that isn't a memfd).
int vibe_get_seals(int fd);
// No seal can be added after it.
#define VIBE_F_SEAL_SEAL 0x0001
// The file can't get smaller.
#define VIBE_F_SEAL_SHRINK 0x0002
// The file can't get larger.
#define VIBE_F_SEAL_GROW 0x0004
// The file's bytes can't be written, by write(2) or by a shared mapping.
#define VIBE_F_SEAL_WRITE 0x0008

#endif
#endif
