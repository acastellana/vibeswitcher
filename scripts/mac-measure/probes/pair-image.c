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
//   pair-image limit NAME VALUE PATH [ARGS…]   a launcher, as a session's would be: sets its own RLIMIT_NAME (STACK,
//                           NOFILE, DATA, CPU) to VALUE, says so on descriptor 3, then execs PATH with ARGS
//   pair-image ports FD     K-M16's here part (assumption A, 2026-11-27): what this image finds on itself at its first
//                           statement, written as lines on FD: its task's and its main thread's exception ports for
//                           each mask group (EXC_MASK_ALL, EXC_MASK_CRASH, EXC_MASK_CORPSE_NOTIFY; a set handler, its
//                           behaviour and flavour), its rlimits, its own code-signing status word and the time of the
//                           first statement (mach_absolute_time); then the clear (every mask, task and main thread, to
//                           MACH_PORT_NULL) with each call's result, and the ports read again. It reads only itself:
//                           no other process's port, and nothing received on a handler.
//
// Every mode takes the snapshot as main's first statement (first_look), so the time and the ports are what the image
// found before it read argv; only `ports` reports it.
#include <errno.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <sys/resource.h>
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

// --- K-M16's here part: what the image finds on itself -------------------------------------------------------------
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

typedef struct { const char *name; exception_mask_t mask; } group_t;
static const group_t groups[] = {
    {"EXC_MASK_ALL", EXC_MASK_ALL},
    {"EXC_MASK_CRASH", EXC_MASK_CRASH},
    {"EXC_MASK_CORPSE_NOTIFY", EXC_MASK_CORPSE_NOTIFY},
};
#define GROUPS (sizeof groups / sizeof groups[0])

typedef struct {
    kern_return_t kr;
    mach_msg_type_number_t count;
    exception_mask_t masks[EXC_TYPES_COUNT];
    mach_port_t handlers[EXC_TYPES_COUNT];
    exception_behavior_t behaviors[EXC_TYPES_COUNT];
    thread_state_flavor_t flavors[EXC_TYPES_COUNT];
} ports_t;

typedef struct { ports_t task[GROUPS], thread[GROUPS]; } look_t;

static uint64_t first_time;
static look_t first;

static void read_ports(look_t *look) {
    mach_port_t thread = mach_thread_self();
    for (size_t g = 0; g < GROUPS; g++) {
        ports_t *t = &look->task[g], *h = &look->thread[g];
        t->count = h->count = EXC_TYPES_COUNT;
        t->kr = task_get_exception_ports(mach_task_self(), groups[g].mask, t->masks, &t->count, t->handlers, t->behaviors, t->flavors);
        h->kr = thread_get_exception_ports(thread, groups[g].mask, h->masks, &h->count, h->handlers, h->behaviors, h->flavors);
    }
    mach_port_deallocate(mach_task_self(), thread);
}

static void first_look(void) {
    first_time = mach_absolute_time();
    read_ports(&first);
}

// One line per level: each mask group, then each entry whose handler is set (mask, behaviour, flavour).
static void say_level(FILE *out, const char *level, const ports_t *p) {
    fprintf(out, "    %s:", level);
    for (size_t g = 0; g < GROUPS; g++) {
        fprintf(out, " %s", groups[g].name + 9);
        if (p[g].kr != KERN_SUCCESS) { fprintf(out, " refused 0x%x;", p[g].kr); continue; }
        int set = 0;
        for (mach_msg_type_number_t i = 0; i < p[g].count; i++) {
            if (!MACH_PORT_VALID(p[g].handlers[i])) continue;
            fprintf(out, " %smask 0x%x behaviour 0x%x flavour %d", set++ ? ", " : "[", p[g].masks[i], (unsigned)p[g].behaviors[i], p[g].flavors[i]);
        }
        fprintf(out, set ? "];" : " none;");
    }
    fprintf(out, "\n");
}

static void say_look(FILE *out, const look_t *look) {
    say_level(out, "task", look->task);
    say_level(out, "main thread", look->thread);
}

