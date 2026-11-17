// The session sandbox's seccomp filter (CVibePlatform_sandbox.h's vibe_sandbox_load_filter), as classic BPF: allow by
// default, EPERM for what no session needs, and death for a call of another architecture. The list is the session
// sandbox plan's (SB1):
// - socket and socketpair of any family but AF_UNIX, AF_INET, AF_INET6, and AF_NETLINK with NETLINK_ROUTE: so no
//   AF_VSOCK (a network namespace doesn't cover Hyper-V sockets: measured), AF_PACKET, AF_ALG, netfilter netlink;
// - bpf, perf_event_open, userfaultfd, the keyring (add_key, request_key, keyctl), kexec_load, kexec_file_load, the
//   modules (init_module, finit_module, delete_module), swapon, swapoff, open_by_handle_at;
// - ioctl's TIOCSTI (typing into a terminal) and TIOCLINUX (a virtual console's selection, which pastes);
// - without nesting: unshare and clone with CLONE_NEWUSER, mount, umount2, pivot_root, the new mount calls (fsopen,
//   fsconfig, fsmount, move_mount, open_tree, mount_setattr) and setns; and clone3 answers ENOSYS, so the C library
//   falls back to clone, whose flags the filter can read (clone3's are behind a pointer).
// On x86_64 an x32 call (the number's bit 30) is killed too: it shares x86_64's architecture value.
#ifdef __linux__
#define _GNU_SOURCE
#include "CVibePlatform.h"

#include <errno.h>
#include <sched.h>
#include <stddef.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/netlink.h>
#include <linux/seccomp.h>
#include <termios.h>
#include <sys/ioctl.h>

#if defined(__x86_64__)
#define VIBE_AUDIT_ARCH AUDIT_ARCH_X86_64
#elif defined(__aarch64__)
#define VIBE_AUDIT_ARCH AUDIT_ARCH_AARCH64
#endif

#ifndef SYS_clone3
#define SYS_clone3 435
#endif
#ifndef SYS_open_tree
#define SYS_open_tree 428
#endif
#ifndef SYS_move_mount
#define SYS_move_mount 429
#endif
#ifndef SYS_fsopen
#define SYS_fsopen 430
#endif
#ifndef SYS_fsconfig
#define SYS_fsconfig 431
#endif
#ifndef SYS_fsmount
#define SYS_fsmount 432
#endif
#ifndef SYS_mount_setattr
#define SYS_mount_setattr 442
#endif
#ifndef TIOCLINUX
#define TIOCLINUX 0x541C
#endif
#define VIBE_X32_SYSCALL_BIT 0x40000000u

// The low 32 bits of a call's argument `index` (an int or unsigned int argument is in them).
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
#define VIBE_ARGUMENT_LOW(index) (offsetof(struct seccomp_data, args) + 8 * (index))
#else
#define VIBE_ARGUMENT_LOW(index) (offsetof(struct seccomp_data, args) + 8 * (index) + 4)
#endif

#define VIBE_ALLOW SECCOMP_RET_ALLOW
#define VIBE_REFUSE (SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA))
#define VIBE_NOT_THERE (SECCOMP_RET_ERRNO | (ENOSYS & SECCOMP_RET_DATA))
#define VIBE_KILL SECCOMP_RET_KILL_PROCESS

// The calls refused outright, wherever this architecture has them.
static const long refused[] = {
#ifdef SYS_bpf
    SYS_bpf,
#endif
#ifdef SYS_perf_event_open
    SYS_perf_event_open,
#endif
#ifdef SYS_userfaultfd
    SYS_userfaultfd,
#endif
#ifdef SYS_add_key
    SYS_add_key,
#endif
#ifdef SYS_request_key
    SYS_request_key,
#endif
#ifdef SYS_keyctl
    SYS_keyctl,
#endif
#ifdef SYS_kexec_load
    SYS_kexec_load,
#endif
#ifdef SYS_kexec_file_load
    SYS_kexec_file_load,
#endif
#ifdef SYS_init_module
    SYS_init_module,
#endif
#ifdef SYS_finit_module
    SYS_finit_module,
#endif
#ifdef SYS_delete_module
    SYS_delete_module,
#endif
#ifdef SYS_swapon
    SYS_swapon,
#endif
#ifdef SYS_swapoff
    SYS_swapoff,
#endif
#ifdef SYS_open_by_handle_at
    SYS_open_by_handle_at,
#endif
};

// Refused unless the plan allows nesting.
static const long refused_without_nesting[] = {
#ifdef SYS_mount
    SYS_mount,
#endif
#ifdef SYS_umount2
    SYS_umount2,
#endif
#ifdef SYS_pivot_root
    SYS_pivot_root,
#endif
    SYS_fsopen, SYS_fsconfig, SYS_fsmount, SYS_move_mount, SYS_open_tree, SYS_mount_setattr,
#ifdef SYS_setns
    SYS_setns,
#endif
};

#define VIBE_FILTER_ROOM 160

