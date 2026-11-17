// The session sandbox's box (CVibePlatform_sandbox.h): namespaces, the uid and gid maps, the mounts, the pivot, the
// keeper, init and the program, in the order the session sandbox plan gives (SB1), each step failing closed. Compiled
// under `_GNU_SOURCE`, on glibc and on musl: the newer calls (open_tree, move_mount, fsopen, mount_setattr, openat2,
// close_range) go through syscall(2) with their own numbers and structures, which neither C library is sure to have.
//
// Three processes come out of one call:
// - the keeper: the process that called, after it made the namespaces. It stays outside the box's pid namespace, the
//   leader of its terminal, and exits as the program did.
// - init: its child, pid 1 inside. It builds the root, then starts the program, passes door connections on, reaps,
//   and ends with the program, which ends every process left in the namespace.
// - the program: init's child, with no capability, no_new_privs and the filter, holding descriptors 0, 1 and 2.
//
// A step that fails before the program's exec reaches the keeper as a failure record on a socket pair between them;
// the keeper then collects init and returns the record to its caller. Nothing of the plan has run by then.
#ifdef __linux__
#define _GNU_SOURCE
#include "CVibePlatform.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <net/if.h>
#include <netinet/in.h>
#include <poll.h>
#include <sched.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/signalfd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <linux/capability.h>

// The kernel's numbers for the calls a C library may not wrap; the same on every architecture (the unified table).
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
#ifndef SYS_close_range
#define SYS_close_range 436
#endif
#ifndef SYS_openat2
#define SYS_openat2 437
#endif
#ifndef SYS_mount_setattr
#define SYS_mount_setattr 442
#endif
#ifndef SYS_landlock_create_ruleset
#define SYS_landlock_create_ruleset 444
#endif

// Their flags and structures (<linux/mount.h>, <linux/openat2.h>, <linux/close_range.h>), under names of our own: glibc's
// <sys/mount.h> defines some of them, and <linux/mount.h> beside it doesn't compile.
#define VIBE_OPEN_TREE_CLONE 1u
#define VIBE_AT_RECURSIVE 0x8000
#define VIBE_AT_EMPTY_PATH 0x1000
#define VIBE_MOVE_MOUNT_F_EMPTY_PATH 0x4u
#define VIBE_MOVE_MOUNT_T_EMPTY_PATH 0x40u
#define VIBE_FSOPEN_CLOEXEC 1u
#define VIBE_FSCONFIG_SET_FLAG 0u
#define VIBE_FSCONFIG_SET_STRING 1u
#define VIBE_FSCONFIG_CMD_CREATE 6u
#define VIBE_FSMOUNT_CLOEXEC 1u
#define VIBE_MOUNT_ATTR_RDONLY 0x1ull
#define VIBE_MOUNT_ATTR_NOSUID 0x2ull
#define VIBE_MOUNT_ATTR_NODEV 0x4ull
#define VIBE_MOUNT_ATTR_NOEXEC 0x8ull
#define VIBE_RESOLVE_NO_MAGICLINKS 0x02ull
#define VIBE_RESOLVE_NO_SYMLINKS 0x04ull
#define VIBE_RESOLVE_IN_ROOT 0x10ull
#define VIBE_CLOSE_RANGE_CLOEXEC (1u << 2)
#define VIBE_AF_VSOCK 40

struct vibe_mount_attr {
    uint64_t attr_set;
    uint64_t attr_clr;
    uint64_t propagation;
    uint64_t userns_fd;
};

struct vibe_open_how {
    uint64_t flags;
    uint64_t mode;
    uint64_t resolve;
};

// MUTATION ONLY. Built with -DVIBE_SANDBOX_MUTATION (never in a product build: SandboxLintTests checks no build
// setting names it), `VIBE_SANDBOX_SKIP=<step>` skips that step, so that a run of the suite shows a test failing
// without each step (scripts/sandbox-mutation.sh). Without the macro `skipped` is false and the compiler drops it.
#ifdef VIBE_SANDBOX_MUTATION
static int skipped(const char *step) {
    const char *skip = getenv("VIBE_SANDBOX_SKIP");
    return skip != NULL && strcmp(skip, step) == 0;
}
#else
#define skipped(step) 0
#endif

// MARK: Failures

// One message on the line between init and the keeper.
struct line_message {
    char kind;  // 'F' a failure (nothing started), 'S' the program started, 'X' the program ended
    int code;   // the error number ('F') or the program's wait status ('X')
    char step[512];
};

static void name_step(struct vibe_sandbox_failure *failure, int code, const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(failure->step, sizeof(failure->step), format, arguments);
    va_end(arguments);
    failure->code = code;
}

// A write of all of `length`, again after EINTR.
static int write_all(int fd, const void *bytes, size_t length) {
    const char *at = bytes;
    while (length > 0) {
        ssize_t wrote = write(fd, at, length);
        if (wrote < 0 && errno == EINTR) continue;
        if (wrote <= 0) return -1;
        at += wrote;
        length -= (size_t)wrote;
    }
    return 0;
}

