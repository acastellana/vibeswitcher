#!/bin/bash
# UI journeys: short scripts of sandbox commands that end in named shots, each shot compared with a stored baseline, to
# catch a UI change nobody meant before the user sees it. Each journey runs in a fresh sandbox of its own
# (scripts/sandbox-app.sh, built from this worktree, fake sessions only, off screen; its own --dir, so a sandbox you are
# driving by hand here is left alone), which is quit when the journey ends.
#
# scripts/ui-journeys.sh [options] run [JOURNEY…]   runs the journeys (all of them when none is named) and compares
#                                                   each shot with its baseline; a shot with no baseline yet becomes it
# scripts/ui-journeys.sh accept JOURNEY…            takes the last run's shots of each journey as its new baselines
# scripts/ui-journeys.sh list                       names every journey with its one-line description
#
# Exits 0 when every shot is unchanged (within the threshold) or new; 1 when one changed or a journey failed; 64 on a
# wrong command line.
#
# Options (run): --threshold PERCENT  a shot counts as changed when more than this share of its pixels differ (0.05)
#                --tolerance N        a pixel differs when a channel (0–255) moves by more than N (8)
#                --binary PATH        run this build of VibeSwitcher (vibeswitcher-host beside it) instead of building
#
# Files, all under .build/ui-journeys/: baseline/JOURNEY/*.png (the accepted shots), current/JOURNEY/*.png (the last
# run's, with SHOT.diff.png beside each changed one: the shot faded, changed pixels red, masked areas grey), report.txt
# (the last run's report, as printed), image-diff (the comparer, compiled from scripts/ui-journeys/image-diff.swift and
# Sources/VibeCore/ImageDiff.swift when either is newer).
#
# A journey is a file scripts/ui-journeys/NAME.journey; adding one needs nothing here. One command a line:
#   # …                   a comment (blank lines are skipped too)
#   desc TEXT             its one-line description, for `list`
#   mask GLOB X Y W H     pixels never compared in the shots whose name (e.g. chat-main-light) matches GLOB: a
#                         rectangle from the image's top left, in the image's pixels (a Retina shot is twice the points)
#   shot NAME             draws the sandbox's windows, light and dark: NAME-main-light.png, NAME-main-dark.png, and
#                         NAME-settings-*.png, NAME-sheet-*.png when those are shown; each is compared
#   anything else         a sandbox command, run as `scripts/sandbox-app.sh COMMAND REST` (chat, type TEXT, send,
#                         settings TAB, sheet NAME, select TEXT…: `scripts/sandbox-app.sh help` lists them); one that
#                         answers with an error stops the journey, which then counts as failed
# e.g. scripts/ui-journeys/smoke.journey:
#   desc Open a fake session's chat, type into its composer, and shoot it.
#   chat
#   type hello from the smoke journey
#   shot chat
#
# Noise: a composer's caret isn't drawn in a shot (a sandbox window is never key, so it never blinks there), and
# anti-aliasing stays under the tolerance. What does change from run to run on its own (clock times, ages like "10s",
# a fake session's id, pid, tty and scratch paths) goes under `mask` lines in the journey: see smoke.journey. To find
# them, run a journey twice and look at the red in its .diff.png files.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/scratch.sh

repo=$(pwd -P)
root=$repo/.build/ui-journeys
journeys=$repo/scripts/ui-journeys
threshold=0.05
tolerance=8
binary=""

usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; }

while [[ $# -gt 0 ]]; do
    case $1 in
        --threshold) threshold=${2:-}; shift 2 || { echo "--threshold PERCENT"; exit 64; } ;;
        --tolerance) tolerance=${2:-}; shift 2 || { echo "--tolerance N"; exit 64; } ;;
        --binary) binary=${2:-}; shift 2 || { echo "--binary PATH"; exit 64; } ;;
        -h|--help) usage; exit 0 ;;
        --*) echo "unknown option $1 (--help)"; exit 64 ;;
        *) break ;;
    esac
