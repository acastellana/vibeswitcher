// K-M1 of the keeper's design (docs/superpowers/specs/2026-11-27-v2-mac-keeper-design.md, "Measurements owed"): what a
// received pair end's LOCAL_PEERTOKEN names, asked in KP10's order (the maker makes a pair after its fork, sends one end
// over a connection by SCM_RIGHTS, acts, execs; the token is asked of the received end only then), and what Security
// says of it; (d) the names of a pair's ends and of a connection's; (e) the token and poll(2) once the other end is
// closed or shut; (f) a connection's token after a process holding a copy of the connecting socket writes last.
//
// This process plays the keeper: it listens on SOCKET_PATH and receives each trial's end. Every other process is its own
// child (or a child's child); each reports its own pid and pidversion (its own task's audit token, TASK_AUDIT_TOKEN: no
// other task's port is taken) over a pipe, so each token read is labelled by whose it is. A fresh maker and pair per
// trial, sequenced over pipes; the keeper reads or writes its end only where the trial says so. No dialog, no debugger,
// no root, nothing read of a process this one didn't start.
//
//   pair-token SOCKET_PATH PROGRAM [IMAGE [PLAIN BIG WINDOW]]   (PROGRAM: a hardened image taking --sleep SECONDS, the
//                                             maker's exec target; IMAGE: pair-image, the hardened image that acts, for
//                                             the second part; PLAIN, BIG, WINDOW: part three's other images)
//   pair-token --a-routes IMAGE PLAIN BIG WINDOW   part three alone (K-M16's here part and D1's timing)
//
// The second part, (g) to (o) (2026-11-27, the proof's redesign after K-M1 refuted the fixed token), is at the end of
// this file: the whole write-then-exec with every point a keeper could ask the token, a silent holder, a nonce round,
// a keeper-made end, which acts of a holder move the token, the token once the last to act exited, the end of file a
// first run saw, a Mach message's audit trailer, and SCM_CREDS.
//
// The third part (2026-11-27, the proof review of that day: I1, I2, D1), after the second: K-M16's here part, what a
// hardened child finds on itself when its parent named exception ports by every way a parent can, its rlimits, the
// window before its first statement, and Security's check timed against a large image. It receives no exception and
// takes no other task's port; the active routes are the keyboard trial's (K7).
#include <Security/Security.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

typedef struct { pid_t pid; int version; } who_t;

static const char *program, *image;
static char *program_real;  // PROGRAM's path with its links resolved (/tmp is /private/tmp), as proc_pidpath gives it
static struct sockaddr_un address = {.sun_family = AF_UNIX};
static int listener = -1;
static CFDataRef own_file_cdhash, program_cdhash, image_cdhash;

// Who the trial's processes are, for the labels.
static who_t keeper, maker, child, third, spawned;
static int have_child, have_third, have_spawned;
static const char *child_name = "the maker's forked child", *third_name = "the third process";

static void die(const char *what) { fprintf(stderr, "pair-token: %s: %s\n", what, strerror(errno)); exit(1); }

static who_t of(audit_token_t token) { return (who_t){(pid_t)token.val[5], (int)token.val[7]}; }

static who_t own(void) {
    audit_token_t token;
    mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
    if (task_info(mach_task_self(), TASK_AUDIT_TOKEN, (task_info_t)&token, &count) != KERN_SUCCESS) die("TASK_AUDIT_TOKEN");
    return of(token);
}

static void put(int fd, const void *bytes, size_t count) {
    if (write(fd, bytes, count) != (ssize_t)count) die("write to a pipe");
}

static void get(int fd, void *bytes, size_t count) {
    size_t got = 0;
    while (got < count) {
        ssize_t n = read(fd, (char *)bytes + got, count - got);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { fprintf(stderr, "pair-token: a pipe ended early\n"); exit(1); }
        got += (size_t)n;
    }
}

static void say(int fd) { put(fd, "g", 1); }
static void hear(int fd) { char byte; get(fd, &byte, 1); }
static void tell_who(int fd) { who_t me = own(); put(fd, &me, sizeof me); }
static who_t hear_who(int fd) { who_t them; get(fd, &them, sizeof them); return them; }

static int same(who_t a, who_t b) { return a.pid == b.pid && a.version == b.version; }

static const char *label(who_t w) {
    static char text[160];
    if (same(w, maker)) return "the maker, as it was before any exec";
    if (w.pid == maker.pid) return "the maker's pid, another pidversion (its image after the exec)";
    if (have_child && same(w, child)) return child_name;
    if (have_third && same(w, third)) return third_name;
    if (have_spawned && same(w, spawned)) return "the image the probe spawned";
    if (same(w, keeper)) return "this process (the keeper)";
    snprintf(text, sizeof text, "none of the trial's processes");
    return text;
}

static CFDataRef file_cdhash(const char *path) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    SecStaticCodeRef code = NULL;
    CFDictionaryRef info = NULL;
    CFDataRef cdhash = NULL;
    if (SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &code) == errSecSuccess &&
        SecCodeCopySigningInformation(code, kSecCSDefaultFlags, &info) == errSecSuccess) {
        CFDataRef found = CFDictionaryGetValue(info, kSecCodeInfoUnique);
        if (found) cdhash = CFDataCreateCopy(NULL, found);
    }
    if (info) CFRelease(info);
    if (code) CFRelease(code);
    CFRelease(url);
    return cdhash;
}

static void print_cdhash(CFDataRef cdhash) {
    if (!cdhash) { printf("none"); return; }
    for (CFIndex i = 0; i < CFDataGetLength(cdhash) && i < 8; i++) printf("%02x", CFDataGetBytePtr(cdhash)[i]);
}

// Security's answer for a token: the guest's status, then (found) its validity, cdhash, whose file it is, and whether
// the dynamic status word says valid, hardened, not debuggable (the node's isHardened).
static void security(audit_token_t token) {
    CFDataRef data = CFDataCreate(NULL, (const UInt8 *)&token, sizeof token);
    const void *keys[] = {kSecGuestAttributeAudit};
    const void *values[] = {data};
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SecCodeRef code = NULL;
    OSStatus status = SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &code);
    printf(" | Security: guest=%d", (int)status);
    if (status == errSecSuccess && code) {
        OSStatus valid = SecCodeCheckValidity(code, kSecCSDefaultFlags, NULL);
        CFDictionaryRef info = NULL;
        SecCodeCopySigningInformation((SecStaticCodeRef)code, kSecCSDynamicInformation, &info);
        CFDataRef cdhash = info ? CFDictionaryGetValue(info, kSecCodeInfoUnique) : NULL;
        CFNumberRef word = info ? CFDictionaryGetValue(info, kSecCodeInfoStatus) : NULL;
        uint32_t flags = 0;
        if (word) CFNumberGetValue(word, kCFNumberSInt32Type, &flags);
        printf(" valid=%d cdhash=", (int)valid);
        print_cdhash(cdhash);
        if (cdhash && own_file_cdhash && CFEqual(cdhash, own_file_cdhash)) printf(" (this probe's file)");
        else if (cdhash && program_cdhash && CFEqual(cdhash, program_cdhash)) printf(" (PROGRAM's file)");
        else if (cdhash && image_cdhash && CFEqual(cdhash, image_cdhash)) printf(" (IMAGE's file)");
        int hardened = (flags & 0x1) && (flags & 0x10000) && !(flags & (0x4 | 0x10000000));
        printf(" hardened=%s", word ? (hardened ? "yes" : "no") : "unread");
        if (info) CFRelease(info);
        CFRelease(code);
    }
    CFRelease(attributes);
    CFRelease(data);
}

// The token of `fd`'s peer, asked now (a fresh getsockopt each time), labelled, with Security's answer; returns whose
// it is (pid 0 when refused).
static who_t token_who(const char *when, int fd) {
    audit_token_t token;
    socklen_t size = sizeof token;
    printf("  %s: LOCAL_PEERTOKEN ", when);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) != 0) {
        printf("refused errno=%d (%s)\n", errno, strerror(errno));
        return (who_t){0, 0};
    }
    who_t w = of(token);
    printf("pid=%d pidversion=%d = %s", w.pid, w.version, label(w));
    pid_t peer = 0;
    size = sizeof peer;
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &size) == 0) printf(" | LOCAL_PEERPID=%d", peer);
    else printf(" | LOCAL_PEERPID refused errno=%d", errno);
    security(token);
    printf("\n");
    return w;
}

static void token(const char *when, int fd) { (void)token_who(when, fd); }

static void who_line(void) {
    printf("  keeper pid=%d pidversion=%d; maker pid=%d pidversion=%d", keeper.pid, keeper.version, maker.pid, maker.version);
    if (have_child) printf("; forked child pid=%d pidversion=%d", child.pid, child.version);
    if (have_third) printf("; third pid=%d pidversion=%d", third.pid, third.version);
    printf("\n");
}

static void send_fd(int socket, const char *bytes, size_t count, int fd) {
    struct iovec io = {.iov_base = (void *)bytes, .iov_len = count};
    char control[CMSG_SPACE(sizeof(int))];
    memset(control, 0, sizeof control);
    struct msghdr message = {.msg_iov = &io, .msg_iovlen = 1, .msg_control = control, .msg_controllen = sizeof control};
    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(header), &fd, sizeof fd);
    if (sendmsg(socket, &message, 0) != (ssize_t)count) die("sendmsg");
}

static int receive_fd(int socket) {
    char bytes[64];
    struct iovec io = {.iov_base = bytes, .iov_len = sizeof bytes};
    char control[CMSG_SPACE(sizeof(int))];
    struct msghdr message = {.msg_iov = &io, .msg_iovlen = 1, .msg_control = control, .msg_controllen = sizeof control};
    ssize_t got = recvmsg(socket, &message, 0);
    if (got <= 0) die("recvmsg");
    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    if (!header || header->cmsg_type != SCM_RIGHTS) { fprintf(stderr, "pair-token: no descriptor\n"); exit(1); }
    int fd;
    memcpy(&fd, CMSG_DATA(header), sizeof fd);
    return fd;
}

static int connect_to_keeper(void) {
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    if (s < 0 || connect(s, (struct sockaddr *)&address, sizeof address) != 0) die("connect");
    return s;
}

// The maker's first steps: a pair made after its fork, one end sent with the hello over a connection; once the
// keeper says it has the end (`received`), the sent end and the connection closed. Returns the maker's own end.
// (Closing them while the end was still in flight, before the keeper's recvmsg, lost the pair's buffered bytes in a
// first run of this probe: the keeper read end of file, not the request. Not measured further.)
static int make_and_send(int received) {
    int connection = connect_to_keeper();
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) die("socketpair");
    send_fd(connection, "vibeswitcher-keeper-v1\n", 23, pair[1]);
    hear(received);
    close(pair[1]);
    close(connection);
    return pair[0];
}

// The keeper's receipt: the connection accepted, its one message's end taken, the connection closed.
static int receive_end(void) {
    int connection = accept(listener, NULL, NULL);
    if (connection < 0) die("accept");
    int end = receive_fd(connection);
    close(connection);
    return end;
}

static void exec_program(void) {
    execl(program, program, "--sleep", "30", (char *)NULL);
    _exit(127);
}

// Waits for the maker's exec: its close-on-exec pipe end reaches end of file (nothing else holds it), then says what
// the maker now runs.
static void await_exec(int exec_read) {
    char byte;
    while (read(exec_read, &byte, 1) != 0) {
        if (errno != EINTR) break;
    }
    char path[PROC_PIDPATHINFO_MAXSIZE] = "";
    proc_pidpath(maker.pid, path, sizeof path);
    int is_program = strcmp(path, program) == 0 || (program_real && strcmp(path, program_real) == 0);
    printf("  the maker exec'd: it now runs %s\n", is_program ? "PROGRAM" : path);
}

static void end_maker(void) {
    kill(maker.pid, SIGTERM);
    waitpid(maker.pid, NULL, 0);
}

static int closed_on_exec_pipe(int ends[2]) {
    if (pipe(ends) != 0) die("pipe");
    fcntl(ends[1], F_SETFD, FD_CLOEXEC);
    return 0;
}

