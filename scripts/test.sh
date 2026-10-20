#!/bin/bash
# `swift build && swift test "$@"` on a fresh scratch home, so nothing a test writes reaches your ~/.vibeswitcher,
# ~/.claude or login Keychain. HOME, CFFIXED_USER_HOME (what NSHomeDirectory() follows; HOME alone doesn't move it),
# VIBESWITCHER_HOME and TMPDIR all point into a folder this creates under /tmp and removes when it exits, Ctrl-C too
# (scripts/lib/scratch.sh).
# A plain `swift test` on your own home refuses to start (see `VibePaths.testRefusal`).
#
# scripts/test.sh [swift test options], e.g. scripts/test.sh --filter HomeIsolationTests
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/scratch.sh

scratch_tmpdir vs-test
mkdir -p "$tool_scratch/home" || exit 1

export HOME=$tool_scratch/home CFFIXED_USER_HOME=$tool_scratch/home VIBESWITCHER_HOME=$tool_scratch/home/.vibeswitcher
swift build && swift test "$@"