static int send_message(int line, char kind, int code, const char *step) {
    struct line_message message;
    memset(&message, 0, sizeof(message));
    message.kind = kind;
    message.code = code;
    if (step != NULL) snprintf(message.step, sizeof(message.step), "%s", step);
    for (;;) {
        ssize_t sent = send(line, &message, sizeof(message), MSG_NOSIGNAL);
        if (sent < 0 && errno == EINTR) continue;
        return sent == (ssize_t)sizeof(message) ? 0 : -1;
    }
}

// MARK: The calls

static int sys_open_tree(int dirfd, const char *path, unsigned int flags) {
    return (int)syscall(SYS_open_tree, dirfd, path, flags);
}

static int sys_move_mount(int from_dirfd, const char *from_path, int to_dirfd, const char *to_path, unsigned int flags) {
    return (int)syscall(SYS_move_mount, from_dirfd, from_path, to_dirfd, to_path, flags);
}

static int sys_fsopen(const char *name, unsigned int flags) { return (int)syscall(SYS_fsopen, name, flags); }

static int sys_fsconfig(int fd, unsigned int command, const char *key, const void *value, int aux) {
    return (int)syscall(SYS_fsconfig, fd, command, key, value, aux);
}

static int sys_fsmount(int fd, unsigned int flags, unsigned int attributes) {
    return (int)syscall(SYS_fsmount, fd, flags, attributes);
}

static int sys_mount_setattr(int dirfd, const char *path, unsigned int flags, uint64_t set) {
    struct vibe_mount_attr attributes;
    memset(&attributes, 0, sizeof(attributes));
    attributes.attr_set = set;
    return (int)syscall(SYS_mount_setattr, dirfd, path, flags, &attributes, sizeof(attributes));
}

static int sys_openat2(int dirfd, const char *path, uint64_t flags, uint64_t resolve) {
    struct vibe_open_how how;
    memset(&how, 0, sizeof(how));
    how.flags = flags;
    how.resolve = resolve;
    return (int)syscall(SYS_openat2, dirfd, path, &how, sizeof(how));
}

static int sys_pivot_root(const char *new_root, const char *put_old) {
    return (int)syscall(SYS_pivot_root, new_root, put_old);
}

// MARK: Before the fork

// Whether this process has more than one thread: unshare(CLONE_NEWUSER) refuses one, and a fork of one copies a
// single thread of a process whose locks others may hold.
static int threads(void) {
    DIR *tasks = opendir("/proc/self/task");
    if (tasks == NULL) return -1;
    int count = 0;
    struct dirent *entry;
    while ((entry = readdir(tasks)) != NULL) {
        if (entry->d_name[0] != '.') count++;
    }
    closedir(tasks);
    return count;
}

static int write_file(const char *path, const char *text) {
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    int result = write_all(fd, text, strlen(text));
    int code = errno;
    close(fd);
    errno = code;
    return result;
}

// MARK: Paths

// Whether `path` is absolute, has no empty, `.` or `..` component, and fits.
static int plain_path(const char *path) {
    if (path == NULL || path[0] != '/' || strlen(path) >= PATH_MAX) return 0;
    const char *at = path + 1;
    while (*at != '\0') {
        const char *end = strchr(at, '/');
        size_t length = end ? (size_t)(end - at) : strlen(at);
        if (length == 0 || (length == 1 && at[0] == '.') || (length == 2 && at[0] == '.' && at[1] == '.')) return 0;
        at += length;
        if (*at == '/') at++;
    }
    return 1;
}