// --- (a) to (c), and the controls: the token of the received end, asked after the maker's exec ---------------------
enum kind { LIVE, ASKED_BEFORE, A_WRITES, A_WRITES_READS, B_KEEPER, C_THIRD };

static void trial(enum kind kind, const char *title) {
    printf("== %s\n", title);
    int to_maker[2], from_maker[2], to_child[2], from_child[2], exec_pipe[2], side[2];
    if (pipe(to_maker) || pipe(from_maker) || pipe(to_child) || pipe(from_child)) die("pipe");
    closed_on_exec_pipe(exec_pipe);
    if (kind == C_THIRD && socketpair(AF_UNIX, SOCK_STREAM, 0, side) != 0) die("socketpair (side)");
    have_child = kind == A_WRITES || kind == A_WRITES_READS;
    have_third = kind == C_THIRD;
    pid_t m = fork();
    if (m == 0) {
        close(to_maker[1]); close(from_maker[0]); close(exec_pipe[0]);
        if (kind == C_THIRD) close(side[1]);
        tell_who(from_maker[1]);
        int end = make_and_send(to_maker[0]);
        if (have_child) {
            pid_t c = fork();
            if (c == 0) {
                // The forked child: holds a copy of the maker's end; on the word, writes (and reads) on it.
                close(exec_pipe[1]); close(to_child[1]); close(from_child[0]);
                tell_who(from_child[1]);
                hear(to_child[0]);
                if (write(end, "a", 1) != 1) die("the child's write");
                if (kind == A_WRITES_READS) { char byte; if (read(end, &byte, 1) != 1) die("the child's read"); }
                say(from_child[1]);
                hear(to_child[0]);
                _exit(0);
            }
        }
        if (kind == B_KEEPER || kind == C_THIRD || kind == ASKED_BEFORE) {
            if (write(end, "req", 3) != 3) die("the maker's request");
        }
        if (kind == C_THIRD) { send_fd(side[0], "t", 1, end); close(side[0]); }
        say(from_maker[1]);
        hear(to_maker[0]);
        if (kind == LIVE) { hear(to_maker[0]); _exit(0); }
        exec_program();
    }
    maker = (who_t){m, 0};
    close(to_maker[0]); close(from_maker[1]); close(exec_pipe[1]);
    pid_t t = -1;
    if (kind == C_THIRD) {
        t = fork();
        if (t == 0) {
            // The third process: given a copy of the maker's end by the maker; on the word, reads the answer on it.
            close(side[0]); close(to_child[1]); close(from_child[0]);
            tell_who(from_child[1]);
            int copy = receive_fd(side[1]);
            hear(to_child[0]);
            char bytes[3];
            if (read(copy, bytes, 3) != 3) die("the third's read");
            say(from_child[1]);
            hear(to_child[0]);
            _exit(0);
        }
        close(side[0]); close(side[1]);
    }
    close(to_child[0]); close(from_child[1]);
    maker = hear_who(from_maker[0]);
    keeper = own();
    int end = receive_end();
    say(to_maker[1]);
    if (have_child || have_third) {
        who_t w = hear_who(from_child[0]);
        if (have_child) child = w; else third = w;
    }
    hear(from_maker[0]);
    who_line();
    if (kind == LIVE) {
        token("the maker alive, not exec'd, nothing written", end);
        say(to_maker[1]); say(to_maker[1]);
        waitpid(m, NULL, 0);
        close(end);
        return;
    }
    audit_token_t kept;
    socklen_t kept_size = sizeof kept;
    int have_kept = 0;
    if (kind == ASKED_BEFORE) {
        token("asked at the receipt, before the exec (this control only)", end);
        // The token taken at the receipt, kept to ask Security again after the exec (as M7 asks for a connection's).
        have_kept = getsockopt(end, SOL_LOCAL, LOCAL_PEERTOKEN, &kept, &kept_size) == 0;
    }
    if (kind == A_WRITES_READS) {
        if (write(end, "k", 1) != 1) die("the keeper's write");
        printf("  the keeper wrote 1 byte on its end (for the child to read), before the child acted\n");
    }
    if (have_child) {
        say(to_child[1]);
        hear(from_child[0]);
        printf("  the forked child wrote 1 byte on the maker's end%s\n", kind == A_WRITES_READS ? " and read 1" : "");
    }
    say(to_maker[1]);
    await_exec(exec_pipe[0]);
    token("after the exec", end);
    if (have_kept) {
        who_t w = of(kept);
        printf("  the token kept from the receipt, asked of Security again after the exec: pid=%d pidversion=%d = %s", w.pid, w.version, label(w));
        security(kept);
        printf("\n");
    }
    if (kind == B_KEEPER || kind == C_THIRD || kind == ASKED_BEFORE) {
        char bytes[3];
        ssize_t got = read(end, bytes, 3);
        if (got != 3) { fprintf(stderr, "pair-token: the keeper's read of the request gave %zd (errno %d)\n", got, errno); exit(1); }
        if (write(end, "ans", 3) != 3) die("the keeper's write");
        printf("  the keeper read the 3-byte request and wrote a 3-byte answer on its end\n");
        token("after the keeper's read and write", end);
    }
    if (have_third) {
        say(to_child[1]);
        hear(from_child[0]);
        printf("  the third process read the answer on its copy of the maker's end\n");
        token("after the third's read", end);
        say(to_child[1]);
        waitpid(t, NULL, 0);
    }
    if (have_child) say(to_child[1]);
    end_maker();
    close(end);
    close(to_maker[1]); close(from_maker[0]); close(exec_pipe[0]); close(to_child[1]); close(from_child[0]);
    have_child = have_third = 0;
}

// --- (d) names --------------------------------------------------------------------------------------------------------
static void name_of(const char *which, int r, struct sockaddr_un *a, socklen_t n) {
    if (r != 0) { printf(" %s refused errno=%d (%s)", which, errno, strerror(errno)); return; }
    socklen_t header = (socklen_t)offsetof(struct sockaddr_un, sun_path);
    char path[sizeof a->sun_path + 1] = "";
    if (n > header) { size_t k = n - header; if (k > sizeof a->sun_path) k = sizeof a->sun_path; memcpy(path, a->sun_path, k); path[k] = 0; }
    printf(" %s len=%u family=%d path=\"%s\"", which, (unsigned)n, n >= header ? a->sun_family : -1, path);
}

static void names(const char *what, int fd) {
    struct sockaddr_un a;
    memset(&a, 0, sizeof a);
    socklen_t n = sizeof a;
    printf("  %s:", what);
    int r = getsockname(fd, (struct sockaddr *)&a, &n);
    name_of("getsockname", r, &a, n);
    memset(&a, 0, sizeof a);
    n = sizeof a;
    r = getpeername(fd, (struct sockaddr *)&a, &n);
    name_of("getpeername", r, &a, n);
    printf("\n");
}

static int bound_listener(const char *path) {
    struct sockaddr_un at = {.sun_family = AF_UNIX};
    strcpy(at.sun_path, path);
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    unlink(path);
    if (bind(s, (struct sockaddr *)&at, sizeof at) != 0 || listen(s, 4) != 0) die("bind/listen (d)");
    return s;
}

static int connect_path(const char *path) {
    struct sockaddr_un at = {.sun_family = AF_UNIX};
    strcpy(at.sun_path, path);
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    if (connect(s, (struct sockaddr *)&at, sizeof at) != 0) die("connect (d)");
    return s;
}

static void attempt(const char *what, int r) {
    if (r == 0) printf("  %s: succeeded\n", what);
    else printf("  %s: refused errno=%d (%s)\n", what, errno, strerror(errno));
}

static void trial_d(const char *folder) {
    printf("== (d) the names of a pair's ends and of a connection's\n");
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) die("socketpair");
    names("socketpair, end 0", pair[0]);
    names("socketpair, end 1", pair[1]);
    // An end sent to another process and back, by SCM_RIGHTS: still the pair's.
    int carrier[2];
    socketpair(AF_UNIX, SOCK_STREAM, 0, carrier);
    send_fd(carrier[0], "x", 1, pair[1]);
    int carried = receive_fd(carrier[1]);
    names("socketpair, end 1 received by SCM_RIGHTS", carried);
    close(carried); close(carrier[0]); close(carrier[1]); close(pair[0]); close(pair[1]);

    char path[200], moved[200];
    snprintf(path, sizeof path, "%s/d.sock", folder);
    snprintf(moved, sizeof moved, "%s/d-renamed.sock", folder);
    int l = bound_listener(path);
    int client = connect_path(path);
    int accepted = accept(l, NULL, NULL);
    names("connect: the connecting end", client);
    names("connect: the accepted end", accepted);
    unlink(path);
    printf("  (the listener's path unlinked)\n");
    names("connect: the connecting end", client);
    names("connect: the accepted end", accepted);
    close(l);
    printf("  (the listener closed)\n");
    names("connect: the accepted end", accepted);
    close(client); close(accepted);

    l = bound_listener(path);
    rename(path, moved);
    printf("  (a listener's path renamed before a connect through the new name)\n");
    client = connect_path(moved);
    accepted = accept(l, NULL, NULL);
    names("connect via the new name: the connecting end", client);
    names("connect via the new name: the accepted end", accepted);
    close(client); close(accepted); close(l); unlink(moved);

    printf("  other ways tried to make two connected stream ends unnamed on both sides:\n");
    struct sockaddr_un empty = {.sun_family = AF_UNIX};
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    attempt("bind to an empty path (sun_path \"\", full length)", bind(s, (struct sockaddr *)&empty, sizeof empty));
    close(s);
    s = socket(AF_UNIX, SOCK_STREAM, 0);
    attempt("bind with no path (the length of the family alone)", bind(s, (struct sockaddr *)&empty, (socklen_t)offsetof(struct sockaddr_un, sun_path)));
    close(s);
    s = socket(AF_UNIX, SOCK_STREAM, 0);
    attempt("listen on a socket never bound", listen(s, 4));
    names("that socket", s);
    int c = socket(AF_UNIX, SOCK_STREAM, 0);
    attempt("connect to an empty path", connect(c, (struct sockaddr *)&empty, sizeof empty));
    close(c);
    c = socket(AF_UNIX, SOCK_STREAM, 0);
    attempt("connect with no path (the length of the family alone)", connect(c, (struct sockaddr *)&empty, (socklen_t)offsetof(struct sockaddr_un, sun_path)));
    close(c); close(s);
    c = socket(AF_UNIX, SOCK_STREAM, 0);
    attempt("connect to a path where nothing is bound", connect(c, (struct sockaddr *)&(struct sockaddr_un){.sun_family = AF_UNIX, .sun_path = "/nonexistent-k-m1.sock"}, sizeof(struct sockaddr_un)));
    close(c);
}

// --- (e) the received end's token and poll(2) after the other end is closed or shut --------------------------------
enum shut { OPEN, CLOSED, SHUT_WRITE, SHUT_READ_FORMER };

static void poll_line(int fd) {
    struct pollfd p = {.fd = fd, .events = POLLIN | POLLOUT | POLLPRI};
    int r = poll(&p, 1, 0);
    printf("  poll (POLLIN|POLLOUT|POLLPRI asked, no wait): %d revents=0x%x%s%s%s%s%s%s\n", r, p.revents,
           p.revents & POLLIN ? " POLLIN" : "", p.revents & POLLPRI ? " POLLPRI" : "", p.revents & POLLOUT ? " POLLOUT" : "",
           p.revents & POLLHUP ? " POLLHUP" : "",
           p.revents & POLLERR ? " POLLERR" : "", p.revents & POLLNVAL ? " POLLNVAL" : "");
    char byte;
    ssize_t n = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT);
    if (n < 0) printf("  recv(MSG_PEEK|MSG_DONTWAIT): -1 errno=%d (%s)\n", errno, strerror(errno));
    else printf("  recv(MSG_PEEK|MSG_DONTWAIT): %zd\n", n);
}

