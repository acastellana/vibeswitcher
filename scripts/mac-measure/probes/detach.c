// The escape a session's process can make without any app's help: fork, setsid (no controlling terminal, a POSIX
// session of its own), fork again so launchd (pid 1) becomes the parent, then exec COMMAND. Prints the grandchild's pid
// on stdout and exits once it has started (a pipe closed by the exec tells it so: no sleep).
//
//   detach COMMAND [ARGS…]
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: detach COMMAND [ARGS...]\n"); return 64; }
    int started[2];
    if (pipe(started) != 0) { perror("pipe"); return 1; }
    pid_t first = fork();
    if (first < 0) { perror("fork"); return 1; }
    if (first == 0) {
        if (setsid() < 0) _exit(2);
        pid_t second = fork();
        if (second < 0) _exit(3);
        if (second > 0) {
            dprintf(STDOUT_FILENO, "%d\n", second);
            _exit(0);
        }
        close(started[0]);
        fcntl(started[1], F_SETFD, FD_CLOEXEC);
        int null = open("/dev/null", O_RDWR);
        if (null >= 0) { dup2(null, STDIN_FILENO); dup2(null, STDOUT_FILENO); }
        execvp(argv[1], argv + 1);
        _exit(127);
    }
    close(started[1]);
    int status = 0;
    waitpid(first, &status, 0);
    char byte;
    // Returns 0 at the exec (close-on-exec closed the last writer).
    while (read(started[0], &byte, 1) > 0) {}
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
