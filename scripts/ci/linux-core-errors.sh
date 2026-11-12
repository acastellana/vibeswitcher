#!/bin/bash
# scripts/ci/linux-core-errors.sh [TARGET]: how far a target is from compiling on Linux: by default VibeHost, the first
# of those that don't yet (VibeCore, the hook and the tool server do since 2026-11-12, and are in the default build);
# vibeswitcher-host once VibeHost compiles. Builds it there with VIBE_LINUX_ALL=1
# (Package.swift: every portable target, those that don't compile yet too) and the compiler told to go on after an
# error, then prints the number of errors, each counted once by its file, line, column and message (the build names
# one for each command that met it), and the number in each file, most first. Exit 0 with the count, whatever it is;
# 1 when nothing could be counted (not Linux, or a build that failed before it compiled a file).
#
# The compiler stops at the first module it can't find ("no such module 'ImageIO'") and checks nothing else, in any
# file. So each module it misses is given an empty stand-in for this build (in the scratch folder, on the import
# path) and the build is run again, until it misses none: what the module would have declared then shows as errors of
# its own ("cannot find 'SecItemAdd' in scope"). The stand-ins are named in the output, each an import still to go.
# CryptoKit gets none: Sources/VibeCore/PlatformExport.swift asks whether it can be imported and exports swift-crypto
# where it can't, so an `import CryptoKit` left in a file stays the one error it is.
#
# Package.resolved is left as it was found: the build takes its pins as they are, and the file is put back if it
# changed all the same.
set -uo pipefail
cd "$(dirname "$0")/../.."

target=${1:-VibeHost}
[[ $(uname -s) == Linux ]] || { echo "scripts/ci/linux-core-errors.sh counts what Linux's compiler says: this is $(uname -s)"; exit 1; }

source scripts/lib/scratch.sh
source scripts/lib/swift-jobs.sh

scratch_tmpdir vs-errors
cp Package.resolved "$tool_scratch/Package.resolved" || exit 1
on_exit 'cmp -s "$tool_scratch/Package.resolved" Package.resolved || cp "$tool_scratch/Package.resolved" Package.resolved'

export target VIBE_LINUX_ALL=1 stand_ins=$tool_scratch/stand-ins log=$tool_scratch/build.log
mkdir "$stand_ins" || exit 1
: > "$tool_scratch/empty.swift"
made=()
while :; do
    # A build on every core for as long as it compiles: in a slot, on the slot's share (Resources/bin/vs-heavy).
    Resources/bin/vs-heavy --as scripts/ci/linux-core-errors.sh bash -c 'heavy_swift build --force-resolved-versions --target "$target" -Xswiftc -continue-building-after-errors -Xswiftc -I -Xswiftc "$stand_ins" > "$log" 2>&1'
    status=$?
    again=""
    for module in $(sed -nE "s/.*error: no such module '([A-Za-z0-9_]+)'.*/\1/p" "$log" | sort -u); do
        [[ $module == CryptoKit || -e $stand_ins/$module.swiftmodule ]] && continue
        swiftc -emit-module -parse-as-library -module-name "$module" -emit-module-path "$stand_ins/$module.swiftmodule" "$tool_scratch/empty.swift" || exit 1
        made+=("$module")
        again=1
    done
    [[ -n $again ]] || break
done

errors=$tool_scratch/errors
grep -E '^/[^:]+:[0-9]+:[0-9]+: error: ' "$log" | sort -u > "$errors"
total=$(wc -l < "$errors" | tr -d ' ')
if (( total == 0 )); then
    if (( status == 0 )); then
        echo "$target on Linux: 0 errors, it compiles"
        exit 0
    fi
    echo "$target on Linux: the build failed (exit $status) and named no error in a file. Its last lines:"
    tail -n 20 "$log"
    exit 1
fi
files=$(sed -E 's/:[0-9]+:[0-9]+: error: .*//' "$errors" | sort | uniq -c | sort -k1,1nr -k2)
echo "$target on Linux: $total errors in $(echo "$files" | wc -l | tr -d ' ') files"
if (( ${#made[@]} > 0 )); then
    echo "modules Linux doesn't have that a file still imports (an empty stand-in each, for this count): ${made[*]}"
fi
if grep -q "error: no such module" "$errors"; then
    echo "the compiler stopped at a module it couldn't find and checked nothing else:"
    grep "error: no such module" "$errors" | sed "s|^$PWD/|  |"
fi
echo "$files" | sed "s| $PWD/| |"
exit 0
