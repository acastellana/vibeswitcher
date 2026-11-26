#!/bin/bash
# scripts/ci/macos-install-dry-run.sh: scripts/install-node-mac.sh's dry run, on the hosted Mac (the `v2 macos install` workflow's
# `install` job) or any Mac: this checkout's HEAD, pushed as v2 to a scratch origin, installed into a scratch prefix with
# the test flags (a file:// origin, an injected "green" CI answer, the runner's Xcode unchecked: it isn't root's there),
# built for real (a release build, signed). Then what the install made is checked, and the refusals a dry run can reach:
#   1. installed: exit 0; current names HEAD; build-info records HEAD and five programs; the server and the command line
#      signed with the Hardened Runtime; no run path left but /usr/lib/swift (the toolchain's deleted); no LaunchAgent
#      written (a test install never writes one); the administrator step (node-pins-mac.sh) dry: the record it prints
#      pins the installed host's, server's and command line's cdhashes, and nothing is written
#   2. again: refused (1), installed already
#   3. a red CI answer, on a fresh prefix: refused (67) before any build
#   4. the test flags with the account's builds folder: refused (64)
#   5. a product with a slice that isn't arm64 or x86_64 (a copy of /bin/ls: arm64e), as --test-products: refused (69)
# Nothing outside the scratch folder is written: no LaunchAgent, nothing in ~/.vibeswitcher, no launchctl. Exit 0 when
# every case holds; else 1, each failure said.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
[[ $(uname -s) == Darwin ]] || { echo "the Mac's install: run on a Mac"; exit 2; }
repo=$PWD
script=$repo/scripts/install-node-mac.sh
commit=$(git rev-parse HEAD) || exit 1
[[ -z $(git status --porcelain) ]] || { echo "the checkout isn't clean: the install's courtesy check would refuse it"; exit 1; }
developer=${DEVELOPER_DIR:-$(xcode-select -p)}

# shellcheck source=../lib/scratch.sh
source scripts/lib/scratch.sh
scratch_tmpdir install-dry-run
work=$tool_scratch
failures=0
fail_case() { echo "FAIL: $*"; failures=$((failures + 1)); }
pass_case() { echo "ok: $*"; }

origin=$work/origin.git
git init -q --bare "$origin" && git -C "$origin" config receive.shallowUpdate true \
    && git push -q "$origin" "HEAD:refs/heads/v2" || { echo "can't make the scratch origin"; exit 1; }
printf 'green\n' > "$work/green"
printf 'red: v2 linux failed\n' > "$work/red"
agent=$HOME/Library/LaunchAgents/dev.vibeswitcher.node.plist
agent_before=$( [[ -e $agent ]] && echo there || echo none )

# install PREFIX ANSWER [MORE…]: the install as its header says to run it, its output in $work/out, its status returned.
install() {
    local prefix=$1 answer=$2
    shift 2
    /usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin VIBESWITCHER_HEAVY_TIMEOUT=50m /bin/bash -p "${INSTALL_SCRIPT:-$script}" "$commit" \
        --prefix "$prefix" --repo "$repo" --test-origin "file://$origin" --test-ci-answer "$answer" "$@" > "$work/out" 2>&1
}

# 1. Installed.
builds=$work/builds
install "$builds" "$work/green" --test-unchecked-toolchain --developer-dir "$developer"
status=$?
cat "$work/out"
if [[ $status != 0 ]]; then
    fail_case "the install exited $status"
