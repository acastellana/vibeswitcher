// Terminals, sockets, pairs and pipes made close-on-exec from the call that makes them, and a terminal's controlling
// session: what Swift can't reach through Glibc's or Musl's module because the C library shows it only under
// `_GNU_SOURCE` or `_XOPEN_SOURCE` (pipe2, accept4, posix_openpt, grantpt, unlockpt), names it through a type Swift
// imports differently on each (SOCK_CLOEXEC, an enum to Swift on glibc), or reaches it only through ioctl, which
// takes a variable list of arguments. Included by CVibePlatform.h; tied to the system's in shim_terminals.c.
#ifndef CVIBEPLATFORM_TERMINALS_H
#define CVIBEPLATFORM_TERMINALS_H
#ifdef __linux__

#include <sys/types.h>

// A new pseudo-terminal's master: posix_openpt(flags), then grantpt and unlockpt, so its slave can be opened. -1 and
// errno, with nothing left open, as the calls.
int vibe_openpt(int flags);

// TIOCSCTTY: the terminal `fd` becomes the controlling terminal of the calling process, which must lead a session
// that has none. 0, or the error number.
int vibe_make_controlling(int fd);

// TIOCGSID: the session whose controlling terminal the terminal of `fd` is; given a pseudo-terminal's master, its
// slave's, whoever asks. 0 and `session` filled, or the error number (ENOTTY: no session has it).
int vibe_terminal_session(int fd, pid_t *session);

// TIOCSWINSZ and TIOCGWINSZ: a terminal's size in rows and columns. 0, or the error number.
int vibe_terminal_set_size(int fd, unsigned short rows, unsigned short cols);
int vibe_terminal_size(int fd, unsigned short *rows, unsigned short *cols);

// socket(AF_UNIX, type | SOCK_CLOEXEC, 0). -1 and errno, as the call.
int vibe_socket_cloexec(int type);

// socketpair(AF_UNIX, type | SOCK_CLOEXEC, 0, fds). -1 and errno, as the call.
int vibe_socketpair_cloexec(int type, int fds[2]);

// accept4(fd, NULL, NULL, SOCK_CLOEXEC). -1 and errno, as the call.
int vibe_accept_cloexec(int fd);

// pipe2(fds, O_CLOEXEC). -1 and errno, as the call.
int vibe_pipe_cloexec(int fds[2]);

#endif
#endif