// The folder that holds `target` inside the new root, made as needed (0755) and opened (O_PATH), every component a
// folder and none a link; its last component's name in `name`. -1 and errno.
static int parent_of(int root, const char *target, char *name, size_t room) {
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s", target + 1);
    char *last = strrchr(path, '/');
    const char *leaf = last ? last + 1 : path;
    if (strlen(leaf) == 0 || strlen(leaf) >= room) {
        errno = EINVAL;
        return -1;
    }
    snprintf(name, room, "%s", leaf);
    int folder = fcntl(root, F_DUPFD_CLOEXEC, 3);
    if (folder < 0 || last == NULL) return folder;
    *last = '\0';
    char *component = path;
    while (component != NULL) {
        char *slash = strchr(component, '/');
        if (slash) *slash = '\0';
        if (mkdirat(folder, component, 0755) != 0 && errno != EEXIST) {
            int code = errno;
            close(folder);
            errno = code;
            return -1;
        }
        int next = openat(folder, component, O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        int code = errno;
        close(folder);
        if (next < 0) {
            errno = code;
            return -1;
        }
        folder = next;
        component = slash ? slash + 1 : NULL;
    }
    return folder;
}

// The mount point `name` in `folder`: a folder, or an empty file when `file`, made unless it is there; opened (O_PATH)
// with no link followed. -1 and errno.
static int mount_point(int folder, const char *name, int file) {
    if (file) {
        int made = openat(folder, name, O_CREAT | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0644);
        if (made < 0 && errno != EISDIR) return -1;
        if (made >= 0) close(made);
    } else if (mkdirat(folder, name, 0755) != 0 && errno != EEXIST) {
        return -1;
    }
    int point = openat(folder, name, O_PATH | O_NOFOLLOW | O_CLOEXEC);
    if (point < 0) return -1;
    // A folder, or a regular file for a file: never a link (O_PATH | O_NOFOLLOW opens a link itself).
    struct stat info;
    if (fstat(point, &info) != 0 || (file ? !S_ISREG(info.st_mode) : !S_ISDIR(info.st_mode))) {
        int code = S_ISLNK(info.st_mode) ? ELOOP : (file ? EISDIR : ENOTDIR);
        close(point);
        errno = code;
        return -1;
    }
    return point;
}

// `source`, a path outside, opened (O_PATH) beneath the old root as if it were `/`, with no link along it.
static int open_source(int old_root, const char *source) {
    if (!plain_path(source)) {
        errno = EINVAL;
        return -1;
    }
    return sys_openat2(old_root, source + 1, O_PATH | O_CLOEXEC, VIBE_RESOLVE_IN_ROOT | VIBE_RESOLVE_NO_SYMLINKS | VIBE_RESOLVE_NO_MAGICLINKS);
}

// A new file system of `type`, configured by `options` ("key=value" or a flag "key", NULL at the end), mounted
// detached with `attributes`, then moved onto `point`.
static int mount_new(const char *type, const char *const *options, unsigned int attributes, int point) {
    int context = sys_fsopen(type, VIBE_FSOPEN_CLOEXEC);
    if (context < 0) return -1;
    for (const char *const *option = options; option && *option; option++) {
        char key[64];
        const char *equals = strchr(*option, '=');
        int result;
        if (equals) {
            snprintf(key, sizeof(key), "%.*s", (int)(equals - *option), *option);
            result = sys_fsconfig(context, VIBE_FSCONFIG_SET_STRING, key, equals + 1, 0);
        } else {
            result = sys_fsconfig(context, VIBE_FSCONFIG_SET_FLAG, *option, NULL, 0);
        }
        if (result != 0) {
            int code = errno;
            close(context);
            errno = code;
            return -1;
        }
    }
    if (sys_fsconfig(context, VIBE_FSCONFIG_CMD_CREATE, NULL, NULL, 0) != 0) {
        int code = errno;
        close(context);
        errno = code;
        return -1;
    }
    int mounted = sys_fsmount(context, VIBE_FSMOUNT_CLOEXEC, attributes);
    int code = errno;
    close(context);
    if (mounted < 0) {
        errno = code;
        return -1;
    }
    int result = sys_move_mount(mounted, "", point, "", VIBE_MOVE_MOUNT_F_EMPTY_PATH | VIBE_MOVE_MOUNT_T_EMPTY_PATH);
    code = errno;
    close(mounted);
    errno = code;
    return result;
}

// `source` (an open O_PATH descriptor) bound onto `point`, with every mount below it when `recursive`, then
// `attributes` added to each of them. The point is reopened after the move: the descriptor held before names the
// folder under the new mount.
static int bind_tree(int source, int folder, const char *name, int point, int recursive, uint64_t attributes) {
    unsigned int flags = VIBE_OPEN_TREE_CLONE | O_CLOEXEC | VIBE_AT_EMPTY_PATH | (recursive ? VIBE_AT_RECURSIVE : 0);
    int tree = sys_open_tree(source, "", flags);
    if (tree < 0) return -1;
    int result = sys_move_mount(tree, "", point, "", VIBE_MOVE_MOUNT_F_EMPTY_PATH | VIBE_MOVE_MOUNT_T_EMPTY_PATH);
    int code = errno;
    close(tree);
    if (result != 0) {
        errno = code;
        return -1;
    }
    int mounted = openat(folder, name, O_PATH | O_NOFOLLOW | O_CLOEXEC);
    if (mounted < 0) return -1;
    result = skipped("attributes") ? 0
        : sys_mount_setattr(mounted, "", VIBE_AT_EMPTY_PATH | (recursive ? VIBE_AT_RECURSIVE : 0), attributes);
    code = errno;
    close(mounted);
    errno = code;
    return result;
}

// Whether `path` can go into overlayfs's options: no comma, colon, backslash or equals sign.
static int overlay_safe(const char *path) { return path && strpbrk(path, ",:\\=") == NULL; }

// One mount of the plan, made under the new root (`root`) from the old one (`old_root`, the machine's `/`).
static int apply_mount(const struct vibe_sandbox_mount *mount, int root, int old_root) {
    if (!plain_path(mount->target) || strcmp(mount->target, "/") == 0) {
        errno = EINVAL;
        return -1;
    }
    char name[NAME_MAX + 1];
    int folder = parent_of(root, mount->target, name, sizeof(name));
    if (folder < 0) return -1;
    int result = -1, point = -1, source = -1;
    const uint64_t locked = VIBE_MOUNT_ATTR_NOSUID | VIBE_MOUNT_ATTR_NODEV;
    switch (mount->kind) {
    case VIBE_MOUNT_READ_ONLY:
    case VIBE_MOUNT_READ_WRITE: {
        source = open_source(old_root, mount->source);
        if (source < 0) break;
        struct stat info;
        if (fstat(source, &info) != 0) break;
        point = mount_point(folder, name, !S_ISDIR(info.st_mode));
        if (point < 0) break;
        uint64_t attributes = locked | (mount->kind == VIBE_MOUNT_READ_ONLY && !skipped("read-only") ? VIBE_MOUNT_ATTR_RDONLY : 0);
        result = bind_tree(source, folder, name, point, 1, attributes);
        break;
    }
    case VIBE_MOUNT_OVERLAY: {
        if (!overlay_safe(mount->source) || !overlay_safe(mount->upper) || !overlay_safe(mount->work)) {
            errno = EINVAL;
            break;
        }
        // Each folder opened as a source is (beneath the old root, no link along it), then named to overlayfs by that
        // descriptor (the machine's /proc, under the old root): nothing renamed between the check and the mount
        // changes which folder it is.
        const char *folders[3] = { mount->source, mount->upper, mount->work };
        int opened[3] = { -1, -1, -1 };
        int checked = 1;
        for (int index = 0; index < 3 && checked; index++) {
            opened[index] = open_source(old_root, folders[index]);
            if (opened[index] < 0) checked = 0;
        }
        if (checked) point = mount_point(folder, name, 0);
        if (checked && point >= 0) {
            char lower[64], upper[64], work[64];
            snprintf(lower, sizeof(lower), "lowerdir=/oldroot/proc/self/fd/%d", opened[0]);
            snprintf(upper, sizeof(upper), "upperdir=/oldroot/proc/self/fd/%d", opened[1]);
            snprintf(work, sizeof(work), "workdir=/oldroot/proc/self/fd/%d", opened[2]);
            const char *options[] = { lower, upper, work, "userxattr", NULL };
            result = mount_new("overlay", options, (unsigned int)VIBE_MOUNT_ATTR_NOSUID | (unsigned int)VIBE_MOUNT_ATTR_NODEV, point);
        }
        int code = errno;
        for (int index = 0; index < 3; index++) if (opened[index] >= 0) close(opened[index]);
        errno = code;
        break;
    }
    case VIBE_MOUNT_EMPTY: {
        point = mount_point(folder, name, 0);
        if (point < 0) break;
        char mode[32];
        snprintf(mode, sizeof(mode), "mode=0%o", mount->mode & 07777);
        const char *options[] = { mode, NULL };
        result = mount_new("tmpfs", options, (unsigned int)VIBE_MOUNT_ATTR_NOSUID | (unsigned int)VIBE_MOUNT_ATTR_NODEV, point);
        break;
    }
    case VIBE_MOUNT_PROC: {
        point = mount_point(folder, name, 0);
        if (point < 0) break;
        result = mount_new("proc", NULL, (unsigned int)VIBE_MOUNT_ATTR_NOSUID | (unsigned int)VIBE_MOUNT_ATTR_NODEV | (unsigned int)VIBE_MOUNT_ATTR_NOEXEC, point);
        break;
    }
    case VIBE_MOUNT_DEVPTS: {
        point = mount_point(folder, name, 0);
        if (point < 0) break;
        const char *options[] = { "newinstance", "ptmxmode=0666", "mode=0620", NULL };
        result = mount_new("devpts", options, (unsigned int)VIBE_MOUNT_ATTR_NOSUID | (unsigned int)VIBE_MOUNT_ATTR_NOEXEC, point);
        break;
    }
    case VIBE_MOUNT_SYSFS: {
        point = mount_point(folder, name, 0);
        if (point < 0) break;
        result = mount_new("sysfs", NULL, (unsigned int)VIBE_MOUNT_ATTR_RDONLY | (unsigned int)VIBE_MOUNT_ATTR_NOSUID | (unsigned int)VIBE_MOUNT_ATTR_NODEV | (unsigned int)VIBE_MOUNT_ATTR_NOEXEC, point);
        break;
    }
    case VIBE_MOUNT_DEVICE: {
        // A bare name of the machine's /dev, a character device: never a path.
        const char *device = mount->source;
        if (device == NULL || device[0] == '\0' || strlen(device) > 32 || strspn(device, "abcdefghijklmnopqrstuvwxyz0123456789") != strlen(device)) {
            errno = EINVAL;
            break;
        }
        char path[64];
        snprintf(path, sizeof(path), "dev/%s", device);
        source = openat(old_root, path, O_PATH | O_NOFOLLOW | O_CLOEXEC);
        if (source < 0) break;
        struct stat info;
        if (fstat(source, &info) != 0) break;
        if (!S_ISCHR(info.st_mode)) {
            errno = ENODEV;
            break;
        }
        point = mount_point(folder, name, 1);
        if (point < 0) break;
        result = bind_tree(source, folder, name, point, 0, VIBE_MOUNT_ATTR_NOSUID | VIBE_MOUNT_ATTR_NOEXEC);
        break;
    }
    case VIBE_MOUNT_LINK:
        if (mount->source == NULL || mount->source[0] == '\0') {
            errno = EINVAL;
            break;
        }
        result = symlinkat(mount->source, folder, name);
        break;
    case VIBE_MOUNT_FILE: {
        int made = openat(folder, name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (made < 0) break;
        result = write_all(made, mount->contents, mount->length);
        if (result == 0) result = fchmod(made, mount->mode & 07777);
        int code = errno;
        close(made);
        errno = code;
        break;
    }
    default:
        errno = EINVAL;
    }
    int code = errno;
    if (point >= 0) close(point);
    if (source >= 0) close(source);
    close(folder);
    errno = code;
    return result;
}

// MARK: Init

// What init holds that its handlers need.
static int init_line = -1;

// Init's failures: the record to the keeper, then the end. Nothing of the plan has run.
static void init_fails(int code, const char *format, ...) {
    char step[512];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(step, sizeof(step), format, arguments);
    va_end(arguments);
    send_message(init_line, 'F', code, step);
    _exit(127);
}

// The new root, built from the machine's: a tmpfs over /tmp as a base, the machine's root pivoted under it at
// /oldroot, a second tmpfs at /newroot that every mount of the plan goes into, then /newroot pivoted into place over
// the base, and the base detached with the machine's root under it (one detach: bubblewrap detaches /oldroot first,
// which changes nothing seen inside, measured). The root's own folders are then read-only. (bubblewrap's way: the base
// keeps the machine's /tmp, and every source is reached beneath /oldroot.)
static void build_root(const struct vibe_sandbox_plan *plan) {
    if (!skipped("private") && mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) init_fails(errno, "private mount tree");
    if (mount("tmpfs", "/tmp", "tmpfs", MS_NOSUID | MS_NODEV, "mode=0700") != 0) init_fails(errno, "the base");
    if (chdir("/tmp") != 0 || mkdir("newroot", 0755) != 0 || mkdir("oldroot", 0755) != 0) init_fails(errno, "the base");
    if (sys_pivot_root(".", "oldroot") != 0) init_fails(errno, "pivot to the base");
    if (chdir("/") != 0) init_fails(errno, "pivot to the base");
    if (mount("tmpfs", "/newroot", "tmpfs", MS_NOSUID | MS_NODEV, "mode=0755") != 0) init_fails(errno, "the root");
    int old_root = open("/oldroot", O_PATH | O_DIRECTORY | O_CLOEXEC);
    int root = open("/newroot", O_PATH | O_DIRECTORY | O_CLOEXEC);
    if (old_root < 0 || root < 0) init_fails(errno, "the root");
    for (size_t index = 0; index < plan->mount_count; index++) {
        const struct vibe_sandbox_mount *mount = &plan->mounts[index];
        if (apply_mount(mount, root, old_root) != 0) init_fails(errno, "mount %s", mount->target ? mount->target : "(none)");
    }
    close(old_root);
    close(root);
    if (chdir("/newroot") != 0 || sys_pivot_root(".", ".") != 0) init_fails(errno, "pivot to the root");
    if (umount2(".", MNT_DETACH) != 0 || chdir("/") != 0) init_fails(errno, "pivot to the root");
    if (!skipped("root read-only")
        && sys_mount_setattr(AT_FDCWD, "/", 0, VIBE_MOUNT_ATTR_RDONLY | VIBE_MOUNT_ATTR_NOSUID | VIBE_MOUNT_ATTR_NODEV) != 0) {
        init_fails(errno, "the root read-only");
    }
}

static void loopback_up(void) {
    int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) init_fails(errno, "loopback");
    struct ifreq request;
    memset(&request, 0, sizeof(request));
    snprintf(request.ifr_name, sizeof(request.ifr_name), "lo");
    if (ioctl(fd, SIOCGIFFLAGS, &request) != 0) init_fails(errno, "loopback");
    request.ifr_flags |= IFF_UP;
    if (ioctl(fd, SIOCSIFFLAGS, &request) != 0) init_fails(errno, "loopback");
    close(fd);
}

// The door: a stream socket bound at `path`, 0700 (only the box's own user connects), listening, non-blocking (init
// polls it).
static int open_door(const char *path) {
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    if (!plain_path(path) || strlen(path) >= sizeof(address.sun_path)) init_fails(ENAMETOOLONG, "door");
    snprintf(address.sun_path, sizeof(address.sun_path), "%s", path);
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0) init_fails(errno, "door");
    mode_t before = umask(0077);
    int bound = bind(fd, (struct sockaddr *)&address, sizeof(address));
    int code = errno;
    umask(before);
    if (bound != 0) init_fails(code, "door");
    if (listen(fd, 64) != 0) init_fails(errno, "door");
    return fd;
}

