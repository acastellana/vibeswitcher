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
// otherwise: recvmsg's own, EPIPE at the end of the stream (the peer has gone: the socket is shut for reading), EBADMSG
// when the message carried no descriptor or more than one (every one that came is closed, and those the room here
// couldn't take the kernel dropped itself), or came cut short (MSG_CTRUNC). A message of no bytes and no descriptor
// from a peer still there (SOCK_SEQPACKET reads it as 0, as it does the end) is EBADMSG; one whose sender closed its
// end right after it is EPIPE, as the next read would be. Credentials that came along (SO_PASSCRED) are passed over.
int vibe_receive_descriptor(int socket);

// Whether the Unix socket `socket` is shut for reading: its peer has closed its end (every process that held it) or
// shut it for writing (shutdown(2) SHUT_WR), so no message can come on it again (POLLRDHUP, or POLLHUP, POLLERR,
// POLLNVAL). A poll that doesn't wait; 1 when shut or when the poll failed, else 0. On a SOCK_SEQPACKET socket a message
// of no bytes reads as 0, as the end does: this tells them apart.
int vibe_peer_has_gone(int socket);

// Tests only. vibe_receive_descriptor with only `room` bytes for the kernel to fill with control data (at most what
// vibe_receive_descriptor gives it): room for one descriptor, against a message of two, is how a test sees a message
// the kernel cut short (MSG_CTRUNC) refused, which the full room never brings about on 64-bit Linux.
int vibe_receive_descriptor_in_room(int socket, size_t room);

// Tests only. sendmsg(2) of `count` bytes over the Unix socket `fd` with credentials the sender names itself
// (SCM_CREDENTIALS): `pid`, `uid`, `gid`. The kernel checks them: a pid other than the sender's own is refused (EPERM)
// unless the sender holds CAP_SYS_ADMIN in the user namespace that owns the pid's namespace, a uid or gid other than
// its own unless it holds CAP_SETUID or CAP_SETGID there. What sendmsg returns (-1 and errno), with no SIGPIPE.
// For the tests of who sent a message (the host's per-read check): a process in a user and pid namespace of its own
// may name its namespace's pids.
ssize_t vibe_send_claiming(int fd, const void *bytes, size_t count, pid_t pid, uid_t uid, gid_t gid);

#endif
#endif
