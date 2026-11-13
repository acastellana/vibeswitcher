// CVibePlatform_terminals.h's names, tied to the system's own. Compiled under `_GNU_SOURCE`, as shim.c is, which
// shows pipe2, accept4 and posix_openpt on glibc and on musl.
#ifdef __linux__
#define _GNU_SOURCE
#include "CVibePlatform.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <termios.h>
#include <unistd.h>

int vibe_openpt(int flags) {
    int master = posix_openpt(flags);
    if (master < 0) return -1;
    if (grantpt(master) != 0 || unlockpt(master) != 0) {
        int code = errno;
        close(master);
        errno = code;
        return -1;
    }
    return master;
}

int vibe_make_controlling(int fd) {
    return ioctl(fd, TIOCSCTTY, 0) == 0 ? 0 : errno;
}

int vibe_terminal_session(int fd, pid_t *session) {
    pid_t found = 0;
    if (ioctl(fd, TIOCGSID, &found) != 0) return errno;
    *session = found;
    return 0;
}

int vibe_terminal_set_size(int fd, unsigned short rows, unsigned short cols) {
    struct winsize size = { .ws_row = rows, .ws_col = cols };
    return ioctl(fd, TIOCSWINSZ, &size) == 0 ? 0 : errno;
}

int vibe_terminal_size(int fd, unsigned short *rows, unsigned short *cols) {
    struct winsize size = { 0 };
    if (ioctl(fd, TIOCGWINSZ, &size) != 0) return errno;
    *rows = size.ws_row;
    *cols = size.ws_col;
    return 0;
}

int vibe_socket_cloexec(int type) {
    return socket(AF_UNIX, type | SOCK_CLOEXEC, 0);
}

int vibe_socketpair_cloexec(int type, int fds[2]) {
    return socketpair(AF_UNIX, type | SOCK_CLOEXEC, 0, fds);
}

int vibe_accept_cloexec(int fd) {
    return accept4(fd, NULL, NULL, SOCK_CLOEXEC);
}

int vibe_pipe_cloexec(int fds[2]) {
    return pipe2(fds, O_CLOEXEC);
}
#endif