static void trial_e(enum shut shut, const char *title) {
    printf("== %s\n", title);
    int to_maker[2], from_maker[2], from_child[2];
    if (pipe(to_maker) || pipe(from_maker) || pipe(from_child)) die("pipe");
    have_child = shut == SHUT_READ_FORMER;
    pid_t m = fork();
    if (m == 0) {
        close(to_maker[1]); close(from_maker[0]); close(from_child[0]);
        tell_who(from_maker[1]);
        int end = make_and_send(to_maker[0]);
        if (shut == SHUT_READ_FORMER) {
            pid_t c = fork();
            if (c == 0) {
                // A former holder: shuts its copy for reading, closes it, says so and ends.
                tell_who(from_child[1]);
                if (shutdown(end, SHUT_RD) != 0) die("shutdown SHUT_RD");
                close(end);
                say(from_child[1]);
                _exit(0);
            }
            waitpid(c, NULL, 0);
        }
        if (shut == CLOSED) close(end);
        if (shut == SHUT_WRITE && shutdown(end, SHUT_WR) != 0) die("shutdown SHUT_WR");
        say(from_maker[1]);
        hear(to_maker[0]);
        _exit(0);
    }
    close(to_maker[0]); close(from_maker[1]); close(from_child[1]);
    maker = hear_who(from_maker[0]);
    keeper = own();
    int end = receive_end();
    say(to_maker[1]);
    if (have_child) { child = hear_who(from_child[0]); hear(from_child[0]); }
    hear(from_maker[0]);
    who_line();
    const char *state = shut == OPEN ? "the maker's end open, untouched (the baseline)"
        : shut == CLOSED ? "after the maker's close of its end (its only holder; the maker alive)"
        : shut == SHUT_WRITE ? "after the maker's shutdown(SHUT_WR), its end kept open"
        : "after a former holder's shutdown(SHUT_RD) and close (the maker's forked child, ended; the maker's end open)";
    token(state, end);
    poll_line(end);
    say(to_maker[1]);
    waitpid(m, NULL, 0);
    printf("  (the maker ended)\n");
    token("after the maker ended too", end);
    poll_line(end);
    close(end);
    close(to_maker[1]); close(from_maker[0]); close(from_child[0]);
    have_child = 0;
}

// --- (f) a connection's token after a process holding a copy of the connecting socket writes last -----------------
static void trial_f(int maker_last, const char *title) {
    printf("== %s\n", title);
    int to_maker[2], from_maker[2], to_child[2], from_child[2];
    if (pipe(to_maker) || pipe(from_maker) || pipe(to_child) || pipe(from_child)) die("pipe");
    have_child = 1;
    pid_t m = fork();
    if (m == 0) {
        close(to_maker[1]); close(from_maker[0]); close(to_child[1]); close(from_child[0]);
        tell_who(from_maker[1]);
        int connection = connect_to_keeper();
        if (write(connection, "m", 1) != 1) die("the connector's write");
        pid_t c = fork();
        if (c == 0) {
            tell_who(from_child[1]);
            if (write(connection, "f", 1) != 1) die("the child's write");
            say(from_child[1]);
            hear(to_child[0]);
            _exit(0);
        }
        hear(to_maker[0]);
        if (maker_last && write(connection, "M", 1) != 1) die("the connector's second write");
        say(from_maker[1]);
        hear(to_maker[0]);
        _exit(0);
    }
    close(to_maker[0]); close(from_maker[1]); close(to_child[0]); close(from_child[1]);
    maker = hear_who(from_maker[0]);
    keeper = own();
    child = hear_who(from_child[0]);
    hear(from_child[0]);
    say(to_maker[1]);
    hear(from_maker[0]);
    printf("  the connector wrote 1 byte, then its forked child (holding a copy of the connecting socket) wrote 1%s\n",
           maker_last ? ", then the connector wrote 1 more" : "");
    who_line();
    int connection = accept(listener, NULL, NULL);
    if (connection < 0) die("accept");
    token("at the accept, nothing read", connection);
    char bytes[3];
    ssize_t n = read(connection, bytes, maker_last ? 3 : 2);
    printf("  the keeper read %zd bytes: %.*s\n", n, (int)(n > 0 ? n : 0), bytes);
    token("after the keeper's read", connection);
    say(to_child[1]);
    say(to_maker[1]);
    waitpid(m, NULL, 0);
    close(connection);
    close(to_maker[1]); close(from_maker[0]); close(to_child[1]); close(from_child[0]);
    have_child = 0;
}

// ======================================================================================================================
// K-M1's second part (2026-11-27, the proof's redesign): (g) to (o). The first part above is unchanged, so its row still
// reproduces. IMAGE is pair-image (probes/pair-image.c): a hardened image with its own cdhash that, on the probe's word,
// does on its descriptors what the host does in some mode (a line on descriptor 2, a read of descriptor 0, an answer on
// a descriptor it was named, a descriptor taken and read). Every step is sequenced over pipes; nothing waits on a clock
// but the bounded waits named in the lines (a read with a limit, the token asked again for at most 1 s).
// ======================================================================================================================

static const char *how(char status, char err) {
    static char text[96];
    if (status == 'o') return "done";
    if (status == 'b') return "entered";
    snprintf(text, sizeof text, "failed errno=%d (%s)", err, strerror(err));
    return text;
}

// One step asked of a process over its pipes, its result printed.
static void step(const char *who, int to, int from, char code, const char *what) {
    put(to, &code, 1);
    char r[2];
    get(from, r, 2);
    printf("  %s %s: %s\n", who, what, how(r[0], r[1]));
}

// A holder: its copy of an end (`end`), steps read on `in`, each result (status, errno) on `out`. `give`: a socket to
// pass a taken descriptor over ('G').
static void holder_loop(int end, int in, int out, int give) {
    char code;
    int taken = -1;
    while (read(in, &code, 1) == 1) {
        int ok = 1;
        char bytes[1024];
        memset(bytes, 'x', sizeof bytes);
        switch (code) {
        case 'w': ok = write(end, "x", 1) == 1; break;                               // a 1-byte write
        case 'v': ok = write(end, "req", 3) == 3; break;                             // a request
        case 'W': ok = send(end, bytes, 0, 0) == 0; break;                           // a zero-length send
        case 'n': ok = recv(end, bytes, 1, MSG_DONTWAIT) >= 0; break;                // a read that doesn't wait
        case 'p': ok = recv(end, bytes, 1, MSG_PEEK | MSG_DONTWAIT) >= 0; break;     // a peek that doesn't wait
        case 'P': { struct pollfd p = {.fd = end, .events = POLLIN | POLLOUT}; ok = poll(&p, 1, 0) >= 0; break; }
        case 'g': { int type; socklen_t n = sizeof type; ok = getsockopt(end, SOL_SOCKET, SO_TYPE, &type, &n) == 0; break; }
        case 's': { struct timeval t = {.tv_sec = 2}; ok = setsockopt(end, SOL_SOCKET, SO_RCVTIMEO, &t, sizeof t) == 0; break; }
        case 'm': { struct sockaddr_un a; socklen_t n = sizeof a; ok = getpeername(end, (struct sockaddr *)&a, &n) == 0; break; }
        case 'i': { int n; ok = ioctl(end, FIONREAD, &n) == 0; break; }
        case 'f': { struct stat st; ok = fstat(end, &st) == 0; break; }
        case 'd': { int copy = dup(end); ok = copy >= 0 && close(copy) == 0; break; }
        case 'S': ok = shutdown(end, SHUT_WR) == 0; break;
        case 'R': ok = shutdown(end, SHUT_RD) == 0; break;
        case 'r': {                                                                   // a read that waits
            char entered[2] = {'b', 0};
            put(out, entered, 2);
            ok = read(end, bytes, 1) >= 0;
            break;
        }
        case 'a': {                                                                   // an answer: 8 bytes back
            struct timeval t = {.tv_sec = 2};
            setsockopt(end, SOL_SOCKET, SO_RCVTIMEO, &t, sizeof t);
            size_t got = 0;
            while (got < 8) { ssize_t n = read(end, bytes + got, 8 - got); if (n <= 0) break; got += (size_t)n; }
            ok = got == 8 && write(end, bytes, 8) == 8;
            break;
        }
        case 'A': {                                                                   // the keeper's 3-byte reply
            struct timeval t = {.tv_sec = 2};
            setsockopt(end, SOL_SOCKET, SO_RCVTIMEO, &t, sizeof t);
            size_t got = 0;
            while (got < 3) { ssize_t n = read(end, bytes + got, 3 - got); if (n <= 0) break; got += (size_t)n; }
            ok = got == 3;
            break;
        }
        case 'k': {                                                                   // a descriptor taken, a request on it
            taken = receive_fd(end);
            ok = taken >= 0 && write(taken, "req", 3) == 3;
            break;
        }
        case 'G': ok = taken >= 0 && give >= 0; if (ok) send_fd(give, "f", 1, taken); break;
        case 'q': _exit(0);
        default: errno = EINVAL; ok = 0;
        }
        char r[2] = {ok ? 'o' : 'e', (char)(ok ? 0 : errno)};
        put(out, r, 2);
    }
    _exit(0);
}

// Moves `fd` above the low numbers, so a dup2 onto 0 to 6 never overwrites another descriptor still needed.
static int high(int fd) { int moved = fcntl(fd, F_DUPFD, 30); close(fd); return moved; }

// --- the scenes: a maker (attacker code) that makes a pair and sends one end as K-M1's makers do, a silent holder S
// forked from it with a copy of the maker's end, and the maker's exec of PROGRAM (silent) or IMAGE (talking) ---------
typedef struct { pid_t m, s; int to_m, from_m, to_s, from_s, to_i, from_i, exec_read, end; } scene_t;

static scene_t scene_start(int with_give) {
    int mo[2], mr[2], so[2], sr[2], io[2], ir[2], ex[2], q[2] = {-1, -1};
    if (pipe(mo) || pipe(mr) || pipe(so) || pipe(sr) || pipe(io) || pipe(ir)) die("pipe");
    closed_on_exec_pipe(ex);
    pid_t m = fork();
    if (m == 0) {
        close(mo[1]); close(mr[0]); close(so[1]); close(sr[0]); close(io[1]); close(ir[0]); close(ex[0]);
        tell_who(mr[1]);
        int end = make_and_send(mo[0]);
        if (with_give && socketpair(AF_UNIX, SOCK_STREAM, 0, q) != 0) die("socketpair (give)");
        pid_t s = fork();
        if (s == 0) {
            close(mo[0]); close(mr[1]); close(io[0]); close(ir[1]); close(ex[1]);
            if (q[0] >= 0) close(q[0]);
            tell_who(sr[1]);
            holder_loop(end, so[0], sr[1], q[1]);
        }
        close(so[0]); close(sr[1]);
        if (q[1] >= 0) close(q[1]);
        char code;
        while (read(mo[0], &code, 1) == 1) {
            int ok = 1;
            char bytes[8];
            if (code == 'v') ok = write(end, "req", 3) == 3;
            else if (code == 'a') {
                size_t got = 0;
                while (got < 8) { ssize_t n = read(end, bytes + got, 8 - got); if (n <= 0) break; got += (size_t)n; }
                ok = got == 8 && write(end, bytes, 8) == 8;
            } else if (code == 'X') {
                execl(program, program, "--sleep", "30", (char *)NULL);
                _exit(127);
            } else if (code == 'x') {
                // IMAGE with the maker's end as its descriptors 0, 2 and 5, its steps on 3 and 4, the give socket on 6.
                int e = high(end), i = high(io[0]), r = high(ir[1]), g = q[0] >= 0 ? high(q[0]) : -1;
                dup2(e, 0); dup2(e, 2); dup2(e, 5); dup2(i, 3); dup2(r, 4);
                if (g >= 0) dup2(g, 6);
                close(e); close(i); close(r);
                if (g >= 0) close(g);
                execl(image, image, "act", (char *)NULL);
                _exit(127);
            } else if (code == 'q') _exit(0);
            char res[2] = {ok ? 'o' : 'e', (char)(ok ? 0 : errno)};
            put(mr[1], res, 2);
        }
        _exit(0);
    }
    close(mo[0]); close(mr[1]); close(so[0]); close(sr[1]); close(io[0]); close(ir[1]); close(ex[1]);
    scene_t c = {.m = m, .to_m = mo[1], .from_m = mr[0], .to_s = so[1], .from_s = sr[0], .to_i = io[1], .from_i = ir[0], .exec_read = ex[0]};
    maker = hear_who(mr[0]);
    keeper = own();
    c.end = receive_end();
    say(mo[1]);
    third = hear_who(sr[0]);
    have_third = 1;
    third_name = "S, the maker's forked holder (silent until told)";
    who_line();
    return c;
}

