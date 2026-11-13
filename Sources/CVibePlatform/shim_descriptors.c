// CVibePlatform_descriptors.h's calls, tied to the system's own. Compiled under `_GNU_SOURCE`, as shim.c is, which
// shows struct ucred and SCM_CREDENTIALS, on glibc and on musl.
#ifdef __linux__
#define _GNU_SOURCE
#include "CVibePlatform.h"

#include <errno.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int vibe_send_descriptor(int socket, int fd) {
    union {
        char bytes[CMSG_SPACE(sizeof(int))];
        struct cmsghdr aligned;
    } control;
    memset(&control, 0, sizeof(control));
    char byte = 'd';
    struct iovec piece = { .iov_base = &byte, .iov_len = 1 };
    struct msghdr message = { .msg_iov = &piece, .msg_iovlen = 1, .msg_control = control.bytes, .msg_controllen = sizeof(control.bytes) };
    struct cmsghdr *part = CMSG_FIRSTHDR(&message);
    part->cmsg_level = SOL_SOCKET;
    part->cmsg_type = SCM_RIGHTS;
    part->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(part), &fd, sizeof(fd));
    ssize_t sent;
    do sent = sendmsg(socket, &message, MSG_NOSIGNAL); while (sent < 0 && errno == EINTR);
    return sent == 1 ? 0 : -1;
}

// Room for credentials (a socket with SO_PASSCRED gets them on every message) and four descriptors: a message carrying
// more than fits is refused all the same, and the kernel drops what it couldn't put here (MSG_CTRUNC).
#define VIBE_DESCRIPTOR_ROOM (CMSG_SPACE(sizeof(struct ucred)) + CMSG_SPACE(4 * sizeof(int)))

// Whether `socket` is shut for reading, which a Unix socket is once its peer has closed or shut its end: a poll that
// doesn't wait. A failed poll says gone, as before this check was made.
int vibe_peer_has_gone(int socket) {
    struct pollfd waiting = { .fd = socket, .events = POLLRDHUP };
    int ready;
    do ready = poll(&waiting, 1, 0); while (ready < 0 && errno == EINTR);
    return ready != 0 && (ready < 0 || (waiting.revents & (POLLRDHUP | POLLHUP | POLLERR | POLLNVAL)));
}

int vibe_receive_descriptor(int socket) {
    return vibe_receive_descriptor_in_room(socket, VIBE_DESCRIPTOR_ROOM);
}

int vibe_receive_descriptor_in_room(int socket, size_t room) {
    union {
        char bytes[VIBE_DESCRIPTOR_ROOM];
        struct cmsghdr aligned;
    } control;
    if (room > sizeof(control.bytes)) room = sizeof(control.bytes);
    char byte;
    struct iovec piece = { .iov_base = &byte, .iov_len = 1 };
    struct msghdr message = { .msg_iov = &piece, .msg_iovlen = 1, .msg_control = control.bytes, .msg_controllen = room };
    ssize_t count;
    do count = recvmsg(socket, &message, MSG_CMSG_CLOEXEC); while (count < 0 && errno == EINTR);
    if (count < 0) return -1;
    int taken = -1;
    size_t passed = 0;
    for (struct cmsghdr *part = CMSG_FIRSTHDR(&message); part != NULL; part = CMSG_NXTHDR(&message, part)) {
        if (part->cmsg_level != SOL_SOCKET || part->cmsg_type != SCM_RIGHTS || part->cmsg_len <= CMSG_LEN(0)) continue;
        size_t here = (part->cmsg_len - CMSG_LEN(0)) / sizeof(int);
        for (size_t index = 0; index < here; index++) {
            int descriptor;
            memcpy(&descriptor, CMSG_DATA(part) + index * sizeof(int), sizeof(descriptor));
            if (passed++ == 0) {
                taken = descriptor;
            } else {
                close(descriptor);
            }
        }
    }
    if (passed == 1 && !(message.msg_flags & MSG_CTRUNC)) return taken;
    if (taken >= 0) close(taken);
    // A stream's end comes with nothing: say the peer has gone, not that its message was wrong. But on a SOCK_SEQPACKET
    // socket (the connector's) a message of no bytes from a peer still there reads as 0 too, so the end is told by the
    // socket itself: shut for reading (POLLRDHUP), as it is once the peer has closed its end or shut it for writing.
    errno = count == 0 && passed == 0 && vibe_peer_has_gone(socket) ? EPIPE : EBADMSG;
    return -1;
}

ssize_t vibe_send_claiming(int fd, const void *bytes, size_t count, pid_t pid, uid_t uid, gid_t gid) {
    union {
        char bytes[CMSG_SPACE(sizeof(struct ucred))];
        struct cmsghdr aligned;
    } control;
    memset(&control, 0, sizeof(control));
    struct iovec piece = { .iov_base = (void *)bytes, .iov_len = count };
    struct msghdr message = { .msg_iov = &piece, .msg_iovlen = 1, .msg_control = control.bytes, .msg_controllen = sizeof(control.bytes) };
    struct cmsghdr *part = CMSG_FIRSTHDR(&message);
    part->cmsg_level = SOL_SOCKET;
    part->cmsg_type = SCM_CREDENTIALS;
    part->cmsg_len = CMSG_LEN(sizeof(struct ucred));
    struct ucred claimed = { .pid = pid, .uid = uid, .gid = gid };
    memcpy(CMSG_DATA(part), &claimed, sizeof(claimed));
    return sendmsg(fd, &message, MSG_NOSIGNAL);
}
#endif
