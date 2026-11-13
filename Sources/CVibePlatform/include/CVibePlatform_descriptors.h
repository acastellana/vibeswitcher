// Descriptors passed over a Unix socket (SCM_RIGHTS), and, for tests only, a send that names its own sender
// (SCM_CREDENTIALS): a message's control data is built and walked with macros (CMSG_FIRSTHDR, CMSG_NXTHDR, CMSG_DATA,
// CMSG_SPACE), which Swift doesn't see. Included by CVibePlatform.h; the bodies are shim_descriptors.c's.
#ifndef CVIBEPLATFORM_DESCRIPTORS_H
#define CVIBEPLATFORM_DESCRIPTORS_H
#ifdef __linux__

#include <stddef.h>
#include <sys/types.h>

// sendmsg(2) of one byte carrying `fd` (SCM_RIGHTS) over the Unix socket `socket`, with no SIGPIPE when the peer has
// gone (MSG_NOSIGNAL): EPIPE. 0 when the byte went; -1 and errno. `fd` stays open here: the peer gets a copy.
int vibe_send_descriptor(int socket, int fd);

// recvmsg(2) of one message from the Unix socket `socket`, taking the one descriptor it carries, close-on-exec from
// its arrival (MSG_CMSG_CLOEXEC): no program this process starts meanwhile inherits it. The descriptor; -1 and errno
// otherwise: recvmsg's own, EPIPE at the end of the stream (the peer has gone), EBADMSG when the message carried no
// descriptor or more than one (every one that came is closed, and those the room here couldn't take the kernel
// dropped itself). Credentials that came along (SO_PASSCRED) are passed over.
int vibe_receive_descriptor(int socket);

// Tests only. sendmsg(2) of `count` bytes over the Unix socket `fd` with credentials the sender names itself
// (SCM_CREDENTIALS): `pid`, `uid`, `gid`. The kernel checks them: a pid other than the sender's own is refused (EPERM)
// unless the sender holds CAP_SYS_ADMIN in the user namespace that owns the pid's namespace, a uid or gid other than
// its own unless it holds CAP_SETUID or CAP_SETGID there. What sendmsg returns (-1 and errno), with no SIGPIPE.
// For the tests of who sent a message (the host's per-read check): a process in a user and pid namespace of its own
// may name its namespace's pids.
ssize_t vibe_send_claiming(int fd, const void *bytes, size_t count, pid_t pid, uid_t uid, gid_t gid);

#endif
#endif