static void scene_exec(scene_t *c, char code) {
    put(c->to_m, &code, 1);
    await_exec(c->exec_read);
}

static void scene_end(scene_t *c) {
    kill(c->m, SIGTERM);
    waitpid(c->m, NULL, 0);
    char q = 'q';
    put(c->to_s, &q, 1);
    while (waitpid(-1, NULL, WNOHANG) > 0) {}
    close(c->to_m); close(c->from_m); close(c->to_s); close(c->from_s); close(c->to_i); close(c->from_i); close(c->exec_read);
    close(c->end);
    have_third = 0;
    third_name = "the third process";
}

// The keeper's reads and writes on its end, each said.
static void keeper_reads_request(int end) {
    struct pollfd p = {.fd = end, .events = POLLIN};
    char bytes[3];
    if (poll(&p, 1, 2000) != 1) { printf("  the keeper's read of the request: nothing within 2 s\n"); return; }
    ssize_t n = read(end, bytes, 3);
    if (n <= 0) printf("  the keeper's read of the request: %s\n", n == 0 ? "end of file" : strerror(errno));
    else printf("  the keeper read %zd bytes: %.*s\n", n, (int)n, bytes);
}

static void keeper_pending(int end, const char *when) {
    int n = 0;
    ioctl(end, FIONREAD, &n);
    printf("  bytes waiting on the keeper's end %s: %d\n", when, n);
}

static unsigned char nonce[8];

static void keeper_sends_nonce(int end) {
    arc4random_buf(nonce, sizeof nonce);
    if (write(end, nonce, 8) != 8) die("the nonce");
    printf("  the keeper wrote an 8-byte nonce on its end\n");
}

static void keeper_reads_answer(int end) {
    unsigned char bytes[8];
    size_t got = 0;
    while (got < 8) {
        struct pollfd p = {.fd = end, .events = POLLIN};
        if (poll(&p, 1, 1000) != 1) break;
        ssize_t n = read(end, bytes + got, 8 - got);
        if (n <= 0) break;
        got += (size_t)n;
    }
    if (got == 8) printf("  the keeper read the answer: %s\n", memcmp(bytes, nonce, 8) == 0 ? "the nonce, as sent" : "8 bytes, not the nonce");
    else printf("  the keeper read %zu of the answer's 8 bytes within 1 s\n", got);
}

static void compare(const char *what, who_t first, who_t now) {
    printf("  %s against the first read after the exec: %s\n", what,
           first.pid && same(first, now) ? "the same pid and pidversion" : "not the same");
}

static void trial_g(void) {
    printf("== (g1) the whole write-then-exec, the silent image: the maker writes the request and execs PROGRAM; every point a keeper could ask the token\n");
    scene_t c = scene_start(0);
    token("at the receipt, before any request", c.end);
    step("the maker", c.to_m, c.from_m, 'v', "writes the request on its end");
    scene_exec(&c, 'X');
    who_t first = token_who("after the exec, before the keeper reads the request", c.end);
    keeper_reads_request(c.end);
    keeper_pending(c.end, "after the request");
    token("after the keeper read the request", c.end);
    if (write(c.end, "ans", 3) != 3) die("the reply");
    printf("  the keeper wrote its 3-byte reply\n");
    token("after the keeper's reply", c.end);
    keeper_sends_nonce(c.end);
    keeper_reads_answer(c.end);
    who_t last = token_who("after a second round (a nonce) that nothing answered", c.end);
    compare("the last read", first, last);
    scene_end(&c);

    printf("== (g2) the same, the nonce sent once the token names PROGRAM (before any reply); S, silent until now, answers it\n");
    c = scene_start(0);
    step("the maker", c.to_m, c.from_m, 'v', "writes the request on its end");
    scene_exec(&c, 'X');
    first = token_who("after the exec", c.end);
    keeper_reads_request(c.end);
    keeper_sends_nonce(c.end);
    step("S", c.to_s, c.from_s, 'a', "reads the nonce on its copy and writes it back");
    keeper_reads_answer(c.end);
    last = token_who("after the answer", c.end);
    compare("this read", first, last);
    scene_end(&c);

    const char *titles[] = {
        "== (g3) as (g2), IMAGE the exec'd image (the maker's end its descriptors 0, 2, 5); after S's answer IMAGE writes a line on its descriptor 2",
        "== (g4) as (g3), but S shuts the end's write side after its answer, then IMAGE writes its line on descriptor 2 (SIGPIPE ignored, as the maker left it)",
        "== (g5) as (g3), but after S's answer IMAGE reads its descriptor 0 once, without waiting (nothing there)",
    };
    for (int k = 0; k < 3; k++) {
        printf("%s\n", titles[k]);
        c = scene_start(0);
        step("the maker", c.to_m, c.from_m, 'v', "writes the request on its end");
        scene_exec(&c, 'x');
        first = token_who("after the exec", c.end);
        keeper_reads_request(c.end);
        keeper_sends_nonce(c.end);
        step("S", c.to_s, c.from_s, 'a', "reads the nonce on its copy and writes it back");
        keeper_reads_answer(c.end);
        token("after the answer", c.end);
        if (k == 1) step("S", c.to_s, c.from_s, 'S', "shuts the end's write side (shutdown SHUT_WR)");
        if (k < 2) step("IMAGE", c.to_i, c.from_i, 'e', "writes a line on its descriptor 2");
        else step("IMAGE", c.to_i, c.from_i, '0', "reads its descriptor 0 once, not waiting");
        last = token_who("after IMAGE's step", c.end);
        compare("this read", first, last);
        keeper_pending(c.end, "after IMAGE's step");
        if (k == 1) {
            char byte;
            ssize_t n = recv(c.end, &byte, 1, MSG_DONTWAIT);
            printf("  the keeper's next read: %s\n", n == 0 ? "end of file" : n > 0 ? "a byte" : strerror(errno));
        }
        scene_end(&c);
    }
}

static void trial_h(void) {
    printf("== (h) S holds a copy and stays silent while the genuine image (IMAGE) talks: its own request, its answer to the nonce; then the keeper's reply\n");
    scene_t c = scene_start(0);
    scene_exec(&c, 'x');
    token("after the exec, before IMAGE writes", c.end);
    step("IMAGE", c.to_i, c.from_i, 'r', "writes its request on descriptor 5");
    who_t first = token_who("after IMAGE's request", c.end);
    keeper_reads_request(c.end);
    keeper_sends_nonce(c.end);
    step("IMAGE", c.to_i, c.from_i, 'a', "reads the nonce on descriptor 5 and writes it back");
    keeper_reads_answer(c.end);
    who_t answered = token_who("after IMAGE's answer", c.end);
    compare("this read", first, answered);
    if (write(c.end, "ans", 3) != 3) die("the reply");
    printf("  the keeper wrote its 3-byte reply\n");
    step("S", c.to_s, c.from_s, 'A', "reads the keeper's reply on its copy");
    token("after S took the reply", c.end);
    scene_end(&c);
}

static void trial_i(void) {
    printf("== (i) a nonce sent before the token names a pinned image: the maker (not exec'd) writes the request, answers the nonce, then execs PROGRAM\n");
    scene_t c = scene_start(0);
    step("the maker", c.to_m, c.from_m, 'v', "writes the request on its end");
    keeper_reads_request(c.end);
    token("after the request, the maker not exec'd", c.end);
    keeper_sends_nonce(c.end);
    step("the maker", c.to_m, c.from_m, 'a', "reads the nonce and writes it back");
    keeper_reads_answer(c.end);
    token("after the answer, the maker not exec'd", c.end);
    scene_exec(&c, 'X');
    token("after the maker's exec", c.end);
    scene_end(&c);
}

static void trial_m(void) {
    printf("== (m) a keeper-made end, sent over the maker's pair once its token names IMAGE: who can be named on it\n");
    scene_t c = scene_start(1);
    scene_exec(&c, 'x');
    token("on the maker's pair, after the exec", c.end);
    int made[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, made) != 0) die("socketpair (keeper's)");
    send_fd(c.end, "k", 1, made[1]);
    close(made[1]);
    printf("  the keeper made a pair and sent one end over its end of the maker's pair\n");
    step("S", c.to_s, c.from_s, 'k', "takes that end on its copy of the maker's end and writes a request on it");
    keeper_reads_request(made[0]);
    token("on the keeper-made end, after S's request", made[0]);
    step("IMAGE", c.to_i, c.from_i, 'e', "writes a line on its descriptor 2 (the maker's end, not the keeper-made one)");
    token("on the keeper-made end, after that line", made[0]);
    step("S", c.to_s, c.from_s, 'G', "passes the keeper-made end to IMAGE over a socket IMAGE has as descriptor 6");
    step("IMAGE", c.to_i, c.from_i, 'f', "takes a descriptor on descriptor 6 and reads it once, not waiting");
    token("on the keeper-made end, after IMAGE took it and read once", made[0]);
    close(made[0]);
    scene_end(&c);
}

// --- (j) and (k): which acts of a holder move the token; the token once the last to act has exited -----------------
typedef struct { pid_t h1, h2; int t1, f1, t2, f2, end; } holders_t;

static holders_t holders_start(void) {
    int pair[2], a[2], b[2], c[2], d[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0 || pipe(a) || pipe(b) || pipe(c) || pipe(d)) die("holders");
    holders_t h = {.end = pair[1]};
    h.h1 = fork();
    if (h.h1 == 0) { close(pair[1]); close(a[1]); close(b[0]); close(c[0]); close(c[1]); close(d[0]); close(d[1]); tell_who(b[1]); holder_loop(pair[0], a[0], b[1], -1); }
    h.h2 = fork();
    if (h.h2 == 0) { close(pair[1]); close(c[1]); close(d[0]); close(a[0]); close(a[1]); close(b[0]); close(b[1]); tell_who(d[1]); holder_loop(pair[0], c[0], d[1], -1); }
    close(pair[0]); close(a[0]); close(b[1]); close(c[0]); close(d[1]);
    h.t1 = a[1]; h.f1 = b[0]; h.t2 = c[1]; h.f2 = d[0];
    child = hear_who(h.f1);
    third = hear_who(h.f2);
    have_child = have_third = 1;
    child_name = "holder 1";
    third_name = "holder 2";
    keeper = own();
    maker = (who_t){0, 0};
    return h;
}

static void holders_end(holders_t *h) {
    char q = 'q';
    write(h->t1, &q, 1); write(h->t2, &q, 1);
    waitpid(h->h1, NULL, 0); waitpid(h->h2, NULL, 0);
    close(h->t1); close(h->f1); close(h->t2); close(h->f2); close(h->end);
    have_child = have_third = 0;
    child_name = "the maker's forked child";
    third_name = "the third process";
}

static void drain(int end) {
    char bytes[4096];
    while (recv(end, bytes, sizeof bytes, MSG_DONTWAIT) > 0) {}
}

// Holder 1 writes a byte (the token then names it), the keeper drains its end; then holder 2's act, and the token.
static void act_line(holders_t *h, char code, const char *what) {
    char w = 'w', r[2];
    put(h->t1, &w, 1); get(h->f1, r, 2);
    drain(h->end);
    put(h->t2, &code, 1);
    get(h->f2, r, 2);
    audit_token_t t;
    socklen_t n = sizeof t;
    printf("  holder 2: %s (%s) -> ", what, how(r[0], r[1]));
    if (getsockopt(h->end, SOL_LOCAL, LOCAL_PEERTOKEN, &t, &n) != 0) printf("token refused errno=%d\n", errno);
    else printf("the token names %s\n", label(of(t)));
    drain(h->end);
}