done
[[ $threshold =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "--threshold $threshold: a percentage, e.g. 0.05"; exit 64; }
[[ $tolerance =~ ^[0-9]+$ ]] && ((tolerance <= 255)) || { echo "--tolerance $tolerance: 0–255"; exit 64; }
[[ $# -gt 0 ]] || { usage; exit 64; }

# The journey's file, or a message and exit 64 when there's none by that name.
journey_file() {
    [[ $1 =~ ^[A-Za-z0-9._-]+$ && -f $journeys/$1.journey ]] || { echo "no journey $1 (scripts/ui-journeys.sh list)"; exit 64; }
    echo "$journeys/$1.journey"
}

all_journeys() {
    local file
    for file in "$journeys"/*.journey; do [[ -f $file ]] && basename "$file" .journey; done
}

description() { sed -n 's/^[[:space:]]*desc[[:space:]]\{1,\}//p' "$1" | head -1; }

list() {
    local name
    for name in $(all_journeys); do printf '%-16s %s\n' "$name" "$(description "$journeys/$name.journey")"; done
}

accept() {
    [[ $# -gt 0 ]] || { echo "accept JOURNEY…"; exit 64; }
    local name shots
    for name in "$@"; do journey_file "$name" >/dev/null; done
    for name in "$@"; do
        shots=$(find "$root/current/$name" -maxdepth 1 -name '*.png' ! -name '*.diff.png' 2>/dev/null | sort || true)
        [[ -n $shots ]] || { echo "$name: no shots to accept (run it first: scripts/ui-journeys.sh run $name)"; exit 1; }
        rm -rf "$root/baseline/$name"
        mkdir -p "$root/baseline/$name"
        while IFS= read -r shot; do cp "$shot" "$root/baseline/$name/"; done <<<"$shots"
        echo "$name: $(wc -l <<<"$shots" | tr -d ' ') shots accepted as the baselines"
    done
}

# The comparer, compiled when it's missing or older than its sources.
image_diff=$root/image-diff
build_image_diff() {
    local sources=("$journeys/image-diff.swift" "$repo/Sources/VibeCore/ImageDiff.swift") source
    mkdir -p "$root"
    for source in "${sources[@]}"; do
        [[ -x $image_diff && ! $source -nt $image_diff ]] && continue
        echo "compiling the image comparer"
        swiftc -O -parse-as-library -module-name ImageDiffTool "${sources[@]}" -o "$image_diff.new" </dev/null
        mv "$image_diff.new" "$image_diff"
        return
    done
}

sandbox_dir=$root/sandbox
sandbox() { bash scripts/sandbox-app.sh --dir "$sandbox_dir" --shots "$root/staging" "$@" </dev/null; }
quit_sandbox() { sandbox quit >/dev/null 2>&1 || true; }

# Runs journey $1 in a fresh sandbox: its shots go to current/$1/. Prints what failed and returns 1 when a command did.
run_journey() {
    local name=$1 file number=0 line command rest output png
    file=$(journey_file "$name")
    rm -rf "$root/current/$name" "$root/staging"
    mkdir -p "$root/current/$name" "$root/staging"
    if ! output=$(sandbox ${binary:+--binary "$binary"} run 2>&1); then
        echo "$output" | tail -20 | sed 's/^/    /'
        echo "the sandbox didn't start"
        return 1
    fi
    while IFS= read -r line || [[ -n $line ]]; do
        number=$((number + 1))
        line=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<<"$line")
        [[ -z $line || $line == \#* ]] && continue
        command=${line%%[[:space:]]*}
        rest=$(sed 's/^[^[:space:]]*[[:space:]]*//' <<<"$line")
        case $command in
            desc|mask) continue ;;
            shot)
                [[ $rest =~ ^[A-Za-z0-9._-]+$ ]] || { echo "line $number: shot NAME (letters, digits, . _ -)"; return 1; }
                output=$(sandbox shot "$rest" 2>&1) || { echo "line $number ($line): $output"; return 1; }
                while IFS= read -r png; do
                    [[ $png == "$root/staging/"*.png && -f $png ]] && mv "$png" "$root/current/$name/"
                done <<<"$output"
                ;;
            *)
                if [[ -n $rest ]]; then output=$(sandbox "$command" "$rest" 2>&1) || { echo "line $number ($line): $output"; return 1; }
                else output=$(sandbox "$command" 2>&1) || { echo "line $number ($line): $output"; return 1; }; fi
                ;;
        esac
    done <"$file"
}

