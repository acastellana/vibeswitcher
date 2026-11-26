#!/bin/bash
# scripts/ci/check-versions.sh TOOL...: says each TOOL's version (node, chrome) and fails, one line a tool, when its major
# isn't in the range scripts/ci/checked-versions.txt gives it: the page tests and the browser checks run on what the
# runner image has, which moves on by itself, so a major they never passed on stops the job instead of being trusted.
# Exit 1 on a major out of range, a tool that isn't there or a range the file doesn't give; 2 on a bad call.
# VERSIONS=FILE: another file, and NODE=…/CHROME=… another program (this script's own checks).
set -uo pipefail
cd "$(dirname "$0")/../.."

file=${VERSIONS:-scripts/ci/checked-versions.txt}
(( $# >= 1 )) || { echo "usage: scripts/ci/check-versions.sh node|chrome..."; exit 2; }
[[ -f $file ]] || { echo "no $file"; exit 1; }

status=0
for tool in "$@"; do
    range=$(awk -v tool="$tool" '$1 == tool && NF == 2 { print $2 }' "$file")
    if [[ ! $range =~ ^([0-9]+)-([0-9]+)$ ]] || (( 10#${BASH_REMATCH[1]} > 10#${BASH_REMATCH[2]} )); then
        echo "$tool: $file gives no range of majors for it (wanted a line \"$tool LOW-HIGH\")"
        status=1
        continue
    fi
    low=$(( 10#${BASH_REMATCH[1]} )) high=$(( 10#${BASH_REMATCH[2]} ))
    case $tool in
        node) said=$(${NODE:-node} --version 2>&1) ;;
        chrome) said=$(${CHROME:-google-chrome} --version 2>&1) ;;
        *) echo "$tool: not a tool this checks (node, chrome)"; exit 2 ;;
    esac
    # "v24.22.3" (node), "Google Chrome 157.0.8103.78" (chrome): the first number.
    if [[ ! $said =~ (^|[^0-9.])v?([0-9]+)\.[0-9]+ ]]; then
        echo "$tool: no version read (it said: ${said:0:200})"
        status=1
        continue
    fi
    major=$(( 10#${BASH_REMATCH[2]} ))
    if (( major < low || major > high )); then
        echo "$tool $said: major $major isn't one the checks passed on ($low to $high, $file)."
        echo "  Run them on it, and widen the range in $file once they pass."
        status=1
    else
        echo "$tool $said (majors $low to $high checked)"
    fi
done
exit $status