static const char *named_now(int end) {
    audit_token_t t;
    socklen_t n = sizeof t;
    if (getsockopt(end, SOL_LOCAL, LOCAL_PEERTOKEN, &t, &n) != 0) return "nobody (refused)";
    return label(of(t));
}

static void trial_j(void) {
    printf("== (j) which acts of a holder move the token: a pair made here, its other end held by two forked holders; before each act holder 1 writes a byte (the token then names holder 1)\n");
    holders_t h = holders_start();
    printf("  keeper pid=%d pidversion=%d; holder 1 pid=%d pidversion=%d; holder 2 pid=%d pidversion=%d\n", keeper.pid, keeper.version, child.pid, child.version, third.pid, third.version);
    act_line(&h, 'w', "a 1-byte write");
    act_line(&h, 'W', "a zero-length send");
    act_line(&h, 'n', "a read that doesn't wait, nothing there (EAGAIN)");
    act_line(&h, 'p', "a peek that doesn't wait, nothing there");
    act_line(&h, 'P', "poll");
    act_line(&h, 'g', "getsockopt SO_TYPE");
    act_line(&h, 's', "setsockopt SO_RCVTIMEO (what the handover keeper's limitIO does)");
    act_line(&h, 'm', "getpeername");
    act_line(&h, 'i', "ioctl FIONREAD");
    act_line(&h, 'f', "fstat");
    act_line(&h, 'd', "dup, then close the copy");
    {   // a peek and a read with a byte there
        char w = 'w', r[2], p = 'p', n = 'n';
        put(h.t1, &w, 1); get(h.f1, r, 2); drain(h.end);
        if (write(h.end, "y", 1) != 1) die("write");
        put(h.t2, &p, 1); get(h.f2, r, 2);
        printf("  holder 2: a peek with a byte there (%s) -> the token names %s\n", how(r[0], r[1]), named_now(h.end));
        put(h.t1, &w, 1); get(h.f1, r, 2); drain(h.end);
        put(h.t2, &n, 1); get(h.f2, r, 2);
        printf("  holder 2: a read with a byte there (%s) -> the token names %s\n", how(r[0], r[1]), named_now(h.end));
    }
    {   // a read that waits: the token asked while it waits (for at most 1 s), then after a byte ends the wait
        char w = 'w', rr = 'r', r[2];
        put(h.t1, &w, 1); get(h.f1, r, 2); drain(h.end);
        put(h.t2, &rr, 1); get(h.f2, r, 2);  // 'b': holder 2 says it is about to read
        const char *seen = named_now(h.end);
        for (int i = 0; i < 500 && strcmp(seen, "holder 2") != 0; i++) { usleep(2000); seen = named_now(h.end); }
        printf("  holder 2: a read that waits, entered, nothing there yet -> while it waits (asked for up to 1 s) the token names %s\n", seen);
        if (write(h.end, "y", 1) != 1) die("write");
        get(h.f2, r, 2);
        printf("  holder 2: that read, ended by a byte from the keeper (%s) -> the token names %s\n", how(r[0], r[1]), named_now(h.end));
    }
    holders_end(&h);

    printf("== (j) after the end's write side is shut (holder 1's shutdown SHUT_WR; SIGPIPE ignored)\n");
    h = holders_start();
    {
        char w = 'w', S = 'S', r[2];
        put(h.t1, &w, 1); get(h.f1, r, 2); drain(h.end);
        put(h.t1, &S, 1); get(h.f1, r, 2);
        printf("  holder 1: shutdown SHUT_WR (%s) -> the token names %s\n", how(r[0], r[1]), named_now(h.end));
        char ops[] = {'w', 'W'};
        const char *names[] = {"a 1-byte write (EPIPE expected)", "a zero-length send"};
        for (int k = 0; k < 2; k++) {
            put(h.t2, &ops[k], 1); get(h.f2, r, 2);
            printf("  holder 2: %s (%s) -> the token names %s\n", names[k], how(r[0], r[1]), named_now(h.end));
        }
        char x = 'w';
        put(h.t1, &x, 1); get(h.f1, r, 2);
        printf("  holder 1: a 1-byte write (%s) -> the token names %s\n", how(r[0], r[1]), named_now(h.end));
        keeper_pending(h.end, "(no byte expected)");
    }
    holders_end(&h);

    printf("== (j) after the end's read side is shut (holder 1's shutdown SHUT_RD)\n");
    h = holders_start();
    {
        char w = 'w', R = 'R', n = 'n', rr = 'r', r[2];
        put(h.t1, &w, 1); get(h.f1, r, 2); drain(h.end);
        put(h.t1, &R, 1); get(h.f1, r, 2);
        printf("  holder 1: shutdown SHUT_RD (%s) -> the token names %s\n", how(r[0], r[1]), named_now(h.end));
        put(h.t2, &n, 1); get(h.f2, r, 2);
        printf("  holder 2: a read that doesn't wait (%s) -> the token names %s\n", how(r[0], r[1]), named_now(h.end));
        put(h.t1, &w, 1); get(h.f1, r, 2);
        put(h.t2, &rr, 1); get(h.f2, r, 2); get(h.f2, r, 2);
        printf("  holder 2: a read that would wait (%s, at once) -> the token names %s\n", how(r[0], r[1]), named_now(h.end));
    }
    holders_end(&h);

    printf("== (k) the last to act has exited, another holder keeps the end open\n");
    h = holders_start();
    {
        char w = 'w', q = 'q', r[2];
        put(h.t1, &w, 1); get(h.f1, r, 2); drain(h.end);
        printf("  holder 1 wrote a byte -> the token names %s\n", named_now(h.end));
        put(h.t1, &q, 1);
        waitpid(h.h1, NULL, 0);
        printf("  holder 1 exited and was reaped; holder 2 still holds the end\n");
        token("after holder 1's exit", h.end);
        struct pollfd p = {.fd = h.end, .events = POLLIN | POLLOUT};
        int got = poll(&p, 1, 0);
        printf("  poll: %d revents=0x%x\n", got, p.revents);
        put(h.t2, &w, 1); get(h.f2, r, 2);
        token("after holder 2 writes", h.end);
        drain(h.end);
        h.h1 = 0;
        write(h.t2, &q, 1);
        waitpid(h.h2, NULL, 0);
        close(h.t1); close(h.f1); close(h.t2); close(h.f2); close(h.end);
        have_child = have_third = 0;
        child_name = "the maker's forked child";
        third_name = "the third process";
    }
}

// A descriptor taken from a connection's one message, or -1 (the message came without one).
static int receive_fd_soft(int socket) {
    char bytes[64];
    struct iovec io = {.iov_base = bytes, .iov_len = sizeof bytes};
    char control[CMSG_SPACE(sizeof(int))];
    struct msghdr message = {.msg_iov = &io, .msg_iovlen = 1, .msg_control = control, .msg_controllen = sizeof control};
    if (recvmsg(socket, &message, 0) <= 0) return -1;
    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    if (!header || header->cmsg_type != SCM_RIGHTS) return -1;
    int fd;
    memcpy(&fd, CMSG_DATA(header), sizeof fd);
    return fd;
}

// --- (l) the end of file a first version of K-M1 saw: the sent end closed by its maker while still in flight --------
static void trial_l(int mode, int runs, const char *title) {
    int requests = 0, ends = 0, nothing = 0, none = 0;
    for (int i = 0; i < runs; i++) {
        int to[2], from[2];
        if (pipe(to) || pipe(from)) die("pipe");
        pid_t m = fork();
        if (m == 0) {
            close(to[1]); close(from[0]);
            int connection = connect_to_keeper();
            int pair[2];
            if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) die("socketpair");
            if (write(pair[0], "req", 3) != 3) die("write");
            send_fd(connection, "vibeswitcher-keeper-v1\n", 23, pair[1]);
            if (mode > 0) hear(to[0]);   // 1: the keeper accepted; 2: the keeper holds the end
            close(pair[1]);
            close(connection);
            say(from[1]);
            hear(to[0]);
            _exit(0);
        }
        close(to[0]); close(from[1]);
        int connection = -1, end = -1;
        if (mode == 0) { hear(from[0]); connection = accept(listener, NULL, NULL); end = receive_fd_soft(connection); }
        if (mode == 1) { connection = accept(listener, NULL, NULL); say(to[1]); hear(from[0]); end = receive_fd_soft(connection); }
        if (mode == 2) { connection = accept(listener, NULL, NULL); end = receive_fd_soft(connection); say(to[1]); hear(from[0]); }
        close(connection);
        struct pollfd p = {.fd = end, .events = POLLIN};
        char bytes[3];
        if (end < 0) none++;
        else if (poll(&p, 1, 1000) != 1) nothing++;
        else {
            ssize_t n = read(end, bytes, 3);
            if (n == 3) requests++; else if (n == 0) ends++; else nothing++;
        }
        close(end);
        say(to[1]);
        waitpid(m, NULL, 0);
        close(to[1]); close(from[0]);
    }
    printf("== %s\n  %d runs: the request read %d, end of file %d, nothing within 1 s %d, no descriptor in the hello %d\n", title, runs, requests, ends, nothing, none);
}

// --- (n) a Mach message's audit trailer: the sender's token as it was when it sent ---------------------------------
// The probe's port reaches its children as their bootstrap special port, which fork, posix_spawn and exec carry: the
// probe sets its own to that port around each fork (and restores it at once), or names it for a spawn
// (posix_spawnattr_setspecialport_np). The children here and the images they exec look nothing up through it. (n0)
// first: the registered ports (mach_ports_register), which this probe tried first.
static mach_port_t registered = MACH_PORT_NULL, saved_bootstrap = MACH_PORT_NULL;

static void mach_make(void) {
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &registered) != KERN_SUCCESS) die("mach_port_allocate");
    if (mach_port_insert_right(mach_task_self(), registered, registered, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) die("insert_right");
    if (task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &saved_bootstrap) != KERN_SUCCESS) die("task_get_special_port");
}

static pid_t fork_with_port(void) {
    if (task_set_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, registered) != KERN_SUCCESS) die("task_set_special_port");
    pid_t m = fork();
    if (m != 0 && task_set_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, saved_bootstrap) != KERN_SUCCESS) die("restore");
    return m;
}

static int mach_send_to(mach_port_t port, const char *tag) {
    if (!MACH_PORT_VALID(port)) return 0;
    struct { mach_msg_header_t header; char body[8]; } message;
    memset(&message, 0, sizeof message);
    message.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    message.header.msgh_size = sizeof message;
    message.header.msgh_remote_port = port;
    strncpy(message.body, tag, sizeof message.body - 1);
    return mach_msg(&message.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof message, 0, MACH_PORT_NULL, 5000, MACH_PORT_NULL) == KERN_SUCCESS;
}

static void mach_send_or_say(const char *tag) {
    mach_port_t port = MACH_PORT_NULL;
    task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &port);
    if (!mach_send_to(port, tag)) printf("  (%s: the send failed)\n", tag);
}

static void mach_receive(const char *when) {
    struct { mach_msg_header_t header; char body[8]; mach_msg_audit_trailer_t trailer; } message;
    memset(&message, 0, sizeof message);
    kern_return_t got = mach_msg(&message.header,
                                 MACH_RCV_MSG | MACH_RCV_TIMEOUT | MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) | MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT),
                                 0, sizeof message, registered, 5000, MACH_PORT_NULL);
    if (got != KERN_SUCCESS) { printf("  %s: no message within 5 s (0x%x)\n", when, got); return; }
    who_t w = of(message.trailer.msgh_audit);
    printf("  %s: the message \"%.7s\", its trailer's token pid=%d pidversion=%d = %s", when, message.body, w.pid, w.version, label(w));
    security(message.trailer.msgh_audit);
    printf("\n");
}