// The proxy's listener: 127.0.0.1:`port` in the box's own network namespace, sent out on `out` and closed here.
static void hand_out_listener(uint16_t port, int out) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) init_fails(errno, "proxy listener");
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0) init_fails(errno, "proxy listener");
    if (listen(fd, 128) != 0) init_fails(errno, "proxy listener");
    if (vibe_send_descriptor(out, fd) != 0) init_fails(errno, "proxy listener");
    close(fd);
    close(out);
}

// MARK: The program

// The program's failures, before its exec: the record to init, which sends it on.
static void program_fails(int report, int code, const char *step) {
    struct line_message message;
    memset(&message, 0, sizeof(message));
    message.kind = 'F';
    message.code = code;
    snprintf(message.step, sizeof(message.step), "%s", step);
    write_all(report, &message, sizeof(message));
    _exit(127);
}

static void become_program(const struct vibe_sandbox_plan *plan, int report) {
    // Signals at their defaults, none blocked: init's mask and handlers are init's.
    sigset_t none;
    sigemptyset(&none);
    for (int signal_number = 1; signal_number < NSIG; signal_number++) {
        if (signal_number != SIGKILL && signal_number != SIGSTOP) signal(signal_number, SIG_DFL);
    }
    if (sigprocmask(SIG_SETMASK, &none, NULL) != 0) program_fails(report, errno, "signals");

    // Its terminal's foreground group, in the keeper's session; or a session of its own with no terminal.
    if (plan->terminal == VIBE_TERMINAL_FOREGROUND) {
        if (setpgid(0, 0) != 0) program_fails(report, errno, "process group");
        if (!isatty(STDIN_FILENO)) program_fails(report, ENOTTY, "terminal");
        signal(SIGTTOU, SIG_IGN);
        if (!skipped("foreground") && tcsetpgrp(STDIN_FILENO, getpid()) != 0) program_fails(report, errno, "terminal");
        signal(SIGTTOU, SIG_DFL);
    } else if (!skipped("session") && setsid() < 0) {
        program_fails(report, errno, "session");
    }

    if (chdir(plan->directory) != 0) program_fails(report, errno, "directory");

    // No capability in any set, the bounding set included, and none to be gained.
    if (!skipped("capabilities")) {
        for (int capability = 0; capability <= 63; capability++) {
            if (prctl(PR_CAPBSET_DROP, capability, 0, 0, 0) != 0 && errno != EINVAL) program_fails(report, errno, "bounding set");
        }
        if (prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0) != 0) program_fails(report, errno, "ambient capabilities");
        struct __user_cap_header_struct header = { _LINUX_CAPABILITY_VERSION_3, 0 };
        struct __user_cap_data_struct data[_LINUX_CAPABILITY_U32S_3];
        memset(data, 0, sizeof(data));
        if (syscall(SYS_capset, &header, data) != 0) program_fails(report, errno, "capabilities");
    }
    if (!skipped("no_new_privs") && prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) program_fails(report, errno, "no_new_privs");

    // Descriptors 0, 1 and 2 only: every other one closes at the exec (this report's last).
    if (!skipped("descriptors") && syscall(SYS_close_range, 3u, ~0u, VIBE_CLOSE_RANGE_CLOEXEC) != 0) {
        program_fails(report, errno, "descriptors");
    }
    if (!skipped("filter") && vibe_sandbox_load_filter(plan->nesting) != 0) program_fails(report, errno, "filter");
    execve(plan->path, plan->arguments, plan->environment);
    program_fails(report, errno, "exec");
}