struct program {
    struct sock_filter code[VIBE_FILTER_ROOM];
    unsigned short length;
    int overflow;
};

static void add(struct program *program, unsigned short code, unsigned char jt, unsigned char jf, unsigned int k) {
    if (program->length >= VIBE_FILTER_ROOM) {
        program->overflow = 1;
        return;
    }
    program->code[program->length++] = (struct sock_filter){ code, jt, jf, k };
}

#define LOAD(offset) add(p, BPF_LD | BPF_W | BPF_ABS, 0, 0, (unsigned int)(offset))
#define RETURN(value) add(p, BPF_RET | BPF_K, 0, 0, (value))
// If the accumulator equals `value`, the next instruction; else the one after.
#define IF_EQUAL(value) add(p, BPF_JMP | BPF_JEQ | BPF_K, 0, 1, (unsigned int)(value))
#define LOAD_NUMBER() LOAD(offsetof(struct seccomp_data, nr))

// The call `number` with its arguments judged by the block that follows: `length` instructions, each path of which
// returns. The jump over it is taken for any other call, with the number still in the accumulator.
#define JUDGE(number, length) add(p, BPF_JMP | BPF_JEQ | BPF_K, 0, (unsigned char)(length), (unsigned int)(number))

// socket(family, type, protocol) and socketpair(family, type, protocol, sv): the families a session needs. 11
// instructions.
static void judge_family(struct program *p, long number) {
    JUDGE(number, 10);
    LOAD(VIBE_ARGUMENT_LOW(0));
    add(p, BPF_JMP | BPF_JEQ | BPF_K, 7, 0, AF_UNIX);
    add(p, BPF_JMP | BPF_JEQ | BPF_K, 6, 0, AF_INET);
    add(p, BPF_JMP | BPF_JEQ | BPF_K, 5, 0, AF_INET6);
    add(p, BPF_JMP | BPF_JEQ | BPF_K, 1, 0, AF_NETLINK);
    RETURN(VIBE_REFUSE);
    LOAD(VIBE_ARGUMENT_LOW(2));
    add(p, BPF_JMP | BPF_JEQ | BPF_K, 1, 0, NETLINK_ROUTE);
    RETURN(VIBE_REFUSE);
    RETURN(VIBE_ALLOW);
}

// ioctl(fd, request, …): not TIOCSTI, not TIOCLINUX. 7 instructions.
static void judge_ioctl(struct program *p) {
    JUDGE(SYS_ioctl, 6);
    LOAD(VIBE_ARGUMENT_LOW(1));
    IF_EQUAL(TIOCSTI);
    RETURN(VIBE_REFUSE);
    IF_EQUAL(TIOCLINUX);
    RETURN(VIBE_REFUSE);
    RETURN(VIBE_ALLOW);
}

// A call whose argument `index` holds clone flags: not CLONE_NEWUSER. 5 instructions.
static void judge_new_user(struct program *p, long number, int index) {
    JUDGE(number, 4);
    LOAD(VIBE_ARGUMENT_LOW(index));
    add(p, BPF_JMP | BPF_JSET | BPF_K, 0, 1, CLONE_NEWUSER);
    RETURN(VIBE_REFUSE);
    RETURN(VIBE_ALLOW);
}

int vibe_sandbox_load_filter(int nesting) {
#ifndef VIBE_AUDIT_ARCH
    (void)nesting;
    errno = ENOSYS;
    return -1;
#else
    struct program filter = { .length = 0, .overflow = 0 };
    struct program *p = &filter;

    LOAD(offsetof(struct seccomp_data, arch));
    IF_EQUAL(VIBE_AUDIT_ARCH);
    add(p, BPF_JMP | BPF_JA, 0, 0, 1);
    RETURN(VIBE_KILL);
    LOAD_NUMBER();
#if defined(__x86_64__)
    add(p, BPF_JMP | BPF_JGE | BPF_K, 0, 1, VIBE_X32_SYSCALL_BIT);
    RETURN(VIBE_KILL);
#endif
    for (size_t index = 0; index < sizeof(refused) / sizeof(refused[0]); index++) {
        IF_EQUAL(refused[index]);
        RETURN(VIBE_REFUSE);
    }
    judge_family(p, SYS_socket);
    judge_family(p, SYS_socketpair);
    judge_ioctl(p);
    if (!nesting) {
        for (size_t index = 0; index < sizeof(refused_without_nesting) / sizeof(refused_without_nesting[0]); index++) {
            IF_EQUAL(refused_without_nesting[index]);
            RETURN(VIBE_REFUSE);
        }
        IF_EQUAL(SYS_clone3);
        RETURN(VIBE_NOT_THERE);
        judge_new_user(p, SYS_unshare, 0);
        judge_new_user(p, SYS_clone, 0);
    }
    RETURN(VIBE_ALLOW);
    if (filter.overflow) {
        errno = E2BIG;
        return -1;
    }

    struct sock_fprog program = { .len = filter.length, .filter = filter.code };
    return prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program, 0, 0);
#endif
}
#endif
