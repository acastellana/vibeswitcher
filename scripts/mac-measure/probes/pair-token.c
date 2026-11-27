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
//   pair-token SOCKET_PATH PROGRAM   (PROGRAM: a hardened image taking --sleep SECONDS, the maker's exec target)
#include <Security/Security.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach/mach.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

typedef struct { pid_t pid; int version; } who_t;

static const char *program;
static char *program_real;  // PROGRAM's path with its links resolved (/tmp is /private/tmp), as proc_pidpath gives it
static struct sockaddr_un address = {.sun_family = AF_UNIX};
static int listener = -1;
static CFDataRef own_file_cdhash, program_cdhash;

// Who the trial's processes are, for the labels.
static who_t keeper, maker, child, third;
static int have_child, have_third;

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
    if (have_child && same(w, child)) return "the maker's forked child";
    if (have_third && same(w, third)) return "the third process";
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
        int hardened = (flags & 0x1) && (flags & 0x10000) && !(flags & (0x4 | 0x10000000));
        printf(" hardened=%s", word ? (hardened ? "yes" : "no") : "unread");
        if (info) CFRelease(info);
        CFRelease(code);
    }
    CFRelease(attributes);
    CFRelease(data);
}

// The token of `fd`'s peer, asked now (a fresh getsockopt each time), labelled, with Security's answer.
static void token(const char *when, int fd) {
    audit_token_t token;
    socklen_t size = sizeof token;
    printf("  %s: LOCAL_PEERTOKEN ", when);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) != 0) {
        printf("refused errno=%d (%s)\n", errno, strerror(errno));
        return;
    }
    who_t w = of(token);
    printf("pid=%d pidversion=%d = %s", w.pid, w.version, label(w));
    pid_t peer = 0;
    size = sizeof peer;
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &size) == 0) printf(" | LOCAL_PEERPID=%d", peer);
    else printf(" | LOCAL_PEERPID refused errno=%d", errno);
    security(token);
    printf("\n");
}

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
    if (kind == ASKED_BEFORE) token("asked at the receipt, before the exec (this control only)", end);
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

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc != 3) { fprintf(stderr, "usage: pair-token SOCKET_PATH PROGRAM\n"); return 64; }
    signal(SIGPIPE, SIG_IGN);
    program = argv[2];
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
    unlink(argv[1]);
    return 0;
}