static void trial_n(void) {
    mach_make();
    {
        printf("== (n0) Mach: the probe's port registered for its task (mach_ports_register); a forked child looks its registered ports up and sends to the first\n");
        mach_ports_register(mach_task_self(), &registered, 1);
        pid_t c = fork();
        if (c == 0) {
            mach_port_array_t ports = NULL;
            mach_msg_type_number_t count = 0;
            kern_return_t kr = mach_ports_lookup(mach_task_self(), &ports, &count);
            int sent = kr == KERN_SUCCESS && count > 0 && mach_send_to(ports[0], "child");
            printf("  the child's lookup: 0x%x, %u ports, the first %s the probe's port name; its send: %s\n", kr, count,
                   count > 0 && ports[0] == registered ? "is" : "isn't", sent ? "accepted by the kernel" : "failed");
            _exit(0);
        }
        waitpid(c, NULL, 0);
        mach_receive("the probe's port, once the child exited");
        mach_ports_register(mach_task_self(), NULL, 0);
    }
    const char *titles[] = {
        "== (n1) Mach: a live maker sends one message to the probe's port (its bootstrap special port, set at its fork); it doesn't exec",
        "== (n2) Mach: the maker sends, then execs PROGRAM; the message read only after the exec",
        "== (n3) Mach: the maker sends, then exits; the message read only after its exit",
        "== (n4) Mach: the maker's forked child sends; the maker execs PROGRAM; read after the exec",
        "== (n5) Mach: the maker execs IMAGE, whose own code sends to its bootstrap special port (the port crosses the exec)",
    };
    for (int k = 0; k < 5; k++) {
        printf("%s\n", titles[k]);
        int to[2], from[2], ex[2], cw[2];
        if (pipe(to) || pipe(from) || pipe(cw)) die("pipe");
        closed_on_exec_pipe(ex);
        have_child = k == 3;
        pid_t m = fork_with_port();
        if (m == 0) {
            close(to[1]); close(from[0]); close(ex[0]); close(cw[0]);
            tell_who(from[1]);
            if (k == 3) {
                pid_t c = fork();
                if (c == 0) { close(ex[1]); close(to[0]); tell_who(cw[1]); mach_send_or_say("child"); sleep(30); _exit(0); }
                close(cw[1]);
            } else if (k != 4) mach_send_or_say("maker");
            say(from[1]);
            hear(to[0]);
            if (k == 1 || k == 3) exec_program();
            if (k == 4) { execl(image, image, "mach", (char *)NULL); _exit(127); }
            _exit(0);
        }
        close(to[0]); close(from[1]); close(ex[1]); close(cw[1]);
        maker = hear_who(from[0]);
        keeper = own();
        if (k == 3) { child = hear_who(cw[0]); }
        hear(from[0]);
        who_line();
        if (k == 0) mach_receive("the maker alive, not exec'd");
        say(to[1]);
        if (k == 1 || k == 3 || k == 4) await_exec(ex[0]);
        if (k == 2) { waitpid(m, NULL, 0); printf("  the maker exited and was reaped\n"); }
        if (k == 1) mach_receive("read after the maker's exec");
        if (k == 2) mach_receive("read after the maker's exit");
        if (k == 3) mach_receive("read after the maker's exec");
        if (k == 4) mach_receive("read once IMAGE ran");
        if (k != 2) { kill(m, SIGTERM); waitpid(m, NULL, 0); }
        if (k == 3) kill(child.pid, SIGTERM);
        close(to[1]); close(from[0]); close(ex[0]); close(cw[0]);
        have_child = 0;
    }
    printf("== (n6) Mach: IMAGE started by posix_spawn from the probe (as a host starts its children), the probe's port named as its bootstrap special port\n");
    int report[2];
    if (pipe(report)) die("pipe");
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, report[1], 4);
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setspecialport_np(&attributes, registered, TASK_BOOTSTRAP_PORT);
    pid_t spawned_pid;
    char *args[] = {(char *)image, "mach", "4", NULL};
    extern char **environ;
    if (posix_spawn(&spawned_pid, image, &actions, &attributes, args, environ) != 0) die("posix_spawn");
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    close(report[1]);
    spawned = hear_who(report[0]);
    have_spawned = 1;
    keeper = own();
    printf("  keeper pid=%d pidversion=%d; spawned image pid=%d pidversion=%d\n", keeper.pid, keeper.version, spawned.pid, spawned.version);
    mach_receive("read once the spawned image ran");
    kill(spawned_pid, SIGTERM);
    waitpid(spawned_pid, NULL, 0);
    close(report[0]);
    have_spawned = 0;
    mach_port_mod_refs(mach_task_self(), registered, MACH_PORT_RIGHT_RECEIVE, -1);
}

// --- (o) whether a Unix socket carries a sender's credentials per message (SCM_CREDS) on this Mac -------------------
#define CREDS_SIZE 96
static void trial_o(void) {
    printf("== (o) SCM_CREDS: a message on a pair carrying an SCM_CREDS control message of 96 zero bytes (this SDK names SCM_CREDS but defines no struct cmsgcred)\n");
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) die("socketpair");
    char control[CMSG_SPACE(CREDS_SIZE)];
    memset(control, 0, sizeof control);
    char byte = 'c';
    struct iovec io = {.iov_base = &byte, .iov_len = 1};
    struct msghdr message = {.msg_iov = &io, .msg_iovlen = 1, .msg_control = control, .msg_controllen = sizeof control};
    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_CREDS;
    header->cmsg_len = CMSG_LEN(CREDS_SIZE);
    ssize_t sent = sendmsg(pair[0], &message, 0);
    if (sent < 0) printf("  sendmsg with SCM_CREDS: refused errno=%d (%s)\n", errno, strerror(errno));
    else {
        char back[CMSG_SPACE(CREDS_SIZE) + 64];
        struct msghdr in = {.msg_iov = &io, .msg_iovlen = 1, .msg_control = back, .msg_controllen = sizeof back};
        ssize_t got = recvmsg(pair[1], &in, MSG_DONTWAIT);
        struct cmsghdr *h = got > 0 ? CMSG_FIRSTHDR(&in) : NULL;
        printf("  sendmsg with SCM_CREDS: sent %zd; received %zd, control %s", sent, got, h ? "present" : "none");
        if (h) printf(" (level %d type %d len %u)", h->cmsg_level, h->cmsg_type, (unsigned)h->cmsg_len);
        printf("\n");
    }
    close(pair[0]); close(pair[1]);
}

static void part_two(void) {
    printf("#### K-M1, second part: (g) to (o)\n");
    trial_g();
    trial_h();
    trial_i();
    trial_m();
    trial_j();
    trial_l(0, 200, "(l) the maker closes its copy of the sent end and its connection at once, before the keeper's accept");
    trial_l(1, 200, "(l) the maker closes them after the keeper's accept, before its recvmsg");
    trial_l(2, 200, "(l) the maker closes them once the keeper holds the end (K-M1's makers, and the handover keeper's rule)");
    trial_n();
    trial_o();
}

// ======================================================================================================================
// K-M16's here part (2026-11-27, the proof review's I1, I2 and D1): assumption A measured only as far as a hardened
// child can see itself, and Security's check timed. The probe sets exception ports for its own child, with a port E it
// made and never receives on, by every way a parent can: posix_spawn's attributes (posix_spawnattr_setexceptionports_np),
// its own task's ports and the exec'ing thread's ports set by the forked child just before its exec; each with every
// behaviour, for each mask group (EXC_MASK_ALL, EXC_MASK_CRASH, EXC_MASK_CORPSE_NOTIFY). The child is IMAGE (hardened)
// or PLAIN (the same source, not hardened) in its `ports` mode: it reports what it found on itself at its first
// statement (main's first line), clears every mask on its task and main thread, and reads them again. No exception is
// raised, none is received, none is answered: E is destroyed unread. Then rlimits a parent sets before the exec, and
// the time from just before the spawn or exec to the first statement (the window before any statement of the image's
// own runs: dyld and the libraries' initializers), for IMAGE and for a Swift image linking Foundation (WINDOW).
// (D1) Security's check timed on a message from IMAGE and from BIG (IMAGE's source with a 256 MiB section of random
// bytes, so its signature covers 256 MiB), and again once a copy of IMAGE is renamed over BIG's path while BIG runs.
// What isn't run here (the active routes: a handler receiving a fault, a state reply, a task port the child handed
// over before its exec, a traced exec) is owed to the keyboard trial (K7): not from an agent's session.
// ======================================================================================================================
static const char *image_plain, *image_big, *image_window;
static CFDataRef big_cdhash;
static mach_port_t unread = MACH_PORT_NULL;  // E: the handler port the probe names and never receives on

static double micros(uint64_t from, uint64_t to) {
    static mach_timebase_info_data_t base;
    if (!base.denom) mach_timebase_info(&base);
    return (double)(to - from) * base.numer / base.denom / 1000.0;
}

#if defined(__arm64__)
#define STATE_FLAVOR ARM_THREAD_STATE64
#else
#define STATE_FLAVOR x86_THREAD_STATE64
#endif

static const struct { const char *name; exception_behavior_t behavior; thread_state_flavor_t flavor; } behaviours[] = {
    {"EXCEPTION_DEFAULT", EXCEPTION_DEFAULT, THREAD_STATE_NONE},
    {"EXCEPTION_STATE", EXCEPTION_STATE, STATE_FLAVOR},
    {"EXCEPTION_STATE_IDENTITY", EXCEPTION_STATE_IDENTITY, STATE_FLAVOR},
    {"EXCEPTION_IDENTITY_PROTECTED", EXCEPTION_IDENTITY_PROTECTED, THREAD_STATE_NONE},
    {"EXCEPTION_STATE_IDENTITY_PROTECTED", EXCEPTION_STATE_IDENTITY_PROTECTED, STATE_FLAVOR},
};
#define BEHAVIOURS (sizeof behaviours / sizeof behaviours[0])
static const exception_mask_t set_masks[3] = {EXC_MASK_ALL, EXC_MASK_CRASH, EXC_MASK_CORPSE_NOTIFY};
static const char *set_names[3] = {"ALL", "CRASH", "CORPSE_NOTIFY"};

enum route { BASELINE, SPAWN_ATTR, OWN_TASK, OWN_THREAD };

// The image's lines until the end of file, printed; the window from `before` to the first statement it reports; how
// it ended.
static void image_lines(int from, pid_t pid, uint64_t before) {
    FILE *in = fdopen(from, "r");
    char *line = NULL;
    size_t size = 0;
    unsigned long long first = 0;
    int lines = 0, marked = 0;
    while (getline(&line, &size, in) > 0) {
        lines++;
        if (strstr(line, "main's first statement reached")) marked = 1;
        printf("%s", line);
        const char *mark = strstr(line, "first statement at ");
        if (mark) first = strtoull(mark + strlen("first statement at "), NULL, 10);
    }
    free(line);
    fclose(in);
    int status = 0;
    waitpid(pid, &status, 0);
    if (first && before) printf("  the window, from just before the spawn or exec to its first statement: %.0f us\n", micros(before, first));
    printf("  its main's first statement: %s\n", marked ? "reached (the marker came)" : "never reached (no marker on descriptor 99)");
    if (WIFEXITED(status)) printf("  it exited %d%s\n", WEXITSTATUS(status), lines ? "" : ", having written nothing");
    else if (WIFSIGNALED(status)) printf("  it was ended by signal %d (%s)%s\n", WTERMSIG(status), strsignal(WTERMSIG(status)), lines ? "" : " before its first statement wrote anything");
}

