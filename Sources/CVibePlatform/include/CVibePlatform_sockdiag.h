// The file a Unix socket is bound to, as the kernel knows it: a NETLINK_SOCK_DIAG query for the socket (unix_diag,
// CONFIG_UNIX_DIAG). Nothing goes through the path, so a file renamed over it meanwhile can't answer in the socket's
// place. Included by CVibePlatform.h; the body is shim_sockdiag.c's.
#ifndef CVIBEPLATFORM_SOCKDIAG_H
#define CVIBEPLATFORM_SOCKDIAG_H
#ifdef __linux__

#include <stdint.h>

// The device and inode of the file the Unix socket `fd` was bound to (bind(2) made it; a rename since moves it, it
// is the same file), however the path reads now. 0 and both filled; -1 and errno otherwise: what fstat, socket or
// sendmsg said, ENOTSOCK when `fd` isn't a socket, ENOENT when the kernel knows no such socket or it is bound to
// no file (not bound, or bound to an abstract name), EPROTONOSUPPORT or ENOENT when the kernel has no unix_diag,
// ESTALE when the socket the kernel found by `fd`'s inode number is another (its cookie, SO_COOKIE, differs: the 32-bit
// numbers came round), EIO when its answer can't be read.
//
// `device` is in the encoding stat(2) gives `st_dev` (the kernel's own, which unix_diag reports, converted).
// `inode` is the low 32 bits of the file's inode number: unix_diag reports no more (its `udiag_vfs_ino` is a __u32),
// so a caller compares it with the low 32 bits of a stat's `st_ino`.
int vibe_socket_bound_file(int fd, uint64_t *device, uint64_t *inode);

#endif
#endif
