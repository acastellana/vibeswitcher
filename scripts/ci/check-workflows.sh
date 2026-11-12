#!/bin/bash
# scripts/ci/check-workflows.sh: every workflow under .github/workflows/ runs for pushes to v2 and by hand, and for
# nothing else; reads the repository and nothing more; uses only the two actions named below, by commit; bounds every
# job's time (under 100 minutes); names no secret; has no expression outside its concurrency group; runs on GitHub's
# own runners. One line a failure, exit 1; "no workflows" and exit 1 when there are none. The Ubuntu workflow runs it
# first, so a workflow widened by accident fails its own run. A lint, not a boundary: it lives in the commit it
# checks.
set -uo pipefail
cd "$(dirname "$0")/../.."

allowed_actions=(
    "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"        # v7.0.1
    "actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9" # v7.0.2
)

# The lines of the top-level block that starts at "$2:" in file $1, without indentation, blank lines or comments.
block() {
    awk -v key="$2:" '
        $0 == key { inside = 1; print; next }
        inside && /^[^ #]/ { exit }
        inside { sub(/^ +/, ""); sub(/ +#.*$/, ""); if ($0 != "" && $0 !~ /^#/) print }
    ' "$1"
}

status=0
fail() { echo "$1: $2"; status=1; }

shopt -s nullglob dotglob
files=(.github/workflows/*.yml .github/workflows/*.yaml)
if (( ${#files[@]} == 0 )); then
    echo "no workflows"
    exit 1
fi

for file in "${files[@]}"; do
    [[ $(block "$file" on) == $'on:\npush:\nbranches: [v2]\nworkflow_dispatch:' ]] \
        || fail "$file" "on: must be exactly a push to v2 and workflow_dispatch"
    [[ $(block "$file" permissions) == $'permissions:\ncontents: read' ]] \
        || fail "$file" "permissions: must be exactly contents: read"
    # A job's own permissions: would override the file's.
    (( $(grep -cE "permissions[\"' ]*:" "$file") == 1 )) || fail "$file" "permissions: may appear once, at the top"
    while IFS= read -r action; do
        found=""
        for allowed in "${allowed_actions[@]}"; do [[ $action == "$allowed" ]] && found=1; done
        [[ -n $found ]] || fail "$file" "uses $action, which isn't one of the pinned actions"
    done < <(grep -E '^ +(- )?uses: ' "$file" | sed -E 's/^ +(- )?uses: +//; s/ +#.*$//')
    # Every uses: is in the one form read above (not quoted, not in a flow mapping, not oddly spaced).
    (( $(grep -cE "uses[\"' ]*:" "$file") == $(grep -cE '^ +(- )?uses: [^ ]+( +#.*)?$' "$file") )) \
        || fail "$file" "uses: in a form this check doesn't read"
    jobs=$(awk '/^jobs:/ { inside = 1; next } inside && /^[^ #]/ { exit } inside && /^  [A-Za-z0-9_-]+:/ { n++ } END { print n + 0 }' "$file")
    timeouts=$(grep -cE '^    timeout-minutes: [0-9]{1,2}$' "$file")
    (( jobs >= 1 && jobs == timeouts )) || fail "$file" "$jobs job(s) and $timeouts timeout-minutes: every job needs one"
    grep -qi 'secrets' "$file" && fail "$file" "names a secret"
    # No expression but the concurrency group's: one in a run: line would run text a commit can choose.
    grep -F '${{' "$file" | grep -qvE '^  group: v2-[a-z]+-\$\{\{ github\.ref \}\}$' \
        && fail "$file" "an expression outside concurrency.group"
    grep -qE '^ *(container|services|runs-on: .*self-hosted)' "$file" && fail "$file" "a container, a service or a self-hosted runner"
done
exit $status