static void ports_case(const char *title, const char *img, enum route route, size_t b) {
    printf("== %s\n", title);
    int lines[2], report[2];
    if (pipe(lines) || pipe(report)) die("pipe");
    lines[0] = high(lines[0]); lines[1] = high(lines[1]); report[0] = high(report[0]); report[1] = high(report[1]);
    exception_behavior_t behavior = behaviours[b].behavior | MACH_EXCEPTION_CODES;
    uint64_t before = 0;
    pid_t pid;
    if (route == BASELINE || route == SPAWN_ATTR) {
        posix_spawn_file_actions_t actions;
        posix_spawn_file_actions_init(&actions);
        posix_spawn_file_actions_adddup2(&actions, lines[1], 3);
        posix_spawn_file_actions_adddup2(&actions, lines[1], 99);
        posix_spawnattr_t attributes;
        posix_spawnattr_init(&attributes);
        if (route == SPAWN_ATTR) {
            printf("  posix_spawnattr_setexceptionports_np(E, %s|MACH_EXCEPTION_CODES):", behaviours[b].name);
            for (int m = 0; m < 3; m++)
                printf(" %s %d", set_names[m], posix_spawnattr_setexceptionports_np(&attributes, set_masks[m], unread, behavior, behaviours[b].flavor));
            printf("\n");
        }
        char *args[] = {(char *)img, "ports", "3", NULL};
        extern char **environ;
        before = mach_absolute_time();
        int spawned_ok = posix_spawn(&pid, img, &actions, &attributes, args, environ);
        posix_spawn_file_actions_destroy(&actions);
        posix_spawnattr_destroy(&attributes);
        if (spawned_ok != 0) { printf("  posix_spawn refused: %d (%s)\n", spawned_ok, strerror(spawned_ok)); close(lines[0]); close(lines[1]); close(report[0]); close(report[1]); return; }
    } else {
        // The forked child gets E as its bootstrap special port (set around the fork and restored at once, as (n)).
        mach_port_t saved = MACH_PORT_NULL;
        if (task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &saved) != KERN_SUCCESS) die("task_get_special_port");
        if (task_set_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, unread) != KERN_SUCCESS) die("task_set_special_port");
        pid = fork();
        if (pid != 0 && task_set_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, saved) != KERN_SUCCESS) die("restore");
        if (pid == 0) {
            close(lines[0]); close(report[0]);
            int results[3] = {0, 0, 0};
            mach_port_t e = MACH_PORT_NULL;
            task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &e);
            if (route == OWN_TASK)
                for (int m = 0; m < 3; m++) results[m] = task_set_exception_ports(mach_task_self(), set_masks[m], e, behavior, behaviours[b].flavor);
            if (route == OWN_THREAD) {
                mach_port_t thread = mach_thread_self();
                for (int m = 0; m < 3; m++) results[m] = thread_set_exception_ports(thread, set_masks[m], e, behavior, behaviours[b].flavor);
            }
            put(report[1], results, sizeof results);
            if (dup2(lines[1], 3) != 3 || dup2(lines[1], 99) != 99) _exit(126);
            close(lines[1]);
            uint64_t t = mach_absolute_time();
            put(report[1], &t, sizeof t);
            close(report[1]);
            execl(img, img, "ports", "3", (char *)NULL);
            _exit(127);
        }
        close(report[1]);
        int results[3];
        ssize_t got = read(report[0], results, sizeof results);
        if (got != (ssize_t)sizeof results) {
            int status = 0;
            waitpid(pid, &status, 0);
            printf("  the forked child ended before its exec (%s %d)\n", WIFSIGNALED(status) ? "signal" : "exit", WIFSIGNALED(status) ? WTERMSIG(status) : WEXITSTATUS(status));
            close(report[0]); close(lines[0]); close(lines[1]);
            return;
        }
        if (route == OWN_TASK || route == OWN_THREAD)
            printf("  the forked child's %s(E, %s|MACH_EXCEPTION_CODES) just before its exec: ALL 0x%x, CRASH 0x%x, CORPSE_NOTIFY 0x%x\n",
                   route == OWN_TASK ? "task_set_exception_ports" : "thread_set_exception_ports (its own thread, the one that execs)",
                   behaviours[b].name, results[0], results[1], results[2]);
        get(report[0], &before, sizeof before);
        close(report[0]);
    }
    close(lines[1]);
    if (route == BASELINE || route == SPAWN_ATTR) { close(report[0]); close(report[1]); }
    image_lines(lines[0], pid, before);
}

// A launcher (IMAGE in its `limit` mode, standing for a session's) lowers one of its limits, then execs the target
// (IMAGE in its `ports` mode, or WINDOW): what the target finds, or how it ended before its first statement.
static void limit_case(const char *title, const char *name, const char *value, const char *target) {
    printf("== %s\n", title);
    int lines[2];
    if (pipe(lines)) die("pipe");
    lines[0] = high(lines[0]);
    lines[1] = high(lines[1]);
    // The launcher starts with descriptors 0 to 3 and the marker's 98 alone (POSIX_SPAWN_CLOEXEC_DEFAULT), so under a
    // limit of 4 none is free below it and under 5 one is.
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    for (int fd = 0; fd <= 2; fd++) posix_spawn_file_actions_addinherit_np(&actions, fd);
    posix_spawn_file_actions_adddup2(&actions, lines[1], 3);
    posix_spawn_file_actions_adddup2(&actions, lines[1], 98);
    posix_spawnattr_t limited;
    posix_spawnattr_init(&limited);
    posix_spawnattr_setflags(&limited, POSIX_SPAWN_CLOEXEC_DEFAULT);
    char *with_ports[] = {(char *)image, "limit", (char *)name, (char *)value, (char *)target, "ports", "3", NULL};
    char *bare[] = {(char *)image, "limit", (char *)name, (char *)value, (char *)target, NULL};
    extern char **environ;
    pid_t pid;
    if (posix_spawn(&pid, image, &actions, &limited, target == image ? with_ports : bare, environ) != 0) die("posix_spawn");
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&limited);
    close(lines[1]);
    image_lines(lines[0], pid, 0);
}

// The window alone, for WINDOW (a Swift image linking Foundation): it writes its first statement's time on 3 and ends.
static void window_case(const char *title, const char *img) {
    printf("== %s\n", title);
    int lines[2];
    if (pipe(lines)) die("pipe");
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, lines[1], 3);
    posix_spawn_file_actions_adddup2(&actions, lines[1], 99);
    char *args[] = {(char *)img, NULL};
    extern char **environ;
    pid_t pid;
    uint64_t before = mach_absolute_time();
    if (posix_spawn(&pid, img, &actions, NULL, args, environ) != 0) die("posix_spawn");
    posix_spawn_file_actions_destroy(&actions);
    close(lines[1]);
    image_lines(lines[0], pid, before);
}

static void a_routes(void) {
    printf("#### K-M16, here: what a hardened child finds on itself (assumption A's passive half)\n");
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &unread) != KERN_SUCCESS) die("mach_port_allocate");
    if (mach_port_insert_right(mach_task_self(), unread, unread, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) die("insert_right");
    ports_case("(p0) baseline: IMAGE spawned with no exception port named (what a child of this probe inherits)", image, BASELINE, 0);
    char title[256];
    for (size_t b = 0; b < BEHAVIOURS; b++) {
        snprintf(title, sizeof title, "(p1) IMAGE spawned with E named in posix_spawn's attributes, %s", behaviours[b].name);
        ports_case(title, image, SPAWN_ATTR, b);
    }
    for (size_t b = 0; b < BEHAVIOURS; b++) {
        snprintf(title, sizeof title, "(p2) a forked child sets E as its own task's exception port, %s, then execs IMAGE", behaviours[b].name);
        ports_case(title, image, OWN_TASK, b);
    }
    for (size_t b = 0; b < BEHAVIOURS; b++) {
        snprintf(title, sizeof title, "(p3) a forked child sets E on its own thread (the one that execs), %s, then execs IMAGE", behaviours[b].name);
        ports_case(title, image, OWN_THREAD, b);
    }
    ports_case("(p4) control, not hardened: PLAIN spawned with E in posix_spawn's attributes, EXCEPTION_STATE", image_plain, SPAWN_ATTR, 1);
    ports_case("(p4) control, not hardened: a forked child sets E on its own task, EXCEPTION_STATE, then execs PLAIN", image_plain, OWN_TASK, 1);
    ports_case("(p4) control, not hardened: a forked child sets E on its own thread, EXCEPTION_STATE, then execs PLAIN", image_plain, OWN_THREAD, 1);
    mach_port_mod_refs(mach_task_self(), unread, MACH_PORT_RIGHT_RECEIVE, -1);
    mach_port_deallocate(mach_task_self(), unread);
    unread = MACH_PORT_NULL;
    printf("#### K-M16, here: rlimits a launcher sets before its exec (no exception port named)\n");
    limit_case("(q1) the launcher lowers RLIMIT_STACK to 64 KiB, then execs IMAGE", "STACK", "65536", image);
    limit_case("(q2) the launcher lowers RLIMIT_STACK to 16 KiB, then execs IMAGE", "STACK", "16384", image);
    limit_case("(q3) the launcher lowers RLIMIT_STACK to 16 KiB, then execs WINDOW (Swift, Foundation)", "STACK", "16384", image_window);
    limit_case("(q4) the launcher lowers RLIMIT_NOFILE to 4 (descriptors 0 to 3 open, none free below the limit), then execs IMAGE", "NOFILE", "4", image);
    limit_case("(q5) the launcher lowers RLIMIT_NOFILE to 5 (one free below the limit), then execs IMAGE", "NOFILE", "5", image);
    limit_case("(q6) the launcher lowers RLIMIT_NOFILE to 4, then execs WINDOW (Swift, Foundation)", "NOFILE", "4", image_window);
    limit_case("(q7) the launcher lowers RLIMIT_NOFILE to 5, then execs WINDOW (Swift, Foundation)", "NOFILE", "5", image_window);
    limit_case("(q8) the launcher lowers RLIMIT_DATA to 1 MiB, then execs IMAGE", "DATA", "1048576", image);
    limit_case("(q9) the launcher lowers RLIMIT_CPU to 0, then execs IMAGE", "CPU", "0", image);
    printf("#### K-M16, here: the window before the first statement\n");
    for (int k = 0; k < 3; k++) ports_case("(w1) IMAGE (C) spawned bare: the window", image, BASELINE, 0);
    for (int k = 0; k < 3; k++) window_case("(w2) WINDOW (Swift, Foundation linked, hardened) spawned bare: the window", image_window);
}

// --- (D1) Security's check timed ------------------------------------------------------------------------------------
static int receive_token(mach_port_t port, audit_token_t *token) {
    struct { mach_msg_header_t header; char body[8]; mach_msg_audit_trailer_t trailer; } message;
    memset(&message, 0, sizeof message);
    kern_return_t got = mach_msg(&message.header,
                                 MACH_RCV_MSG | MACH_RCV_TIMEOUT | MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) | MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT),
                                 0, sizeof message, port, 5000, MACH_PORT_NULL);
    if (got != KERN_SUCCESS) { printf("  no message within 5 s (0x%x)\n", got); return 0; }
    *token = message.trailer.msgh_audit;
    return 1;
}

static SecRequirementRef cdhash_requirement(CFDataRef cdhash) {
    char text[128] = "cdhash H\"";
    for (CFIndex i = 0; i < CFDataGetLength(cdhash); i++) snprintf(text + strlen(text), 3, "%02x", CFDataGetBytePtr(cdhash)[i]);
    strcat(text, "\"");
    CFStringRef string = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
    SecRequirementRef requirement = NULL;
    SecRequirementCreateWithString(string, kSecCSDefaultFlags, &requirement);
    CFRelease(string);
    return requirement;
}

static double ms_since(uint64_t t0) { return micros(t0, mach_absolute_time()) / 1000.0; }

// The kernel's own record of the process the token names (csops_audittoken: refused once that pid's pidversion isn't
// the token's): its cdhash (CS_OPS_CDHASH) and its status word (CS_OPS_STATUS). No file is opened.
extern int csops_audittoken(pid_t pid, unsigned int ops, void *useraddr, size_t usersize, audit_token_t *token);

static void kernel_identity(audit_token_t token, CFDataRef own) {
    unsigned char cdhash[20];
    uint32_t status = 0;
    uint64_t t0 = mach_absolute_time();
    int got = csops_audittoken((pid_t)token.val[5], 5 /* CS_OPS_CDHASH */, cdhash, sizeof cdhash, &token);
    int error = got ? errno : 0;
    int got_status = csops_audittoken((pid_t)token.val[5], 0 /* CS_OPS_STATUS */, &status, sizeof status, &token);
    int status_error = got_status ? errno : 0;
    double took = ms_since(t0);
    printf("    csops_audittoken (the kernel's record, by the token), both calls in %.2f ms: ", took);
    if (got) printf("cdhash refused errno=%d (%s)", error, strerror(error));
    else {
        printf("cdhash ");
        for (int i = 0; i < 8; i++) printf("%02x", cdhash[i]);
        int same_bytes = own && CFDataGetLength(own) >= 20 && memcmp(cdhash, CFDataGetBytePtr(own), 20) == 0;
        printf(" (%s)", same_bytes ? "the image's as started" : "not the image's as started");
    }
    if (got_status) printf("; status refused errno=%d (%s)\n", status_error, strerror(status_error));
    else printf("; status word 0x%08x\n", status);
}

