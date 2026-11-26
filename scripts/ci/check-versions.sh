#!/bin/bash
# scripts/ci/check-versions.sh TOOL...: says each TOOL's version and fails, one line a tool, when it isn't one the
# checks were made with. swift: exactly .swift-version (the Mac's jobs take the image's Xcode, which brings its own;
# Linux's install it, or take the image's when it already says that version). node, chrome: a major in the range
# scripts/ci/checked-versions.txt gives it (the page tests and the browser checks run on what the runner image has,
# which moves on by itself, so a major they never passed on stops the job instead of being trusted).
# Exit 1 on a version out of range, a tool that isn't there or a range the file doesn't give; 2 on a bad call.
# VERSIONS=FILE and SWIFT_VERSION_FILE=FILE: other files, and SWIFT=…/NODE=…/CHROME=… another program (this script's
# own checks).
set -uo pipefail
cd "$(dirname "$0")/../.."

file=${VERSIONS:-scripts/ci/checked-versions.txt}
(( $# >= 1 )) || { echo "usage: scripts/ci/check-versions.sh swift|node|chrome..."; exit 2; }
[[ -f $file ]] || { echo "no $file"; exit 1; }

status=0
for tool in "$@"; do
    if [[ $tool == swift ]]; then
        wanted=$(cat "${SWIFT_VERSION_FILE:-.swift-version}" 2> /dev/null)
        said=$(${SWIFT:-swift} --version 2>&1)
        if [[ -n $wanted && $said == *"Swift version $wanted "* ]]; then
            echo "swift: $wanted, as .swift-version says"
        else
            echo "swift: not ${wanted:-(no .swift-version)}, the version .swift-version names: ${said:0:300}"
            status=1
        fi
        continue
    fi
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
        *) echo "$tool: not a tool this checks (swift, node, chrome)"; exit 2 ;;
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
