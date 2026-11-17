#!/bin/bash
# Does this macOS give freed malloc memory back? (MallocMode.swift, 2026-11-17.) On macOS 27.2 a process that frees
# 200 MB of 40 KB blocks keeps all of it in its footprint, and malloc_zone_pressure_relief gives back 0 bytes; with
# MallocLargeCache=0 in the environment from launch it's given back as it's freed. A small C program, built in a scratch
# folder, run with each setting: the footprint (phys_footprint, MB) with the blocks in use, freed, and after a relief;
# then an app-like churn (200,000 live blocks of 16 B-64 KB, 4 million frees), its time and footprint.
# Recheck after a macOS update: when the default's "freed" comes back down, MallocMode's relaunch can go.
#
# scripts/malloc-relief-repro.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/scratch.sh
scratch_tmpdir malloc-relief

cat >"$tool_scratch/relief.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <malloc/malloc.h>
#include <mach/mach.h>
static double fp(void) {
    task_vm_info_data_t info; mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    return info.phys_footprint / 1048576.0;
}
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static void freed(size_t size) {
    int n = (int)(200.0 * 1048576 / size);
    void **blocks = malloc(n * sizeof(void *));
    for (int i = 0; i < n; i++) { blocks[i] = malloc(size); memset(blocks[i], 1, size); }
    double used = fp();
    for (int i = 0; i < n; i++) free(blocks[i]);
    double after = fp();
    size_t given = malloc_zone_pressure_relief(NULL, 0);
    printf("  %6zu B blocks: in use %6.1f MB, freed %6.1f MB, relief gave %zu bytes: %6.1f MB\n", size, used, after, given, fp());
    free(blocks);
}
int main(void) {
    freed(256); freed(4000); freed(40000);
    enum { LIVE = 200000 }; static void *live[LIVE]; unsigned s = 1;
    double started = now();
    for (long i = 0; i < 4000000; i++) {
        s = s * 1103515245 + 12345; int k = s % LIVE; free(live[k]);
        unsigned r = (s >> 8) % 1000;
        size_t size = r < 900 ? 16 + (s >> 4) % 240 : r < 990 ? 256 + (s >> 4) % 4000 : 4096 + (s >> 4) % 61440;
        live[k] = malloc(size); ((char *)live[k])[0] = 1;
    }
    double took = now() - started, working = fp();
    for (int k = 0; k < LIVE; k++) free(live[k]);
    printf("  churn: %.2f s, working footprint %.1f MB, all freed %.1f MB\n", took, working, fp());
    return 0;
}
EOF
clang -O2 -o "$tool_scratch/relief" "$tool_scratch/relief.c"
echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "default malloc:"
env -u MallocLargeCache "$tool_scratch/relief"
echo "MallocLargeCache=0 (what the app starts with, MallocMode.swift):"
MallocLargeCache=0 "$tool_scratch/relief"