static void d1_checks(const char *when, audit_token_t token, CFDataRef own, CFDataRef other) {
    printf("  %s:\n", when);
    kernel_identity(token, own);
    CFDataRef data = CFDataCreate(NULL, (const UInt8 *)&token, sizeof token);
    const void *keys[] = {kSecGuestAttributeAudit};
    const void *values[] = {data};
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SecCodeRef code = NULL;
    uint64_t t0 = mach_absolute_time();
    OSStatus guest = SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &code);
    printf("    SecCodeCopyGuestWithAttributes: %d in %.2f ms\n", (int)guest, ms_since(t0));
    CFRelease(attributes);
    CFRelease(data);
    if (guest != errSecSuccess || !code) return;
    t0 = mach_absolute_time();
    CFDictionaryRef info = NULL;
    OSStatus dynamic = SecCodeCopySigningInformation((SecStaticCodeRef)code, kSecCSDynamicInformation, &info);
    double dynamic_ms = ms_since(t0);
    CFDataRef cdhash = info ? CFDictionaryGetValue(info, kSecCodeInfoUnique) : NULL;
    CFNumberRef word = info ? CFDictionaryGetValue(info, kSecCodeInfoStatus) : NULL;
    uint32_t flags = 0;
    if (word) CFNumberGetValue(word, kCFNumberSInt32Type, &flags);
    printf("    SecCodeCopySigningInformation(kSecCSDynamicInformation): %d in %.2f ms, cdhash ", (int)dynamic, dynamic_ms);
    print_cdhash(cdhash);
    printf(" (%s), status word 0x%08x\n", cdhash && CFEqual(cdhash, own) ? "the image's as started" : "not the image's as started", flags);
    if (info) CFRelease(info);
    SecRequirementRef mine = cdhash_requirement(own), theirs = cdhash_requirement(other);
    const struct { const char *name; SecCSFlags flags; SecRequirementRef requirement; } checks[] = {
        {"SecCodeCheckValidity, default flags, its own cdhash (the keeper's runs)", kSecCSDefaultFlags, mine},
        {"the same, again", kSecCSDefaultFlags, mine},
        {"the same, a third time", kSecCSDefaultFlags, mine},
        {"default flags, another image's cdhash (a pinned row that isn't the sender's)", kSecCSDefaultFlags, theirs},
        {"kSecCSBasicValidateOnly, its own cdhash", kSecCSBasicValidateOnly, mine},
        {"kSecCSMatchGuestRequirementInKernel, its own cdhash", kSecCSMatchGuestRequirementInKernel, mine},
        {"kSecCSMatchGuestRequirementInKernel, another image's cdhash", kSecCSMatchGuestRequirementInKernel, theirs},
    };
    for (size_t i = 0; i < sizeof checks / sizeof checks[0]; i++) {
        t0 = mach_absolute_time();
        OSStatus valid = SecCodeCheckValidity(code, checks[i].flags, checks[i].requirement);
        printf("    %s: %d in %.2f ms\n", checks[i].name, (int)valid, ms_since(t0));
    }
    CFRelease(mine);
    CFRelease(theirs);
    CFRelease(code);
}

// Spawns `img` in its `mach` mode with `port` as its bootstrap special port; returns its pid once its message came.
static pid_t spawn_sender(const char *img, mach_port_t port, audit_token_t *token) {
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setspecialport_np(&attributes, port, TASK_BOOTSTRAP_PORT);
    char *args[] = {(char *)img, "mach", NULL};
    extern char **environ;
    pid_t pid;
    if (posix_spawn(&pid, img, NULL, &attributes, args, environ) != 0) die("posix_spawn");
    posix_spawnattr_destroy(&attributes);
    if (!receive_token(port, token)) { kill(pid, SIGKILL); waitpid(pid, NULL, 0); return 0; }
    return pid;
}

static void d1_timing(void) {
    printf("#### D1: Security's check timed (as the user; the keeper runs it as root)\n");
    mach_port_t port;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) != KERN_SUCCESS) die("mach_port_allocate");
    if (mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) die("insert_right");
    struct stat small, big;
    stat(image, &small);
    stat(image_big, &big);
    printf("== (d1) IMAGE (%lld bytes) sends one message; its token checked\n", (long long)small.st_size);
    audit_token_t token;
    pid_t pid = spawn_sender(image, port, &token);
    if (pid) { d1_checks("IMAGE, its file as signed", token, image_cdhash, big_cdhash); kill(pid, SIGTERM); waitpid(pid, NULL, 0); }
    printf("== (d2) BIG (%lld bytes: IMAGE's source and a 256 MiB section) sends one message; its token checked; then a copy of IMAGE renamed over BIG's path while BIG runs, and the same token checked again\n", (long long)big.st_size);
    pid = spawn_sender(image_big, port, &token);
    if (pid) {
        d1_checks("BIG, its file as signed", token, big_cdhash, image_cdhash);
        char swap[PATH_MAX];
        snprintf(swap, sizeof swap, "%s.swap", image_big);
        int in = open(image, O_RDONLY), out = open(swap, O_WRONLY | O_CREAT | O_TRUNC, 0755);
        char buffer[65536];
        ssize_t n;
        while (in >= 0 && out >= 0 && (n = read(in, buffer, sizeof buffer)) > 0) put(out, buffer, (size_t)n);
        close(in);
        close(out);
        if (rename(swap, image_big) != 0) die("rename");
        printf("  a copy of IMAGE renamed over BIG's path; BIG (pid %d) %s\n", pid,
               kill(pid, 0) == 0 && waitpid(pid, NULL, WNOHANG) == 0 ? "still runs (kill 0 and waitpid WNOHANG checked)" : "is gone");
        d1_checks("BIG, its path now IMAGE's copy", token, big_cdhash, image_cdhash);
        kill(pid, SIGTERM);
        waitpid(pid, NULL, 0);
        printf("  BIG ended and reaped; its token asked again:\n");
        kernel_identity(token, big_cdhash);
    }
    printf("== (d3) a forked child sends one message, then execs IMAGE; the token asked of the kernel and of Security after the exec\n");
    int ex[2];
    closed_on_exec_pipe(ex);
    mach_port_t saved = MACH_PORT_NULL;
    if (task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &saved) != KERN_SUCCESS) die("task_get_special_port");
    if (task_set_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, port) != KERN_SUCCESS) die("task_set_special_port");
    pid_t c = fork();
    if (c != 0 && task_set_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, saved) != KERN_SUCCESS) die("restore");
    if (c == 0) {
        close(ex[0]);
        mach_send_or_say("before");
        execl(image, image, "sleep", (char *)NULL);
        _exit(127);
    }
    close(ex[1]);
    char byte;
    while (read(ex[0], &byte, 1) != 0) {
        if (errno != EINTR) break;
    }
    close(ex[0]);
    char path[PROC_PIDPATHINFO_MAXSIZE] = "";
    proc_pidpath(c, path, sizeof path);
    int alive = kill(c, 0) == 0 && waitpid(c, NULL, WNOHANG) == 0;
    printf("  the child's close-on-exec pipe ended; it %s\n", alive ? (strstr(path, "pair-image") ? "runs IMAGE (alive, its path IMAGE's)" : "is alive, its path not IMAGE's") : "is gone");
    if (receive_token(port, &token)) {
        printf("  the message read after the exec, its trailer's pid=%d pidversion=%d:\n", (int)token.val[5], (int)token.val[7]);
        kernel_identity(token, image_cdhash);
        CFDataRef data = CFDataCreate(NULL, (const UInt8 *)&token, sizeof token);
        const void *keys[] = {kSecGuestAttributeAudit};
        const void *values[] = {data};
        CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        SecCodeRef code = NULL;
        printf("    SecCodeCopyGuestWithAttributes: %d\n", (int)SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &code));
        if (code) CFRelease(code);
        CFRelease(attributes);
        CFRelease(data);
    }
    kill(c, SIGTERM);
    waitpid(c, NULL, 0);
    mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
    mach_port_deallocate(mach_task_self(), port);
}

static void part_three(void) {
    a_routes();
    d1_timing();
}

// IMAGE's, PLAIN's, BIG's and WINDOW's paths and cdhashes, for part three.
static void third_part_images(char **paths) {
    image = paths[0];
    image_plain = paths[1];
    image_big = paths[2];
    image_window = paths[3];
    image_cdhash = file_cdhash(image);
    big_cdhash = file_cdhash(image_big);
    printf("IMAGE's file cdhash=");
    print_cdhash(image_cdhash);
    printf("\nBIG's file cdhash=");
    print_cdhash(big_cdhash);
    printf("\n");
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    signal(SIGPIPE, SIG_IGN);
    if (argc == 6 && strcmp(argv[1], "--a-routes") == 0) {
        third_part_images(argv + 2);
        part_three();
        return 0;
    }
    if (argc != 3 && argc != 4 && argc != 7) {
        fprintf(stderr, "usage: pair-token SOCKET_PATH PROGRAM [IMAGE [PLAIN BIG WINDOW]] | pair-token --a-routes IMAGE PLAIN BIG WINDOW\n");
        return 64;
    }
    program = argv[2];
    image = argc >= 4 ? argv[3] : NULL;
    program_real = realpath(program, NULL);
    if (strlen(argv[1]) >= sizeof address.sun_path) { fprintf(stderr, "socket path too long\n"); return 1; }
    strcpy(address.sun_path, argv[1]);
    char self[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(getpid(), self, sizeof self) <= 0) die("proc_pidpath (self)");
    own_file_cdhash = file_cdhash(self);
    program_cdhash = file_cdhash(program);
    printf("this probe's file cdhash=");
    print_cdhash(own_file_cdhash);
    printf("\nPROGRAM's file cdhash=");
    print_cdhash(program_cdhash);
    printf("\n");
    if (image) {
        image_cdhash = file_cdhash(image);
        printf("IMAGE's file cdhash=");
        print_cdhash(image_cdhash);
        printf("\n");
    }
    listener = socket(AF_UNIX, SOCK_STREAM, 0);
    unlink(argv[1]);
    if (bind(listener, (struct sockaddr *)&address, sizeof address) != 0 || listen(listener, 4) != 0) die("bind/listen");
    char folder[sizeof address.sun_path];
    strcpy(folder, argv[1]);
    char *slash = strrchr(folder, '/');
    if (slash) *slash = 0;

    trial(LIVE, "control: a live maker that hasn't exec'd (the positive control)");
    trial(ASKED_BEFORE, "control: the token asked at the receipt too, then the maker writes a request and execs");
    trial(A_WRITES, "(a) a forked child of the maker writes on the maker's end; the maker execs; then the token");
    trial(A_WRITES_READS, "(a) a forked child of the maker writes and reads on the maker's end; the maker execs; then the token");
    trial(B_KEEPER, "(b) the maker writes a request and execs; the keeper reads and writes on its end; the token after each");
    trial(C_THIRD, "(c) KP10: the maker writes a request, gives a copy of its end to a third process, execs; the keeper answers; the third reads it");
    trial_d(folder);
    trial_e(OPEN, "(e) baseline: the other end open");
    trial_e(SHUT_WRITE, "(e) the other end half-closed: shutdown(SHUT_WR)");
    trial_e(CLOSED, "(e) the other end closed");
    trial_e(SHUT_READ_FORMER, "(e) a former holder's shutdown(SHUT_RD)");
    trial_f(0, "(f) a connection: the connector writes, then its forked child holding a copy writes last");
    trial_f(1, "(f) a connection: the connector writes, its forked child writes, the connector writes last");
    if (image) part_two();
    unlink(argv[1]);
    if (argc == 7) {
        third_part_images(argv + 3);
        part_three();
    }
    return 0;
}