# The journey's `mask` lines that match shot $2, as image-diff's --mask arguments, one a line.
masks_for() {
    local glob x y w h
    while read -r _ glob x y w h; do
        # shellcheck disable=SC2053
        [[ $2 == $glob ]] && echo "--mask" && echo "$x,$y,$w,$h"
    done < <(grep -E '^[[:space:]]*mask[[:space:]]' "$1" || true)
}

# Compares journey $1's shots with its baselines; prints the journey's line then a line a shot. Returns 1 when one changed.
compare_journey() {
    local name=$1 file current=$root/current/$1 baseline=$root/baseline/$1 shot stem result status changed=0 stored=0
    local lines=() masks
    file=$(journey_file "$name")
    mkdir -p "$baseline"
    for shot in "$current"/*.png; do
        [[ -f $shot && $shot != *.diff.png ]] || continue
        stem=$(basename "$shot" .png)
        if [[ ! -f $baseline/$stem.png ]]; then
            cp "$shot" "$baseline/"
            lines+=("  $stem: no baseline yet, stored this shot as it")
            stored=$((stored + 1))
            continue
        fi
        masks=()
        while IFS= read -r line; do [[ -n $line ]] && masks+=("$line"); done < <(masks_for "$file" "$stem")
        status=0
        result=$("$image_diff" "$baseline/$stem.png" "$shot" "$current/$stem.diff.png" --tolerance "$tolerance" --threshold "$threshold" \
            ${masks[@]+"${masks[@]}"} 2>&1) || status=$?
        case $status in
            0) lines+=("  $stem: unchanged ($result)") ;;
            1) lines+=("  $stem: CHANGED, $result; diff: ${current#"$repo"/}/$stem.diff.png"); changed=$((changed + 1)) ;;
            *) lines+=("  $stem: couldn't compare: $result"); changed=$((changed + 1)) ;;
        esac
    done
    for shot in "$baseline"/*.png; do
        [[ -f $shot ]] || continue
        stem=$(basename "$shot" .png)
        [[ -f $current/$stem.png ]] && continue
        lines+=("  $stem: MISSING, the baseline has it but this run drew no such shot")
        changed=$((changed + 1))
    done
    if ((changed > 0)); then echo "$name: changed ($changed shots; accept them with scripts/ui-journeys.sh accept $name)"
    elif ((stored > 0)); then echo "$name: baselines stored ($stored shots, in ${baseline#"$repo"/})"
    else echo "$name: unchanged"; fi
    ((${#lines[@]} > 0)) && printf '%s\n' "${lines[@]}"
    ((changed == 0))
}

run() {
    local names=("$@") name failed=0 problem
    ((${#names[@]} > 0)) || names=($(all_journeys))
    ((${#names[@]} > 0)) || { echo "no journeys in scripts/ui-journeys/"; exit 64; }
    for name in "${names[@]}"; do journey_file "$name" >/dev/null; done
    # swiftc and the sandbox's build leave folders in TMPDIR: a scratch one, removed on exit after the sandbox is quit.
    scratch_tmpdir vs-ui-journeys
    on_exit quit_sandbox
    build_image_diff
    mkdir -p "$root"
    : >"$root/report.txt"
    for name in "${names[@]}"; do
        echo "running $name" >&2
        if problem=$(run_journey "$name"); then
            quit_sandbox
            compare_journey "$name" | tee -a "$root/report.txt" || failed=1
        else
            quit_sandbox
            { echo "$name: failed"; echo "$problem" | sed 's/^/  /'; } | tee -a "$root/report.txt"
            failed=1
        fi
    done
    echo "report: ${root#"$repo"/}/report.txt" >&2
    return $failed
}

command=$1
shift
case $command in
    run) run "$@" ;;
    accept) accept "$@" ;;
    list) list ;;
    *) echo "unknown command $command (run, accept or list; --help)"; exit 64 ;;
esac