static int ports(int fd) {
    FILE *out = fdopen(fd, "w");
    if (!out) return 75;
    fprintf(out, "  first statement at %llu (mach_absolute_time)", (unsigned long long)first_time);
    uint32_t status = 0;
    if (csops(getpid(), 0 /* CS_OPS_STATUS */, &status, sizeof status) == 0) fprintf(out, "; its own status word 0x%08x", status);
    fprintf(out, "\n  rlimits (cur/max):");
    const struct { const char *name; int which; } limits[] = {
        {"STACK", RLIMIT_STACK}, {"DATA", RLIMIT_DATA}, {"NOFILE", RLIMIT_NOFILE}, {"CORE", RLIMIT_CORE},
    };
    for (size_t i = 0; i < sizeof limits / sizeof limits[0]; i++) {
        struct rlimit r;
        if (getrlimit(limits[i].which, &r) != 0) continue;
        fprintf(out, " %s ", limits[i].name);
        if (r.rlim_cur == RLIM_INFINITY) fprintf(out, "inf"); else fprintf(out, "%llu", (unsigned long long)r.rlim_cur);
        if (r.rlim_max == RLIM_INFINITY) fprintf(out, "/inf"); else fprintf(out, "/%llu", (unsigned long long)r.rlim_max);
    }
    fprintf(out, "\n");
    fprintf(out, "  at its first statement:\n");
    say_look(out, &first);
    // The clear: every mask, as one call and as each group alone, task and main thread.
    exception_mask_t every = EXC_MASK_ALL | EXC_MASK_CRASH | EXC_MASK_CORPSE_NOTIFY;
    mach_port_t thread = mach_thread_self();
    kern_return_t task_all = task_set_exception_ports(mach_task_self(), every, MACH_PORT_NULL, EXCEPTION_DEFAULT, THREAD_STATE_NONE);
    kern_return_t thread_all = thread_set_exception_ports(thread, every, MACH_PORT_NULL, EXCEPTION_DEFAULT, THREAD_STATE_NONE);
    fprintf(out, "  the clear (EXC_MASK_ALL|EXC_MASK_CRASH|EXC_MASK_CORPSE_NOTIFY to MACH_PORT_NULL, one call): task 0x%x, main thread 0x%x; each group alone:", task_all, thread_all);
    for (size_t g = 0; g < GROUPS; g++) {
        kern_return_t t = task_set_exception_ports(mach_task_self(), groups[g].mask, MACH_PORT_NULL, EXCEPTION_DEFAULT, THREAD_STATE_NONE);
        kern_return_t h = thread_set_exception_ports(thread, groups[g].mask, MACH_PORT_NULL, EXCEPTION_DEFAULT, THREAD_STATE_NONE);
        fprintf(out, " %s 0x%x/0x%x", groups[g].name + 9, t, h);
    }
    fprintf(out, "\n");
    mach_port_deallocate(mach_task_self(), thread);
    look_t after;
    read_ports(&after);
    fprintf(out, "  after the clear:\n");
    say_look(out, &after);
    fclose(out);
    return 0;
}

// A launcher that lowers one of its limits, then execs its target: limits cross an exec, so the target starts under it.
static int limit_then_exec(char **argv) {
    const struct { const char *name; int which; } names[] = {
        {"STACK", RLIMIT_STACK}, {"NOFILE", RLIMIT_NOFILE}, {"DATA", RLIMIT_DATA}, {"CPU", RLIMIT_CPU},
    };
    int which = -1;
    for (size_t i = 0; i < sizeof names / sizeof names[0]; i++)
        if (strcmp(argv[2], names[i].name) == 0) which = names[i].which;
    if (which < 0) return 64;
    struct rlimit r;
    getrlimit(which, &r);
    r.rlim_cur = strtoull(argv[3], NULL, 10);
    int rc = setrlimit(which, &r);
    dprintf(3, "  the launcher set its RLIMIT_%s to %s: %s, then execs its target\n", argv[2], argv[3], rc ? strerror(errno) : "done");
    execv(argv[4], argv + 4);
    dprintf(3, "  the launcher's exec failed: %s\n", strerror(errno));
    return 127;
}

int main(int argc, char **argv) {
    first_look();
    if (argc >= 5 && strcmp(argv[1], "limit") == 0) return limit_then_exec(argv);
    if (argc >= 3 && strcmp(argv[1], "ports") == 0) return ports(atoi(argv[2]));
    if (argc >= 2 && strcmp(argv[1], "act") == 0) return act();
    if (argc >= 2 && strcmp(argv[1], "mach") == 0) return mach(argc >= 3 ? atoi(argv[2]) : -1);
    if (argc >= 2 && strcmp(argv[1], "sleep") == 0) { sleep(30); return 0; }
    fprintf(stderr, "usage: pair-image act | mach [FD] | sleep | ports FD | limit NAME VALUE PATH [ARGS...]\n");
    return 64;
}
