#!/bin/bash
# Lists the last merges VibeSwitcher landed, from git log alone: each one's commit, date, task, review, models, the
# build of the tool server that merged it, its contract's hash and its worker's Claude Code version, as the trailers
# merge put on it (VS-Task, VS-Review, VS-Worker-Model, VS-Verifier-Model, VS-Build, VS-Contract, VS-CLI; - for a merge from before one). Read-only.
#
# scripts/merge-provenance.sh [-n N] [--build PREFIX] [--model TEXT] [--repo DIR] [REV]
#   -n N            the last N merges (default 20; 0: all)
#   --build PREFIX  only merges by a build whose commit starts with PREFIX
#   --model TEXT    only merges whose worker or verifier model contains TEXT
#   --repo DIR      the repository (default: the current folder's)
#   REV             where to read history from (default HEAD); every commit reachable from it counts, a true
#                   merge's other side too, so another Mac's merges carried in show as well
#
# Prints a header, then one tab-separated line per merge, newest first:
#   commit  date  task  review  worker  verifier  build  contract  cli
set -euo pipefail

count=20
build=""
model=""
repo="."
rev="HEAD"
usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }
while (($#)); do
    case "$1" in
        -n) count="${2:?-n needs a number}"; shift 2 ;;
        --build) build="${2:?--build needs a commit prefix}"; shift 2 ;;
        --model) model="${2:?--model needs a name}"; shift 2 ;;
        --repo) repo="${2:?--repo needs a folder}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "merge-provenance: unknown option $1" >&2; usage >&2; exit 2 ;;
        *) rev="$1"; shift ;;
    esac
done
[[ $count =~ ^[0-9]+$ ]] || { echo "merge-provenance: -n takes a number, not '$count'" >&2; exit 2; }
git -C "$repo" rev-parse --verify --quiet "$rev^{commit}" >/dev/null || { echo "merge-provenance: no commit $rev in $repo" >&2; exit 2; }

# One field per trailer, its value only (several of a key joined with ", "), records apart by RS, fields by US.
field() { printf '%%(trailers:key=%s,valueonly,separator=%%x2C%%x20)' "$1"; }
format="%H%x1f%cs%x1f$(field VS-Task)%x1f$(field VS-Review)%x1f$(field VS-Worker-Model)%x1f$(field VS-Verifier-Model)%x1f$(field VS-Build)%x1f$(field VS-Contract)%x1f$(field VS-CLI)%x1e"

printf 'commit\tdate\ttask\treview\tworker\tverifier\tbuild\tcontract\tcli\n'
shown=0
while IFS=$'\x1f' read -r -d $'\x1e' commit date task review worker verifier made contract cli; do
    commit="${commit#$'\n'}"
    [[ -n $task ]] || continue
    [[ -z $build || $made == "$build"* ]] || continue
    [[ -z $model || $worker == *"$model"* || $verifier == *"$model"* ]] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${commit:0:12}" "$date" "$task" "$review" "${worker:--}" "${verifier:--}" "${made:--}" "${contract:--}" "${cli:--}"
    shown=$((shown + 1))
    ((count == 0 || shown < count)) || break
done < <(git -C "$repo" log --format="$format" "$rev")
