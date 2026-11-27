// K-M1's second part (pair-token.c, trials (g) to (n)): the hardened image a maker execs when the image must act, ad
// hoc signed with the Hardened Runtime under its own identifier by pair-token.sh, so its cdhash is neither the probe's
// nor facts-hardened's. It plays a genuine image that does, on descriptors it was started with, what the node's host
// does in some mode: writes a line on its descriptor 2, reads its descriptor 0, answers on a descriptor it was named,
// takes a descriptor sent to it and reads it once, or sends one Mach message. It touches nothing else, reads no file,
// and takes no other process's port.
//
//   pair-image act          steps on its descriptors 0, 2, 5 and 6, one per byte read on descriptor 3; each step's
//                           result (status 'o' or 'e', then errno) written on descriptor 4; it ends at end of file
//   pair-image mach [FD]    its own pid and pidversion written on FD (if given), then one Mach message sent to its
//                           bootstrap special port (the probe's port, which the probe gave it), then it sleeps 30 s
//   pair-image sleep        sleeps 30 s
#include <errno.h>
#include <mach/mach.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

typedef struct { pid_t pid; int version; } who_t;

static who_t own(void) {
    audit_token_t token;
    mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
    if (task_info(mach_task_self(), TASK_AUDIT_TOKEN, (task_info_t)&token, &count) != KERN_SUCCESS) exit(70);
    return (who_t){(pid_t)token.val[5], (int)token.val[7]};
}

static void result(int ok) {
    char bytes[2] = {ok ? 'o' : 'e', (char)(ok ? 0 : errno)};
    if (write(4, bytes, 2) != 2) exit(71);
}

static int read_all(int fd, char *bytes, size_t count) {
    size_t got = 0;
    while (got < count) {
        ssize_t n = read(fd, bytes + got, count - got);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return 0;
        got += (size_t)n;
    }
    return 1;
}

static void limit(int fd) {
    struct timeval two = {.tv_sec = 2};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &two, sizeof two);
}

static int act(void) {
    char op;
    while (read(3, &op, 1) == 1) {
        switch (op) {
        case 'e': {  // a line on descriptor 2, as a host writes its diagnosis
            const char line[] = "pair-image: a line on its descriptor 2\n";
            result(write(2, line, sizeof line - 1) == (ssize_t)(sizeof line - 1));
            break;
        }
        case '0': {  // one read of descriptor 0 that doesn't wait, as a parser reads its link
            char byte;
            result(recv(0, &byte, 1, MSG_DONTWAIT) >= 0);
            break;
        }
        case 'a': {  // the answer: 8 bytes read on descriptor 5, written back on it
            char nonce[8];
            limit(5);
            result(read_all(5, nonce, 8) && write(5, nonce, 8) == 8);
            break;
        }
        case 'r':  // its own request on descriptor 5
            result(write(5, "req", 3) == 3);
            break;
        case 'f': {  // a descriptor taken on descriptor 6 (as a handover's receiver takes one), then read once
            char byte;
            char control[CMSG_SPACE(sizeof(int))];
            struct iovec io = {.iov_base = &byte, .iov_len = 1};
            struct msghdr message = {.msg_iov = &io, .msg_iovlen = 1, .msg_control = control, .msg_controllen = sizeof control};
            limit(6);
            if (recvmsg(6, &message, 0) != 1) { result(0); break; }
            struct cmsghdr *header = CMSG_FIRSTHDR(&message);
            if (!header || header->cmsg_type != SCM_RIGHTS) { errno = EBADMSG; result(0); break; }
            int got;
            memcpy(&got, CMSG_DATA(header), sizeof got);
            result(recv(got, &byte, 1, MSG_DONTWAIT) >= 0 || errno == EAGAIN);
            break;
        }
        default:
            errno = EINVAL;
            result(0);
        }
    }
    return 0;
}

static int mach(int report) {
    if (report >= 0) {
        who_t me = own();
        if (write(report, &me, sizeof me) != sizeof me) return 72;
    }
    mach_port_t port = MACH_PORT_NULL;
    if (task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &port) != KERN_SUCCESS || !MACH_PORT_VALID(port)) {
        fprintf(stderr, "pair-image: no bootstrap special port\n");
        return 73;
    }
    struct { mach_msg_header_t header; char body[8]; } message;
    memset(&message, 0, sizeof message);
    message.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    message.header.msgh_size = sizeof message;
    message.header.msgh_remote_port = port;
    memcpy(message.body, "image", 6);
    kern_return_t sent = mach_msg(&message.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof message, 0, MACH_PORT_NULL, 5000, MACH_PORT_NULL);
    if (sent != KERN_SUCCESS) { fprintf(stderr, "pair-image: mach_msg send: 0x%x\n", sent); return 74; }
    sleep(30);  // ended by the probe once it has read the message
    return 0;
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "act") == 0) return act();
    if (argc >= 2 && strcmp(argv[1], "mach") == 0) return mach(argc >= 3 ? atoi(argv[2]) : -1);
    if (argc >= 2 && strcmp(argv[1], "sleep") == 0) { sleep(30); return 0; }
    fprintf(stderr, "usage: pair-image act | mach [FD] | sleep\n");
    return 64;
}
