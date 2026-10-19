#!/bin/bash
# The tests under Tests/ that use the system temporary folder themselves (FileManager's temporaryDirectory,
# NSTemporaryDirectory(), a /tmp or /private/tmp path) instead of scratchRoot: every run on this Mac shares that
# folder, and what a test leaves there is never checked. One "file:line:code" per use and exit 1; nothing and exit 0.
# The rules are scripts/temporary-folder-lint.txt: its patterns, and the uses allowed, each with its reason.
# scripts/test-under-load.sh refuses to start when this finds any, and TemporaryFolderLintTests fails on the same
# lines in a normal run (it reads the same list, and checks this script names what it names).
#
# scripts/temporary-folder-lint.sh [ROOT]   ROOT: the folder whose Tests/ it reads (this repository).
set -uo pipefail
list=$(cd "$(dirname "$0")" && pwd)/temporary-folder-lint.txt
cd "${1:-$(dirname "$0")/..}" || exit 2

patterns=()
while IFS= read -r line; do
    [[ $line == "pattern: "* ]] && patterns+=(-e "${line#pattern: }")
done < "$list"
[[ ${#patterns[@]} -gt 0 ]] || { echo "no patterns in $list"; exit 2; }
# A pattern grep can't read would find nothing, and pass.
grep -qE "${patterns[@]}" /dev/null; [[ $? -le 1 ]] || { echo "a pattern in $list isn't an extended regular expression"; exit 2; }

# Comment lines name these, they don't use them. An allowed use: its file, and its text somewhere on the line.
found=$(grep -rnE "${patterns[@]}" Tests --include='*.swift' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' | awk -v list="$list" '
    BEGIN {
        n = 0
        while ((getline entry < list) > 0) {
            if (entry !~ /^allow: /) continue
            sub(/^allow: /, "", entry)
            split(entry, field, / \| /)
            file[n] = field[1]; text[n] = field[2]; n++
        }
    }
    {
        path = $0; sub(/:.*/, "", path)
        code = $0; sub(/^[^:]+:[0-9]+:/, "", code)
        for (i = 0; i < n; i++) if (path == file[i] && index(code, text[i])) next
        print
    }' | sort -t: -k1,1 -k2,2n)
[[ -z $found ]] && exit 0
echo "$found"
exit 1