static void init_forwards(int signal_number) { (void)signal_number; }

static void be_init(const struct vibe_sandbox_plan *plan, int line) {
    init_line = line;
    // Killed with its keeper. The keeper may have died before this was set: its end of the line tells.
    if (!skipped("death signal") && prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0) != 0) init_fails(errno, "death signal");
    if (vibe_peer_has_gone(line)) _exit(127);

    build_root(plan);
    if (plan->hostname && sethostname(plan->hostname, strlen(plan->hostname)) != 0) init_fails(errno, "hostname");
    if (plan->network != VIBE_NETWORK_SHARED) loopback_up();
    int door = plan->door ? open_door(plan->door) : -1;
    if (door >= 0 && fcntl(plan->door_line, F_SETFL, fcntl(plan->door_line, F_GETFL) | O_NONBLOCK) != 0) init_fails(errno, "door line");
    if (plan->network == VIBE_NETWORK_PROXIED) hand_out_listener(plan->proxy_port, plan->proxy_out);
    else if (plan->proxy_out >= 0) close(plan->proxy_out);
    if (!skipped("not dumpable") && prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) != 0) init_fails(errno, "not dumpable");

    // The signals init waits on, read from a descriptor; the keeper's three come on to the program.
    sigset_t waited;
    sigemptyset(&waited);
    sigaddset(&waited, SIGCHLD);
    sigaddset(&waited, SIGHUP);
    sigaddset(&waited, SIGTERM);
    sigaddset(&waited, SIGINT);
    struct sigaction handler;
    memset(&handler, 0, sizeof(handler));
    handler.sa_handler = init_forwards;
    sigaction(SIGHUP, &handler, NULL);
    sigaction(SIGTERM, &handler, NULL);
    sigaction(SIGINT, &handler, NULL);
    if (sigprocmask(SIG_BLOCK, &waited, NULL) != 0) init_fails(errno, "signals");
    int signals = signalfd(-1, &waited, SFD_CLOEXEC | SFD_NONBLOCK);
    if (signals < 0) init_fails(errno, "signals");

    int report[2];
    if (pipe2(report, O_CLOEXEC) != 0) init_fails(errno, "start the program");
    pid_t program = fork();
    if (program < 0) init_fails(errno, "start the program");
    if (program == 0) {
        close(report[0]);
        close(line);
        close(signals);
        if (door >= 0) close(door);
        become_program(plan, report[1]);
    }
    close(report[1]);
    struct line_message failure;
    ssize_t got;
    do got = read(report[0], &failure, sizeof(failure)); while (got < 0 && errno == EINTR);
    close(report[0]);
    if (got == (ssize_t)sizeof(failure)) {
        int status;
        while (waitpid(program, &status, 0) < 0 && errno == EINTR) {}
        send_message(line, 'F', failure.code, failure.step);
        _exit(127);
    }
    send_message(line, 'S', 0, NULL);

    for (;;) {
        struct pollfd watched[2] = { { signals, POLLIN, 0 }, { door, POLLIN, 0 } };
        int count = door >= 0 ? 2 : 1;
        if (poll(watched, (nfds_t)count, -1) < 0 && errno != EINTR) _exit(127);
        if (watched[0].revents & POLLIN) {
            struct signalfd_siginfo info;
            while (read(signals, &info, sizeof(info)) == (ssize_t)sizeof(info)) {
                if (info.ssi_signo != SIGCHLD) {
                    if (kill(-program, (int)info.ssi_signo) != 0) kill(program, (int)info.ssi_signo);
                }
            }
            int status;
            pid_t ended;
            while ((ended = waitpid(-1, &status, WNOHANG)) > 0) {
                if (ended == program) {
                    send_message(line, 'X', status, NULL);
                    _exit(WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status));
                }
            }
        }
        if (count == 2 && (watched[1].revents & POLLIN)) {
            int connection;
            while ((connection = accept4(door, NULL, NULL, SOCK_CLOEXEC)) >= 0) {
                // Sent whole, never read; dropped when the line can't take it now.
                vibe_send_descriptor(plan->door_line, connection);
                close(connection);
            }
        }
    }
}

