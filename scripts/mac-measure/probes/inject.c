// A library that, if dyld loads it (DYLD_INSERT_LIBRARIES), writes the path named by MEASURE_INJECTED: the marker of
// an injection that worked. The measurement of the Hardened Runtime's DYLD_* refusal (item 3 of "Before
// approvalMeasured flips") loads it into copies of a program the measurement built itself, never into anything else.
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>

__attribute__((constructor)) static void injected(void) {
    const char *marker = getenv("MEASURE_INJECTED");
    if (!marker) return;
    int fd = open(marker, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd >= 0) { write(fd, "injected\n", 9); close(fd); }
}
