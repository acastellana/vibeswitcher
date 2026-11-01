# Sourced by the scripts that run swift build and swift test under vs-heavy (test.sh, build-app.sh). vs-heavy gives the
# command it runs VS_HEAVY_CORES, its slot's share of the Mac (the cores ÷ the slots, rounded up, at least 2: 4 on a
# 12-core Mac with 3 slots; see Resources/bin/vs-heavy). Left to itself SwiftPM compiles on every core: on 2026-11-01 a
# merge's build ran 9 swift-frontends at ~900 % CPU inside one slot, beside two other slots' jobs, at load 62–84.
#
# heavy_swift VERB [ARGS...]: `swift VERB -j N ARGS...` when VS_HEAVY_CORES is a whole number N above 0, else
# `swift VERB ARGS...` as before (SwiftPM's default, every core). -j bounds the build's jobs, swift test's build of the
# tests too. The tests' own parallelism isn't bounded: Swift Testing (6.1) runs them on Swift's cooperative pool, one
# thread a core, with no width to give (--num-workers is XCTest's, with --parallel). It calls `swift` as the caller has
# it: module-cache.sh's function when that's in use. Exported, for the bash vs-heavy runs.
heavy_swift() {
    local verb=$1
    shift
    if [[ ${VS_HEAVY_CORES:-} =~ ^[0-9]+$ ]] && (( 10#$VS_HEAVY_CORES >= 1 )); then
        swift "$verb" -j "$(( 10#$VS_HEAVY_CORES ))" "$@"
    else
        swift "$verb" "$@"
    fi
}
export -f heavy_swift
