#!/bin/bash
# How many vsh-* entries (the sockets and locks tests used to leave) are directly in /tmp: their count, the last
# line. Read-only: it lists, it never makes or removes anything. Run it before and after a full scripts/test.sh;
# the count shouldn't grow (tests put sockets in a Scratch.shortFolder, removed with the test).
#
# scripts/tmp-socket-count.sh [-v]   -v: each entry's name first, one a line.
set -uo pipefail
shopt -s nullglob
entries=(/tmp/vsh-*)
[[ ${1:-} == -v ]] && for entry in "${entries[@]}"; do echo "$entry"; done
echo "${#entries[@]}"
