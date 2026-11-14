// CVibePlatform_sockdiag.h's call: one NETLINK_SOCK_DIAG request for one Unix socket, by its inode, asking for the
// file it is bound to (UDIAG_SHOW_VFS). The kernel's structures are spelled here, as its uapi headers spell them
// (linux/netlink.h, linux/sock_diag.h, linux/unix_diag.h), because the static SDK's musl has no linux/ headers; where
// the headers are there, the layouts are checked against them.
#ifdef __linux__
#define _GNU_SOURCE
#include "CVibePlatform.h"

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

// linux/netlink.h
struct vibe_nlmsghdr {
    uint32_t nlmsg_len;
    uint16_t nlmsg_type;
    uint16_t nlmsg_flags;
    uint32_t nlmsg_seq;
    uint32_t nlmsg_pid;
};
struct vibe_sockaddr_nl {
    sa_family_t nl_family;
    unsigned short nl_pad;
    uint32_t nl_pid;
    uint32_t nl_groups;
};
#define VIBE_NETLINK_SOCK_DIAG 4
#define VIBE_NLM_F_REQUEST 1
#define VIBE_NLMSG_ERROR 2
#define VIBE_NLMSG_DONE 3
#define VIBE_NLMSG_ALIGN(length) (((length) + 3u) & ~3u)
#define VIBE_NLA_TYPE_MASK 0x3fff
// asm-generic/socket.h: a socket's cookie, 64 bits the kernel never gives two sockets (Linux 4.12's getsockopt).
#define VIBE_SO_COOKIE 57

// linux/sock_diag.h
#define VIBE_SOCK_DIAG_BY_FAMILY 20

// linux/unix_diag.h
struct vibe_unix_diag_req {
    uint8_t sdiag_family;
    uint8_t sdiag_protocol;
    uint16_t pad;
    uint32_t udiag_states;
    uint32_t udiag_ino;
    uint32_t udiag_show;
    uint32_t udiag_cookie[2];
};
struct vibe_unix_diag_msg {
    uint8_t udiag_family;
    uint8_t udiag_type;
    uint8_t udiag_state;
    uint8_t pad;
    uint32_t udiag_ino;
    uint32_t udiag_cookie[2];
};
struct vibe_unix_diag_vfs {
    uint32_t udiag_vfs_ino;
    uint32_t udiag_vfs_dev;
};
#define VIBE_UDIAG_SHOW_VFS 0x2
#define VIBE_UNIX_DIAG_VFS 1
// linux/rtnetlink.h's struct rtattr: an attribute's length (with its header) and type, each attribute 4-byte aligned.
struct vibe_rtattr {
    uint16_t rta_len;
    uint16_t rta_type;
};

#if __has_include(<linux/unix_diag.h>) && __has_include(<linux/sock_diag.h>) && __has_include(<linux/netlink.h>)
#include <linux/netlink.h>
#include <linux/sock_diag.h>
#include <linux/unix_diag.h>
_Static_assert(sizeof(struct vibe_nlmsghdr) == sizeof(struct nlmsghdr), "struct nlmsghdr");
_Static_assert(sizeof(struct vibe_sockaddr_nl) == sizeof(struct sockaddr_nl)
               && offsetof(struct vibe_sockaddr_nl, nl_pid) == offsetof(struct sockaddr_nl, nl_pid), "struct sockaddr_nl");
_Static_assert(sizeof(struct vibe_unix_diag_req) == sizeof(struct unix_diag_req)
               && offsetof(struct vibe_unix_diag_req, udiag_ino) == offsetof(struct unix_diag_req, udiag_ino)
               && offsetof(struct vibe_unix_diag_req, udiag_show) == offsetof(struct unix_diag_req, udiag_show)
               && offsetof(struct vibe_unix_diag_req, udiag_cookie) == offsetof(struct unix_diag_req, udiag_cookie),
               "struct unix_diag_req");
