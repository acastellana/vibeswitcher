// Item 3 and item 7 of "Before approvalMeasured flips": the connect-write-exec race. A child connects to this process's
// Unix socket, then execs another program. Is the audit token read at the accept (LOCAL_PEERTOKEN) still vouched for
// by Security after the exec, and as which code? Only this process's own child, and nothing but reads of it.
//
//   token-exec SOCKET_PATH PROGRAM   (the child, still this program's image, connects, then execs PROGRAM, a build of the
//                                     caller's that takes --sleep SECONDS)
#include <Security/Security.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

static void describe(const char *when, audit_token_t token) {
    CFDataRef data = CFDataCreate(NULL, (const UInt8 *)&token, sizeof token);
    const void *keys[] = {kSecGuestAttributeAudit};
    const void *values[] = {data};
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SecCodeRef code = NULL;
    OSStatus status = SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &code);
    printf("%s: SecCodeCopyGuestWithAttributes=%d", when, (int)status);
    if (status == errSecSuccess && code) {
        OSStatus valid = SecCodeCheckValidity(code, kSecCSDefaultFlags, NULL);
        CFDictionaryRef info = NULL;
        SecCodeCopySigningInformation((SecStaticCodeRef)code, kSecCSDynamicInformation, &info);
        CFDataRef cdhash = info ? CFDictionaryGetValue(info, kSecCodeInfoUnique) : NULL;
        printf(" SecCodeCheckValidity=%d cdhash=", (int)valid);
        if (cdhash) for (CFIndex i = 0; i < CFDataGetLength(cdhash) && i < 8; i++) printf("%02x", CFDataGetBytePtr(cdhash)[i]);
        else printf("none");
        if (info) CFRelease(info);
        CFRelease(code);
    }
    printf("\n");
    CFRelease(attributes);
    CFRelease(data);
}

static void cdhash_of_file(const char *label, const char *path) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    SecStaticCodeRef code = NULL;
    CFDictionaryRef info = NULL;
    if (SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &code) == errSecSuccess &&
        SecCodeCopySigningInformation(code, kSecCSDefaultFlags, &info) == errSecSuccess) {
        CFDataRef cdhash = CFDictionaryGetValue(info, kSecCodeInfoUnique);
        printf("%s file cdhash=", label);
        for (CFIndex i = 0; cdhash && i < CFDataGetLength(cdhash) && i < 8; i++) printf("%02x", CFDataGetBytePtr(cdhash)[i]);
        printf("\n");
    }
    if (info) CFRelease(info);
    if (code) CFRelease(code);
    CFRelease(url);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc != 3) { fprintf(stderr, "usage: token-exec SOCKET_PATH PROGRAM\n"); return 64; }
    char self[4096];
    extern int proc_pidpath(int, void *, uint32_t);
    if (proc_pidpath(getpid(), self, sizeof self) > 0) cdhash_of_file("this program's", self);
    cdhash_of_file("PROGRAM's", argv[2]);
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    if (strlen(argv[1]) >= sizeof address.sun_path) { fprintf(stderr, "socket path too long\n"); return 1; }
    strcpy(address.sun_path, argv[1]);
    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    unlink(argv[1]);
    if (bind(listener, (struct sockaddr *)&address, sizeof address) != 0 || listen(listener, 1) != 0) { perror("bind/listen"); return 1; }
    int go[2];
    if (pipe(go) != 0) { perror("pipe"); return 1; }
    pid_t child = fork();
    if (child == 0) {
        // The child: connect as this program's image, write, wait for the word, then exec PROGRAM.
        close(go[1]);
        int s = socket(AF_UNIX, SOCK_STREAM, 0);
        if (connect(s, (struct sockaddr *)&address, sizeof address) != 0) _exit(2);
        write(s, "hello\n", 6);
        char byte;
        read(go[0], &byte, 1);
        execl(argv[2], argv[2], "--sleep", "5", (char *)NULL);
        _exit(127);
    }
    close(go[0]);
    int peer = accept(listener, NULL, NULL);
    audit_token_t token;
    socklen_t size = sizeof token;
    if (getsockopt(peer, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) != 0) { perror("LOCAL_PEERTOKEN"); return 1; }
    printf("child=%d (forked: still this program's image)\n", child);
    describe("before exec", token);
    write(go[1], "x", 1);
    // Waits for the exec: the child's path becomes PROGRAM's (a read of its own child), 2 s at most.
    char path[4096] = "";
    for (int i = 0; i < 400; i++) {
        if (proc_pidpath(child, path, sizeof path) > 0 && strcmp(path, argv[2]) == 0) break;
        usleep(5000);
    }
    printf("child now runs %s\n", path);
    describe("after exec, the token read at the accept", token);
    kill(child, SIGTERM);
    waitpid(child, NULL, 0);
    describe("after the child ended", token);
    unlink(argv[1]);
    return 0;
}
