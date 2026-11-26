// One entry in the unified log under SUBSYSTEM (a throwaway one of the measurement's, never dev.vibeswitcher.node),
// carrying NONCE, so `log show` can find it and say which image logd stamped it with (processImagePath,
// senderImagePath): the design's step 6 measurement, whether a process can write under another image's name.
//
//   oslog SUBSYSTEM NONCE
#include <os/log.h>
#include <stdio.h>

#ifdef FORGER
// The forger's own code: a program that isn't oslog (other bytes, another cdhash), built from this file so its format
// string is the same; its LC_UUID is then set to oslog's (patch-uuid.py).
static void forger_only(void) { fprintf(stderr, "a different program: the forger\n"); }
#endif

int main(int argc, char **argv) {
#ifdef FORGER
    forger_only();
#endif
    if (argc != 3) { fprintf(stderr, "usage: oslog SUBSYSTEM NONCE\n"); return 64; }
    os_log_t log = os_log_create(argv[1], "measure");
    os_log(log, "measure %{public}s", argv[2]);
    return 0;
}
