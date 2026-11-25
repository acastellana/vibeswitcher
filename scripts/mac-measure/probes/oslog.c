// One entry in the unified log under SUBSYSTEM (a throwaway one of the measurement's, never dev.vibeswitcher.node),
// carrying NONCE, so `log show` can find it and say which image logd stamped it with (processImagePath,
// senderImagePath): the design's step 6 measurement, whether a process can write under another image's name.
//
//   oslog SUBSYSTEM NONCE
#include <os/log.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: oslog SUBSYSTEM NONCE\n"); return 64; }
    os_log_t log = os_log_create(argv[1], "measure");
    os_log(log, "measure %{public}s", argv[2]);
    return 0;
}