_Static_assert(sizeof(struct vibe_unix_diag_msg) == sizeof(struct unix_diag_msg)
               && offsetof(struct vibe_unix_diag_msg, udiag_ino) == offsetof(struct unix_diag_msg, udiag_ino), "struct unix_diag_msg");
_Static_assert(sizeof(struct vibe_unix_diag_vfs) == sizeof(struct unix_diag_vfs)
               && offsetof(struct vibe_unix_diag_vfs, udiag_vfs_dev) == offsetof(struct unix_diag_vfs, udiag_vfs_dev),
               "struct unix_diag_vfs");
_Static_assert(VIBE_NETLINK_SOCK_DIAG == NETLINK_SOCK_DIAG && VIBE_SOCK_DIAG_BY_FAMILY == SOCK_DIAG_BY_FAMILY
               && VIBE_NLM_F_REQUEST == NLM_F_REQUEST && VIBE_NLMSG_ERROR == NLMSG_ERROR && VIBE_NLMSG_DONE == NLMSG_DONE
               && VIBE_UDIAG_SHOW_VFS == UDIAG_SHOW_VFS && VIBE_UNIX_DIAG_VFS == UNIX_DIAG_VFS, "netlink numbers");
#endif
#ifdef SO_COOKIE
_Static_assert(VIBE_SO_COOKIE == SO_COOKIE, "SO_COOKIE");
#endif

// The kernel's dev_t (MAJOR in the bits from 20 up, MINOR below: include/linux/kdev_t.h), which unix_diag reports from
// the file system's s_dev, in the encoding stat(2) gives st_dev (the C library's makedev, as the kernel's
// new_encode_dev puts it in a stat).
static uint64_t vibe_user_device(uint32_t kernel) {
    return (uint64_t)makedev(kernel >> 20, kernel & ((1u << 20) - 1));
}

