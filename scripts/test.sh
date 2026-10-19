#!/bin/bash
# `swift build && swift test "$@"` on a fresh scratch home, so nothing a test writes reaches your ~/.vibeswitcher,
# ~/.claude or login Keychain. HOME, CFFIXED_USER_HOME (what NSHomeDirectory() follows; HOME alone doesn't move it),
# VIBESWITCHER_HOME and TMPDIR all point into a folder this creates under /tmp and removes when it exits, Ctrl-C too.
# A plain `swift test` on your own home refuses to start (see `VibePaths.testRefusal`).
#
# scripts/test.sh [swift test options], e.g. scripts/test.sh --filter HomeIsolationTests
set -uo pipefail
cd "$(dirname "$0")/.."

# Short: host tests put sockets under TMPDIR, and a socket's path is limited to 104 bytes.
scratch=$(mktemp -d /tmp/vs-test.XXXXXX) || { echo "can't make a scratch folder under /tmp"; exit 1; }
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/home" "$scratch/tmp" || exit 1

export HOME=$scratch/home CFFIXED_USER_HOME=$scratch/home VIBESWITCHER_HOME=$scratch/home/.vibeswitcher TMPDIR=$scratch/tmp/
swift build && swift test "$@"
