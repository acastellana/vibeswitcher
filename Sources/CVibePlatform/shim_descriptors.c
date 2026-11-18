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

// One message's descriptor, taken as vibe_receive_descriptor says, in `room` bytes of control data; `sender`, when
// given, is the pid the kernel put on the message (SCM_CREDENTIALS), 0 when it came with none.
static int receive_descriptor(int socket, size_t room, pid_t *sender) {
    union {
        char bytes[VIBE_DESCRIPTOR_ROOM];
        struct cmsghdr aligned;
    } control;
    if (room > sizeof(control.bytes)) room = sizeof(control.bytes);
    if (sender != NULL) *sender = 0;
    char byte;
    struct iovec piece = { .iov_base = &byte, .iov_len = 1 };
    struct msghdr message = { .msg_iov = &piece, .msg_iovlen = 1, .msg_control = control.bytes, .msg_controllen = room };
    ssize_t count;
    do count = recvmsg(socket, &message, MSG_CMSG_CLOEXEC); while (count < 0 && errno == EINTR);
    if (count < 0) return -1;
    int taken = -1;
    size_t passed = 0;
    for (struct cmsghdr *part = CMSG_FIRSTHDR(&message); part != NULL; part = CMSG_NXTHDR(&message, part)) {
        if (part->cmsg_level != SOL_SOCKET) continue;
        if (part->cmsg_type == SCM_CREDENTIALS && part->cmsg_len >= CMSG_LEN(sizeof(struct ucred))) {
            struct ucred from;
            memcpy(&from, CMSG_DATA(part), sizeof(from));
            if (sender != NULL) *sender = from.pid;
            continue;
        }
        if (part->cmsg_type != SCM_RIGHTS || part->cmsg_len <= CMSG_LEN(0)) continue;
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

int vibe_receive_descriptor(int socket) {
    return receive_descriptor(socket, VIBE_DESCRIPTOR_ROOM, NULL);
}

int vibe_receive_descriptor_in_room(int socket, size_t room) {
    return receive_descriptor(socket, room, NULL);
}

int vibe_receive_descriptor_from(int socket, pid_t *sender) {
    return receive_descriptor(socket, VIBE_DESCRIPTOR_ROOM, sender);
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

#define VIBE_DOOR_MOST 8

ssize_t vibe_send_with_descriptors(int socket, const void *bytes, size_t count, const int *fds, size_t fdCount) {
    if (fdCount > VIBE_DOOR_MOST || count == 0) { errno = EINVAL; return -1; }
    union {
        char bytes[CMSG_SPACE(VIBE_DOOR_MOST * sizeof(int))];
        struct cmsghdr aligned;
    } control;
    memset(&control, 0, sizeof(control));
    struct iovec piece = { .iov_base = (void *)bytes, .iov_len = count };
    struct msghdr message = { .msg_iov = &piece, .msg_iovlen = 1 };
    if (fdCount > 0) {
        message.msg_control = control.bytes;
        message.msg_controllen = CMSG_SPACE(fdCount * sizeof(int));
        struct cmsghdr *part = CMSG_FIRSTHDR(&message);
        part->cmsg_level = SOL_SOCKET;
        part->cmsg_type = SCM_RIGHTS;
        part->cmsg_len = CMSG_LEN(fdCount * sizeof(int));
        memcpy(CMSG_DATA(part), fds, fdCount * sizeof(int));
    }
    ssize_t sent;
    do sent = sendmsg(socket, &message, MSG_NOSIGNAL); while (sent < 0 && errno == EINTR);
    return sent;
}

ssize_t vibe_receive_with_descriptors(int socket, void *bytes, size_t count, int *fds, size_t room, size_t *fdCount, int *cut) {
    *fdCount = 0;
    *cut = 0;
    if (room > VIBE_DOOR_MOST) room = VIBE_DOOR_MOST;
    union {
        char bytes[CMSG_SPACE(sizeof(struct ucred)) + CMSG_SPACE(VIBE_DOOR_MOST * sizeof(int))];
        struct cmsghdr aligned;
    } control;
    struct iovec piece = { .iov_base = bytes, .iov_len = count };
    struct msghdr message = { .msg_iov = &piece, .msg_iovlen = 1, .msg_control = control.bytes,
                              .msg_controllen = CMSG_SPACE(sizeof(struct ucred)) + CMSG_SPACE(room * sizeof(int)) };
    ssize_t got;
    do got = recvmsg(socket, &message, MSG_CMSG_CLOEXEC); while (got < 0 && errno == EINTR);
    if (got < 0) return -1;
    for (struct cmsghdr *part = CMSG_FIRSTHDR(&message); part != NULL; part = CMSG_NXTHDR(&message, part)) {
        if (part->cmsg_level != SOL_SOCKET || part->cmsg_type != SCM_RIGHTS || part->cmsg_len <= CMSG_LEN(0)) continue;
        size_t here = (part->cmsg_len - CMSG_LEN(0)) / sizeof(int);
        for (size_t index = 0; index < here; index++) {
            int descriptor;
            memcpy(&descriptor, CMSG_DATA(part) + index * sizeof(int), sizeof(descriptor));
            if (*fdCount < room) {
                fds[(*fdCount)++] = descriptor;
            } else {
                close(descriptor);
                *cut = 1;
            }
        }
    }
    if (message.msg_flags & MSG_CTRUNC) *cut = 1;
    return got;
}
#endif
