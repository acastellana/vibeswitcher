// The process facts the Mac's voice rule could read (the node on the Mac's design, step 4), printed as key=value lines.
// Built by scripts/mac-measure/lib.sh (clang, ad hoc), never installed. It reads, it never signals, and it takes no
// task port: the code-signing status word (csops), the kernel's BSD records (proc_pidinfo), KERN_PROCARGS2 and the
// responsible pid (the private responsibility_get_pid_responsible_for_pid, looked up with dlsym) and the coalitions
// (the private PROC_PIDCOALITIONINFO) are each a read the kernel answers without a debugger's rights.
//
//   facts                 this process's own facts
//   facts --pid PID [VAR] what this process can read of PID (VAR: an environment name to look for, default MEASURE_MARK)
//   facts --zombie        a child that exits, read while it is a zombie, then reaped
//   facts --sleep SECONDS sleeps (a target to read; the measurements start it with a marker in its environment)
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <unistd.h>

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

static void status_word(pid_t pid) {
    uint32_t flags = 0;
    if (csops(pid, 0 /* CS_OPS_STATUS */, &flags, sizeof flags) != 0) {
        printf("cs_status=unreadable errno=%d (%s)\n", errno, strerror(errno));
        return;
    }
    printf("cs_status=0x%08x valid=%d adhoc=%d get_task_allow=%d hard=%d kill=%d runtime=%d linker_signed=%d platform=%d debugged=%d\n",
           flags, !!(flags & 0x1), !!(flags & 0x2), !!(flags & 0x4), !!(flags & 0x100), !!(flags & 0x200),
           !!(flags & 0x10000), !!(flags & 0x20000), !!(flags & 0x4000000), !!(flags & 0x10000000));
}

static void responsible(pid_t pid) {
    pid_t (*get)(pid_t) = (pid_t (*)(pid_t))dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
    if (!get) { printf("responsible=no-symbol\n"); return; }
    printf("responsible=%d\n", get(pid));
}

// xnu's private PROC_PIDCOALITIONINFO (not in the SDK): the launchd coalitions (resource, jetsam) a process is in.
// A process inherits its parent's at fork and can't leave them; launchd puts each job it starts in a new one.
static void coalitions(pid_t pid) {
    uint64_t info[5] = {0};
    int got = proc_pidinfo(pid, 20 /* PROC_PIDCOALITIONINFO */, 0, info, sizeof info);
    if (got == (int)sizeof info) printf("coalition=read resource=%llu jetsam=%llu\n", info[0], info[1]);
    else printf("coalition=refused got=%d errno=%d (%s)\n", got, errno, strerror(errno));
}

static void bsd_records(pid_t pid) {
    struct proc_bsdinfo info;
    int got = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof info);
    if (got == (int)sizeof info) {
        const char *tty = info.e_tdev == (uint32_t)-1 || info.e_tdev == 0 ? NULL : devname(info.e_tdev, S_IFCHR);
        printf("bsdinfo=read ppid=%d pgid=%d uid=%d status=%u tty=%s start_us=%llu\n", info.pbi_ppid, info.pbi_pgid, info.pbi_uid,
               info.pbi_status, tty ? tty : "none", (unsigned long long)info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec);
    } else {
        printf("bsdinfo=refused got=%d errno=%d (%s)\n", got, errno, strerror(errno));
    }
    struct proc_bsdshortinfo short_info;
    got = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &short_info, sizeof short_info);
    if (got == (int)sizeof short_info) {
        printf("shortbsdinfo=read ppid=%d pgid=%d uid=%d status=%u\n", short_info.pbsi_ppid, short_info.pbsi_pgid, short_info.pbsi_uid,
               short_info.pbsi_status);
    } else {
        printf("shortbsdinfo=refused got=%d errno=%d (%s)\n", got, errno, strerror(errno));
    }
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    struct kinfo_proc kp;
    size_t size = sizeof kp;
    if (sysctl(mib, 4, &kp, &size, NULL, 0) == 0 && size == sizeof kp) {
        printf("kern_proc_pid=read ppid=%d tdev=%s\n", kp.kp_eproc.e_ppid,
               kp.kp_eproc.e_tdev == (dev_t)-1 ? "none" : (devname(kp.kp_eproc.e_tdev, S_IFCHR) ?: "?"));
    } else {
        printf("kern_proc_pid=refused errno=%d (%s) size=%zu\n", errno, strerror(errno), size);
    }
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, path, sizeof path) > 0) printf("pidpath=%s\n", path);
    else printf("pidpath=refused errno=%d (%s)\n", errno, strerror(errno));
}

