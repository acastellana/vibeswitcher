# Sourced by the scripts that run swift build and swift test under vs-heavy (test.sh, build-app.sh). vs-heavy gives the
# command it runs VS_HEAVY_CORES, its width: the cores free when it starts, at least its slot's share of the Mac (the
# cores ÷ the slots, rounded up, at least 2: 4 on a 12-core Mac with 3 slots; see Resources/bin/vs-heavy's
# `give_width`). Left to itself SwiftPM compiles on every core: on 2026-11-01 a
# merge's build ran 9 swift-frontends at ~900 % CPU inside one slot, beside two other slots' jobs, at load 62–84.
#
# heavy_swift VERB [ARGS...]: `swift VERB --build-system native -j 2 -Xswiftc -jD ARGS...` (`swiftpm_options`) with
# D = VS_HEAVY_CORES ÷ 2 rounded up, when VS_HEAVY_CORES is a whole number above 0; else `swift VERB --build-system
# native ARGS...` as before (SwiftPM's default, every core). SwiftPM's
# -j N alone isn't N cores: it builds N modules at once and gives each module's swiftc -jN too, N frontends each, and
# swift test compiles the test targets side by side: with -j 4, 12 swift-frontends at ~1100 % CPU (measured 2026-11-01,
# 12 cores). Two modules at once, each with D frontends (the -Xswiftc -j comes after SwiftPM's and wins), keeps it near
# VS_HEAVY_CORES. The tests' own parallelism is a test a core: Swift Testing runs them on Swift's cooperative pool with no
# width of its own (--num-workers is XCTest's, with --parallel), and scripts/test.sh gives it one
# (SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH); they use far less than the build.
# It calls `swift` as the caller has it: module-cache.sh's function when that's in use. Exported, for the bash vs-heavy
# runs. VS_SWIFT_EXTRA_OPTIONS (unset but in `scripts/test.sh --tsan`): SwiftPM options for the build and the tests alike.
#
# Inside Codex's sandbox (a Codex session's commands run under its seatbelt, which sets CODEX_SANDBOX, e.g. "seatbelt")
# it passes --disable-sandbox too (`swiftpm_sandbox`): SwiftPM compiles and runs the package's manifest and plugins under
# a sandbox-exec of its own, and macOS refuses a sandbox inside a sandbox ("sandbox-exec: sandbox_apply: Operation not
# permitted", then "Invalid manifest": a Codex worker's scripts/test.sh, 2026-11-02, before anything compiled). Codex's
# own still holds them (no network, writes only where the worker may). Outside Codex, nothing changes.
heavy_swift() {
    local verb=$1 cores
    shift
    # Read by swiftpm_options in this shell; not on to SwiftPM and the tests it runs.
    export -n swiftpm_cache 2> /dev/null
    if [[ ${VS_HEAVY_CORES:-} =~ ^[0-9]+$ ]] && (( 10#$VS_HEAVY_CORES >= 1 )); then
        cores=$(( 10#$VS_HEAVY_CORES ))
        swift "$verb" $(swiftpm_options) ${VS_SWIFT_EXTRA_OPTIONS:-} -j 2 -Xswiftc "-j$(( (cores + 1) / 2 ))" "$@"
    else
        swift "$verb" $(swiftpm_options) ${VS_SWIFT_EXTRA_OPTIONS:-} "$@"
    fi
}
# "--disable-sandbox" inside Codex's sandbox (CODEX_SANDBOX set), else nothing: for a SwiftPM command run outside
# heavy_swift (`swift build --show-bin-path`, `swift package describe`), unquoted.
swiftpm_sandbox() {
    [[ -n ${CODEX_SANDBOX:-} ]] && echo --disable-sandbox
    return 0
}
# Every SwiftPM command the scripts run: the native build system, then `swiftpm_sandbox`'s, unquoted. Pinned since the
# Command Line Tools of 2026-11-05 (Swift 6.4.2) made swiftbuild the default: it compiles SwiftTerm's .metal file, which
# needs Xcode's Metal Toolchain component (a download), and puts its products in .build/out, not .build/<triple>.
# The native one warns it's deprecated, on stderr, which module-cache.sh's swift puts in its output: a
# --show-bin-path's caller takes the last line.
swiftpm_options() {
    echo --build-system native
    swiftpm_sandbox
    [[ -n ${swiftpm_cache:-} ]] && echo --cache-path "$swiftpm_cache"
    return 0
}
# In a branch run's box (V2/Sandbox/BranchRun.swift) there is no network, and the account's SwiftPM cache is layered
# under the run's own home, where SwiftPM looks for it by HOME. The scripts then give SwiftPM and the tests a scratch
# HOME of their own, where it found no cache and a fresh worktree's first build fetched, and failed: "Fetching
# https://github.com/migueldeicaza/SwiftTerm.git … error: Git command 'git -C /tmp/vs-test.Q8quJp/home/.cache/
# org.swift.swiftpm/repositories/SwiftTerm-74b92343 config --get remote.origin.url' failed" (every merge's and audit's
# run on the node, 2026-11-21). Called before the scratch HOME replaces the caller's: there, swiftpm_options names the
# caller's cache to SwiftPM (`--cache-path`), and to nothing else: the tests' HOME stays the scratch one.
# Only for a caller in a user namespace that doesn't map uid 0 (a box: /proc/self/uid_map) whose HOME's SwiftPM cache
# is a mount of its own (/proc/self/mountinfo: the layer the box made there), both the kernel's: a branch run's home
# given the account's cache. A test.sh a test runs in the box, whose HOME is the outer run's scratch one, takes nothing.
# Outside such a namespace (the Mac, a developer's own run, a node's unboxed run), nothing changes. A shell
# variable, not exported: test.sh exports it for the bash vs-heavy runs, and heavy_swift keeps it from SwiftPM and the tests.
swiftpm_run_cache() {
    unset swiftpm_cache
    local cache=$HOME/.cache/org.swift.swiftpm
    [[ -r /proc/self/uid_map && -r /proc/self/mountinfo && -d $cache && $cache != *[[:space:]\\]* ]] || return 0
    awk '$1 == 0 { mapped = 1 } END { exit mapped }' /proc/self/uid_map || return 0
    awk -v cache="$cache" '$5 == cache { mounted = 1 } END { exit !mounted }' /proc/self/mountinfo || return 0
    swiftpm_cache=$cache
}
# Inside Codex's sandbox there's no network either, and a new worktree's first build clones the package's dependencies
# (SwiftTerm, swift-argument-parser) from GitHub: "Could not resolve host: github.com". There, a checkout whose .build
# has no dependencies yet takes the main checkout's (the git common folder's): its .build/repositories, checkouts and
# workspace-state.json, cloned (cp -c, which takes no space on APFS). The checkouts' git objects stay in the main
# checkout's .build/repositories (their alternates name it): removing that folder while the worktree lives breaks its
# builds, as it would the main checkout's. SwiftPM then builds
# from them without fetching while the pins are the same; a branch that changed Package.resolved fetches as ever, which
# fails there for want of the network. Run from the package's folder, before the build; outside Codex it does nothing.
swiftpm_offline_dependencies() {
    [[ -n ${CODEX_SANDBOX:-} && ! -e .build/workspace-state.json ]] || return 0
    local common main
    common=$(git rev-parse --path-format=absolute --git-common-dir 2> /dev/null) || return 0
    main=$(dirname "$common")/.build
    [[ $main != "$(pwd -P)/.build" && -f $main/workspace-state.json && -d $main/checkouts && -d $main/repositories ]] || return 0
    # Linux: GNU cp has no -c; its clone is --reflink (auto: a plain copy where the file system can't clone).
    if [[ $(uname -s) == Linux ]]; then
        mkdir -p .build && cp -R --reflink=auto "$main/repositories" "$main/checkouts" "$main/workspace-state.json" .build/ \
            && echo "SwiftPM dependencies: the main checkout's, cloned into .build (Codex's sandbox has no network to fetch them)"
        return
    fi
    mkdir -p .build && cp -cR "$main/repositories" "$main/checkouts" "$main/workspace-state.json" .build/ \
        && echo "SwiftPM dependencies: the main checkout's, cloned into .build (Codex's sandbox has no network to fetch them)"
}
export -f heavy_swift swiftpm_sandbox swiftpm_options