else
    [[ $(readlink "$builds/current") == "$commit" ]] && pass_case "current names $commit" || fail_case "current names $(readlink "$builds/current")"
    [[ $(/usr/bin/jq -r .commit "$builds/$commit/build-info") == "$commit" ]] && pass_case "build-info records $commit" || fail_case "build-info's commit"
    [[ $(/usr/bin/jq -r '.binaries | length' "$builds/$commit/build-info") == 5 ]] && pass_case "build-info records five programs" || fail_case "build-info's programs"
    for program in vibeswitcher-server vibeswitcher vibeswitcher-host; do
        shown=$(codesign -d --verbose=2 "$builds/$commit/bin/$program" 2>&1)
        if [[ $shown =~ flags=0x[0-9a-f]+\(([a-z,-]*)\) && ,${BASH_REMATCH[1]}, == *,runtime,* ]]; then
            pass_case "$program is signed with the Hardened Runtime"
        else
            fail_case "$program isn't signed with the Hardened Runtime: $(printf '%s' "$shown" | grep -m1 flags=)"
        fi
        codesign --verify --strict "$builds/$commit/bin/$program" 2> /dev/null && pass_case "$program's signature verifies" || fail_case "$program's signature doesn't verify"
    done
    # The toolchain's run paths deleted before the signature: none left but the system's Swift.
    for program in vibeswitcher-host vibeswitcher-server vibeswitcher vibeswitcher-hook vibeswitcher-mcp; do
        left=$(otool -l "$builds/$commit/bin/$program" | grep -A2 -w LC_RPATH | grep -w path | sed -e 's/^ *path //' -e 's/ (offset [0-9]*)$//' | grep -vx /usr/lib/swift)
        [[ -z $left ]] && pass_case "$program keeps no run path but /usr/lib/swift" || fail_case "$program keeps the run paths $left"
    done
    grep -q "no LaunchAgent written" "$work/out" && pass_case "no LaunchAgent written" || fail_case "the install didn't say it wrote no LaunchAgent"
    # The administrator step (node-pins-mac.sh), dry: the record it would write pins the signed copies' cdhashes.
    pins=""
    for program in vibeswitcher-host vibeswitcher-server vibeswitcher; do
        pins+=" $(codesign -d -a "$(uname -m)" --verbose=3 "$builds/$commit/bin/$program" 2>&1 | sed -n 's/^CDHash=//p')"
    done
    read -r pin_host pin_server pin_cli <<< "$pins"
    grep -qx "    build $commit host $pin_host server $pin_server cli $pin_cli" "$work/out" \
        && pass_case "the administrator step would pin $commit's host, server and command line" || fail_case "the administrator step's record doesn't pin the installed cdhashes"
    grep -q "node-pins-mac: --dry-run: nothing written, no password asked" "$work/out" && pass_case "the administrator step wrote nothing (a test install)" \
        || fail_case "the administrator step didn't say it wrote nothing"
    [[ -x $builds/$commit/Resources/node-pins-mac.sh ]] && pass_case "the build keeps its administrator step" || fail_case "no Resources/node-pins-mac.sh in the build"
    # The review's case: exported `builtin` and `printf` functions don't reach the step run as `bash -p`.
    hijacked=$(env 'BASH_FUNC_builtin%%=() { :; }' 'BASH_FUNC_printf%%=() { command printf "HIJACKED\n"; }' \
        /bin/bash -p "$builds/$commit/Resources/node-pins-mac.sh" --dry-run --build "$commit" $pins 2>&1 | grep -c HIJACKED)
    [[ $hijacked == 0 ]] && pass_case "exported builtin and printf functions don't reach the administrator step (bash -p)" \
        || fail_case "an exported function reached the administrator step ($hijacked lines)"
    [[ ! -e $builds/dev.vibeswitcher.node.plist ]] || fail_case "a LaunchAgent was written into $builds"
    echo "the installed products' load commands (for the record):"
    for program in vibeswitcher-server vibeswitcher; do otool -L "$builds/$commit/bin/$program" | sed 's/^/  /'; done
fi

# 2. Again: installed already (run as the installed copy, as a next install must).
if [[ -f $builds/current/Resources/install-node-mac.sh ]]; then
    INSTALL_SCRIPT=$builds/current/Resources/install-node-mac.sh install "$builds" "$work/green" --test-unchecked-toolchain --developer-dir "$developer"
    status=$?
    [[ $status == 1 ]] && grep -q "is installed" "$work/out" && pass_case "a second install is refused: installed already" \
        || fail_case "a second install exited $status: $(cat "$work/out")"
fi

# 3. A red CI answer: refused before any build.
install "$work/red-builds" "$work/red" --test-unchecked-toolchain --developer-dir "$developer"
status=$?
[[ $status == 67 ]] && grep -q "not green" "$work/out" && [[ ! -e $work/red-builds/$commit ]] \
    && pass_case "a red CI answer is refused (67)" || fail_case "a red CI answer exited $status: $(cat "$work/out")"

# 4. The test flags with the account's builds folder.
install "$HOME/.vibeswitcher/v2/builds" "$work/green" --test-unchecked-toolchain
status=$?
[[ $status == 64 ]] && grep -q "scratch" "$work/out" && pass_case "the test flags refuse the account's builds folder (64)" \
    || fail_case "the account's builds folder with the test flags exited $status: $(cat "$work/out")"

# 5. A slice that isn't arm64 or x86_64.
if [[ -d $builds/$commit/bin ]]; then
    products=$work/products
    mkdir -p "$products"
    for program in vibeswitcher-host vibeswitcher-server vibeswitcher-mcp; do cp "$builds/$commit/bin/$program" "$products/"; done
    cp "$builds/$commit/bin/vibeswitcher" "$products/vibeswitcher-cli"
    cp /bin/ls "$products/vibeswitcher-hook"
    cp "$builds/$commit/build-info" "$work/build-info" && /usr/bin/jq -r .swift "$work/build-info" > "$products/swift-version"
    install "$work/odd-builds" "$work/green" --test-products "$products"
    status=$?
    [[ $status == 69 ]] && grep -q "vibeswitcher-hook" "$work/out" && [[ ! -e $work/odd-builds/$commit ]] \
        && pass_case "a product with an arm64e slice is refused (69): $(tail -n 1 "$work/out")" \
        || fail_case "a product with an arm64e slice exited $status: $(cat "$work/out")"
fi

[[ $( [[ -e $agent ]] && echo there || echo none ) == "$agent_before" ]] || fail_case "$agent changed"
(( failures == 0 )) && { echo "the dry run holds"; exit 0; }
echo "$failures failed"
exit 1