// KERN_PROCARGS2: argc, the exec path, NUL padding, argv, then the environment.
static void procargs(pid_t pid, const char *want) {
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0) {
        printf("procargs=refused errno=%d (%s)\n", errno, strerror(errno));
        return;
    }
    char *buffer = malloc(size + 1);
    if (!buffer || sysctl(mib, 3, buffer, &size, NULL, 0) != 0) {
        printf("procargs=refused errno=%d (%s)\n", errno, strerror(errno));
        free(buffer);
        return;
    }
    buffer[size] = 0;
    int argc = 0;
    memcpy(&argc, buffer, sizeof argc);
    char *at = buffer + sizeof argc, *end = buffer + size;
    at += strnlen(at, end - at);
    while (at < end && *at == 0) at++;
    for (int i = 0; i < argc && at < end; i++) at += strnlen(at, end - at) + 1;
    int entries = 0, found = 0;
    size_t want_len = strlen(want);
    while (at < end && *at) {
        size_t len = strnlen(at, end - at);
        entries++;
        if (len > want_len && strncmp(at, want, want_len) == 0 && at[want_len] == '=') found = 1;
        at += len + 1;
    }
    printf("procargs=read bytes=%zu argc=%d environment_entries=%d %s_seen=%d\n", size, argc, entries, want, found);
    free(buffer);
}

static void about(pid_t pid, const char *want) {
    printf("pid=%d\n", pid);
    bsd_records(pid);
    coalitions(pid);
    procargs(pid, want);
    status_word(pid);
    responsible(pid);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc >= 3 && strcmp(argv[1], "--sleep") == 0) {
        sleep((unsigned)atoi(argv[2]));
        return 0;
    }
    if (argc >= 3 && strcmp(argv[1], "--pid") == 0) {
        about((pid_t)atoi(argv[2]), argc >= 4 ? argv[3] : "MEASURE_MARK");
        return 0;
    }
    if (argc >= 2 && strcmp(argv[1], "--zombie") == 0) {
        pid_t child = fork();
        if (child < 0) { perror("fork"); return 1; }
        if (child == 0) _exit(7);
        siginfo_t info;
        // Waits for the exit without reaping it: the child is a zombie from here until waitpid below.
        if (waitid(P_PID, (id_t)child, &info, WEXITED | WNOWAIT) != 0) { perror("waitid"); return 1; }
        printf("zombie: ");
        about(child, "MEASURE_MARK");
        int status = 0;
        waitpid(child, &status, 0);
        printf("reaped=%d exit=%d\n", child, WEXITSTATUS(status));
        return 0;
    }
    pid_t self = getpid();
    printf("self: pid=%d ppid=%d pgid=%d sid=%d uid=%d\n", self, getppid(), getpgrp(), getsid(0), getuid());
    int tty = open("/dev/tty", O_RDONLY | O_NOCTTY);
    printf("dev_tty=%s\n", tty >= 0 ? "opens" : "none");
    if (tty >= 0) close(tty);
    printf("VIBESWITCHER_SESSION=%s CLAUDECODE=%s\n", getenv("VIBESWITCHER_SESSION") ? "set" : "unset", getenv("CLAUDECODE") ? "set" : "unset");
    about(self, "MEASURE_MARK");
    return 0;
}