// MARK: The keeper

static volatile pid_t keeper_init = 0;

static void keeper_forwards(int signal_number) {
    if (keeper_init > 0) kill(keeper_init, signal_number);
}

// Exits as the program did: its status, or its signal raised again on this process.
static void exit_as(int status) {
    if (WIFSIGNALED(status)) {
        int signal_number = WTERMSIG(status);
        signal(signal_number, SIG_DFL);
        sigset_t only;
        sigemptyset(&only);
        sigaddset(&only, signal_number);
        sigprocmask(SIG_UNBLOCK, &only, NULL);
        kill(getpid(), signal_number);
        _exit(128 + signal_number);
    }
    _exit(WIFEXITED(status) ? WEXITSTATUS(status) : 127);
}

static int receive_message(int line, struct line_message *message) {
    for (;;) {
        ssize_t got = recv(line, message, sizeof(*message), 0);
        if (got < 0 && errno == EINTR) continue;
        return got == (ssize_t)sizeof(*message) ? 0 : -1;
    }
}

static int keep(pid_t init, int line, struct vibe_sandbox_failure *failure) {
    struct line_message message;
    if (receive_message(line, &message) != 0 || message.kind != 'S') {
        int status = 0;
        while (waitpid(init, &status, 0) < 0 && errno == EINTR) {}
        close(line);
        if (message.kind == 'F') {
            name_step(failure, message.code, "%s", message.step);
        } else {
            name_step(failure, ECHILD, "init ended before the program started");
        }
        return -1;
    }

    // The program runs. The keeper keeps its terminal (0, 1, 2) and its line to init, and nothing else.
    keeper_init = init;
    if (line > 3) syscall(SYS_close_range, 3u, (unsigned int)line - 1, 0u);
    syscall(SYS_close_range, (unsigned int)line + 1, ~0u, 0u);
    struct sigaction forward;
    memset(&forward, 0, sizeof(forward));
    forward.sa_handler = keeper_forwards;
    sigaction(SIGHUP, &forward, NULL);
    sigaction(SIGTERM, &forward, NULL);
    sigaction(SIGINT, &forward, NULL);
    signal(SIGTTOU, SIG_IGN);
    signal(SIGTTIN, SIG_IGN);
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);

    int ended = 0, program_status = 0;
    while (receive_message(line, &message) == 0) {
        if (message.kind == 'X') {
            ended = 1;
            program_status = message.code;
        }
    }
    int status = 0;
    while (waitpid(init, &status, 0) < 0 && errno == EINTR) {}
    exit_as(ended ? program_status : status);
    return -1;
}