int vibe_socket_bound_file(int fd, uint64_t *device, uint64_t *inode) {
    struct stat info;
    if (fstat(fd, &info) != 0) return -1;
    if (!S_ISSOCK(info.st_mode)) { errno = ENOTSOCK; return -1; }
    // The socket's own inode (sockfs's) names it to unix_diag, which takes 32 bits.
    if ((uint64_t)info.st_ino > UINT32_MAX) { errno = EOVERFLOW; return -1; }
    uint32_t socketInode = (uint32_t)info.st_ino;
    // sockfs's inode numbers are 32 bits and come round again after 2^32 inodes made, and unix_diag answers for the
    // first socket it finds with the number: the socket's cookie, which no other socket has, makes the kernel refuse
    // (ESTALE) when that is another socket. A kernel without SO_COOKIE (before 4.12) is asked by the number alone.
    uint64_t cookie = 0;
    socklen_t cookieLength = sizeof(cookie);
    int hasCookie = getsockopt(fd, SOL_SOCKET, VIBE_SO_COOKIE, &cookie, &cookieLength) == 0 && cookieLength == sizeof(cookie);

    int query = socket(AF_NETLINK, SOCK_DGRAM | SOCK_CLOEXEC, VIBE_NETLINK_SOCK_DIAG);
    if (query < 0) return -1;
    struct {
        struct vibe_nlmsghdr header;
        struct vibe_unix_diag_req request;
    } message;
    memset(&message, 0, sizeof(message));
    message.header.nlmsg_len = sizeof(message);
    message.header.nlmsg_type = VIBE_SOCK_DIAG_BY_FAMILY;
    message.header.nlmsg_flags = VIBE_NLM_F_REQUEST;
    message.header.nlmsg_seq = socketInode;
    message.request.sdiag_family = AF_UNIX;
    message.request.udiag_states = ~0u;
    message.request.udiag_ino = socketInode;
    message.request.udiag_show = VIBE_UDIAG_SHOW_VFS;
    // The cookie as sock_diag_save_cookie splits it; without one, INET_DIAG_NOCOOKIE: any socket of that number.
    message.request.udiag_cookie[0] = hasCookie ? (uint32_t)cookie : ~0u;
    message.request.udiag_cookie[1] = hasCookie ? (uint32_t)(cookie >> 32) : ~0u;
    struct vibe_sockaddr_nl kernel = { .nl_family = AF_NETLINK };
    ssize_t sent;
    do sent = sendto(query, &message, sizeof(message), 0, (struct sockaddr *)&kernel, sizeof(kernel)); while (sent < 0 && errno == EINTR);
    if (sent != (ssize_t)sizeof(message)) {
        int code = sent < 0 ? errno : EIO;
        close(query);
        errno = code;
        return -1;
    }
    // The kernel answers within the send (sock_diag's handler runs in it), so the answer is there already: a read that
    // doesn't wait, so that a kernel that never answers can't hold the caller.
    union {
        char bytes[8192];
        struct vibe_nlmsghdr aligned;
    } answer;
    struct vibe_sockaddr_nl from;
    socklen_t fromLength = sizeof(from);
    ssize_t count;
    do count = recvfrom(query, answer.bytes, sizeof(answer.bytes), MSG_DONTWAIT | MSG_TRUNC, (struct sockaddr *)&from, &fromLength);
    while (count < 0 && errno == EINTR);
    int code = count < 0 ? errno : 0;
    close(query);
    if (count < 0) { errno = code; return -1; }
    // From the kernel alone (port 0), whole.
    if (from.nl_family != AF_NETLINK || from.nl_pid != 0 || (size_t)count > sizeof(answer.bytes)) { errno = EIO; return -1; }

    size_t offset = 0;
    while (offset + sizeof(struct vibe_nlmsghdr) <= (size_t)count) {
        struct vibe_nlmsghdr *header = (struct vibe_nlmsghdr *)(answer.bytes + offset);
        if (header->nlmsg_len < sizeof(*header) || offset + header->nlmsg_len > (size_t)count) break;
        char *body = (char *)header + sizeof(*header);
        size_t bodyLength = header->nlmsg_len - sizeof(*header);
        if (header->nlmsg_seq != socketInode) {
            // Not this request's: passed over.
        } else if (header->nlmsg_type == VIBE_NLMSG_ERROR) {
            int error = 0;
            if (bodyLength >= sizeof(error)) memcpy(&error, body, sizeof(error));
            errno = error < 0 ? -error : EIO;
            return -1;
        } else if (header->nlmsg_type == VIBE_NLMSG_DONE) {
            break;
        } else if (header->nlmsg_type == VIBE_SOCK_DIAG_BY_FAMILY && bodyLength >= sizeof(struct vibe_unix_diag_msg)) {
            struct vibe_unix_diag_msg found;
            memcpy(&found, body, sizeof(found));
            if (found.udiag_family != AF_UNIX || found.udiag_ino != socketInode
                || (hasCookie && (found.udiag_cookie[0] != (uint32_t)cookie || found.udiag_cookie[1] != (uint32_t)(cookie >> 32)))) {
                errno = EIO;
                return -1;
            }
            size_t at = VIBE_NLMSG_ALIGN(sizeof(found));
            while (at + sizeof(struct vibe_rtattr) <= bodyLength) {
                struct vibe_rtattr attribute;
                memcpy(&attribute, body + at, sizeof(attribute));
                if (attribute.rta_len < sizeof(attribute) || at + attribute.rta_len > bodyLength) break;
                if ((attribute.rta_type & VIBE_NLA_TYPE_MASK) == VIBE_UNIX_DIAG_VFS
                    && attribute.rta_len >= sizeof(attribute) + sizeof(struct vibe_unix_diag_vfs)) {
                    struct vibe_unix_diag_vfs file;
                    memcpy(&file, body + at + sizeof(attribute), sizeof(file));
                    *device = vibe_user_device(file.udiag_vfs_dev);
                    *inode = file.udiag_vfs_ino;
                    return 0;
                }
                at += VIBE_NLMSG_ALIGN(attribute.rta_len);
            }
            // The socket, bound to no file.
            errno = ENOENT;
            return -1;
        }
        offset += VIBE_NLMSG_ALIGN(header->nlmsg_len);
    }
    errno = EIO;
    return -1;
}
#endif
