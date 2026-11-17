// The session sandbox's box, built from the kernel's namespaces and a seccomp filter: the plan as C sees it, the call
// that enters it, and the probes `Platform.Sandbox.probe()` reads. Included by CVibePlatform.h, under its `__linux__`;
// the bodies are shim_sandbox.c's (the box) and shim_seccomp.c's (the filter). The order of the steps, which a review
// checks line by line, is the session sandbox plan's (docs/superpowers/plans/2026-11-17-v2-session-sandbox.md, SB1).
#ifndef CVIBEPLATFORM_SANDBOX_H
#define CVIBEPLATFORM_SANDBOX_H
#ifdef __linux__

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

// What a mount of the plan is (`Platform.Sandbox.Mount.Kind`). Every mount is nosuid and nodev, but a device's, which
// is nosuid and noexec.
enum {
    VIBE_MOUNT_READ_ONLY = 1,  // `source` bound read-only, with every mount below it
    VIBE_MOUNT_READ_WRITE = 2, // `source` bound, with every mount below it
    VIBE_MOUNT_OVERLAY = 3,    // reads `source`, writes go to `upper` (with `work` beside it)
    VIBE_MOUNT_EMPTY = 4,      // a fresh tmpfs of `mode`
    VIBE_MOUNT_PROC = 5,       // the box's own /proc
    VIBE_MOUNT_DEVPTS = 6,     // a devpts of the box's own (newinstance)
    VIBE_MOUNT_SYSFS = 7,      // sysfs, read-only: the kernel allows it only in a network namespace of the box's own
    VIBE_MOUNT_DEVICE = 8,     // the device node /dev/`source` (a bare name), bound
    VIBE_MOUNT_LINK = 9,       // a symbolic link whose text is `source`
    VIBE_MOUNT_FILE = 10,      // a file of `contents` (`length` bytes) and `mode`, in the root's own tmpfs
};

struct vibe_sandbox_mount {
    int kind;
    // Absolute, with no `..` and no symbolic link along it inside the box.
    const char *target;
    // Absolute, as the process that enters sees it, with no symbolic link along it (for READ_ONLY, READ_WRITE and
    // OVERLAY); a bare name (DEVICE); the link's text (LINK); NULL otherwise.
    const char *source;
    const char *upper;
    const char *work;
    const void *contents;
    size_t length;
    unsigned int mode;
};

// `Platform.Sandbox.Network`.
enum { VIBE_NETWORK_SHARED = 0, VIBE_NETWORK_NONE = 1, VIBE_NETWORK_PROXIED = 2 };
// `Platform.Sandbox.Terminal`.
enum { VIBE_TERMINAL_FOREGROUND = 0, VIBE_TERMINAL_NONE = 1 };

struct vibe_sandbox_plan {
    const struct vibe_sandbox_mount *mounts;
    size_t mount_count;
    int network;
    // The port the proxy's listener is bound to on the box's loopback (PROXIED).
    uint16_t proxy_port;
    const char *hostname;
    // Where the program starts, inside.
    const char *directory;
    // The program's environment, "NAME=value" each, NULL at the end.
    char *const *environment;
    // Where init binds the door, inside; NULL: no door.
    const char *door;
    int terminal;
    // Whether the filter lets the program make user namespaces and mounts of its own.
    int nesting;
    // The program: its path inside, then its argv, NULL at the end.
    const char *path;
    char *const *arguments;
    // The descriptor each door connection is sent on (SCM_RIGHTS), or -1 (with no door).
    int door_line;
    // The descriptor the proxy's listener is sent on, or -1 (unless PROXIED).
    int proxy_out;
};

// The step that failed, named as the plan's order names it ("threads", "unshare", "uid map", "mount /usr", "pivot",
// "filter", "exec", …), and its error number.
struct vibe_sandbox_failure {
    char step[512];
    int code;
};

// Enters `plan` and runs its program in it: for a single-threaded process, as its last act. It returns only when
// nothing was started, with `failure` filled: no step is skipped, and a step that fails ends every process the call
// had made. Otherwise this process becomes the box's keeper and never returns: it exits as the program did (its
// status, or the signal that ended it raised again on itself). -1 when it returns.
int vibe_sandbox_enter(const struct vibe_sandbox_plan *plan, struct vibe_sandbox_failure *failure);

// The seccomp filter alone, loaded on this thread: the program's last step before its exec. The caller sets
// no_new_privs first (without it, or CAP_SYS_ADMIN, the kernel refuses a filter: EACCES). 0, or -1 and errno.
int vibe_sandbox_load_filter(int nesting);

// Probes, each in this process and harmless to it.
// landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION): the ABI, or 0 where Landlock is off or missing.
int vibe_sandbox_landlock_abi(void);
// Whether socket(AF_VSOCK, SOCK_STREAM) succeeds here (the socket closed at once): 1, else 0.
int vibe_sandbox_vsock_opens(void);
// Whether the kernel knows the overlay file system (/proc/filesystems): 1, else 0.
int vibe_sandbox_overlay_known(void);

#endif
#endif