// MARK: Entering

int vibe_sandbox_enter(const struct vibe_sandbox_plan *plan, struct vibe_sandbox_failure *failure) {
    memset(failure, 0, sizeof(*failure));
    if (plan == NULL || plan->path == NULL || plan->arguments == NULL || plan->environment == NULL || !plain_path(plan->directory)
        || plan->path[0] != '/' || (plan->mount_count > 0 && plan->mounts == NULL)
        || (plan->door != NULL && (plan->door_line < 0 || !plain_path(plan->door)))
        || (plan->network == VIBE_NETWORK_PROXIED && plan->proxy_out < 0)
        || plan->network < VIBE_NETWORK_SHARED || plan->network > VIBE_NETWORK_PROXIED
        || (plan->terminal != VIBE_TERMINAL_FOREGROUND && plan->terminal != VIBE_TERMINAL_NONE)) {
        name_step(failure, EINVAL, "plan");
        return -1;
    }
    int count = threads();
    if (count != 1) {
        name_step(failure, count < 0 ? errno : EINVAL, "threads");
        return -1;
    }

    // 1. Dumpable, so the maps can be written; the namespaces; the maps, each the user's own id to itself.
    uid_t uid = getuid();
    gid_t gid = getgid();
    if (prctl(PR_SET_DUMPABLE, 1, 0, 0, 0) != 0) {
        name_step(failure, errno, "dumpable");
        return -1;
    }
    int namespaces = CLONE_NEWUSER | CLONE_NEWNS | CLONE_NEWPID | CLONE_NEWIPC | CLONE_NEWUTS | CLONE_NEWCGROUP;
    if (plan->network != VIBE_NETWORK_SHARED && !skipped("network")) namespaces |= CLONE_NEWNET;
    if (skipped("pid")) namespaces &= ~CLONE_NEWPID;
    if (unshare(namespaces) != 0) {
        name_step(failure, errno, "unshare");
        return -1;
    }
    char map[64];
    if (write_file("/proc/self/setgroups", "deny") != 0) {
        name_step(failure, errno, "setgroups");
        return -1;
    }
    snprintf(map, sizeof(map), "%u %u 1\n", (unsigned int)uid, (unsigned int)uid);
    if (write_file("/proc/self/uid_map", map) != 0) {
        name_step(failure, errno, "uid map");
        return -1;
    }
    snprintf(map, sizeof(map), "%u %u 1\n", (unsigned int)gid, (unsigned int)gid);
    if (write_file("/proc/self/gid_map", map) != 0) {
        name_step(failure, errno, "gid map");
        return -1;
    }

    // 2. Init, pid 1 inside; this process its keeper.
    int line[2];
    if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, line) != 0) {
        name_step(failure, errno, "keeper's line");
        return -1;
    }
    pid_t init = fork();
    if (init < 0) {
        name_step(failure, errno, "start init");
        close(line[0]);
        close(line[1]);
        return -1;
    }
    if (init == 0) {
        close(line[0]);
        be_init(plan, line[1]);
        _exit(127);
    }
    close(line[1]);
    if (plan->door_line >= 0) close(plan->door_line);
    if (plan->proxy_out >= 0) close(plan->proxy_out);
    return keep(init, line[0], failure);
}

// MARK: Probes

int vibe_sandbox_landlock_abi(void) {
    long abi = syscall(SYS_landlock_create_ruleset, NULL, 0, 1u);
    return abi > 0 ? (int)abi : 0;
}

int vibe_sandbox_vsock_opens(void) {
    int fd = socket(VIBE_AF_VSOCK, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return 0;
    close(fd);
    return 1;
}

int vibe_sandbox_overlay_known(void) {
    int fd = open("/proc/filesystems", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    char text[8192];
    ssize_t got = read(fd, text, sizeof(text) - 1);
    close(fd);
    if (got <= 0) return 0;
    text[got] = '\0';
    return strstr(text, "\toverlay\n") != NULL;
}
#endif
