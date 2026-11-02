# Sourced by the scripts that run swift build and swift test under vs-heavy (test.sh, build-app.sh). vs-heavy gives the
# command it runs VS_HEAVY_CORES, its slot's share of the Mac (the cores ÷ the slots, rounded up, at least 2: 4 on a
# 12-core Mac with 3 slots; see Resources/bin/vs-heavy). Left to itself SwiftPM compiles on every core: on 2026-11-01 a
# merge's build ran 9 swift-frontends at ~900 % CPU inside one slot, beside two other slots' jobs, at load 62–84.
#
# heavy_swift VERB [ARGS...]: `swift VERB -j 2 -Xswiftc -jD ARGS...` with D = VS_HEAVY_CORES ÷ 2 rounded up, when
# VS_HEAVY_CORES is a whole number above 0; else `swift VERB ARGS...` as before (SwiftPM's default, every core). SwiftPM's
# -j N alone isn't N cores: it builds N modules at once and gives each module's swiftc -jN too, N frontends each, and
# swift test compiles the test targets side by side: with -j 4, 12 swift-frontends at ~1100 % CPU (measured 2026-11-01,
# 12 cores). Two modules at once, each with D frontends (the -Xswiftc -j comes after SwiftPM's and wins), keeps it near
# VS_HEAVY_CORES. The tests' own parallelism isn't bounded: Swift Testing (6.1) runs them on Swift's cooperative pool, one
# thread a core, with no width to give (--num-workers is XCTest's, with --parallel); they use far less than the build.
# It calls `swift` as the caller has it: module-cache.sh's function when that's in use. Exported, for the bash vs-heavy
# runs.
heavy_swift() {
    local verb=$1 cores
    shift
    if [[ ${VS_HEAVY_CORES:-} =~ ^[0-9]+$ ]] && (( 10#$VS_HEAVY_CORES >= 1 )); then
        cores=$(( 10#$VS_HEAVY_CORES ))
        swift "$verb" -j 2 -Xswiftc "-j$(( (cores + 1) / 2 ))" "$@"
    else
        swift "$verb" "$@"
    fi
}
export -f heavy_swift
