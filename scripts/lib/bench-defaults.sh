# Sourced by the scripts that run a VibeSwitcher build's benches (ui-bench.sh, chat-bench-perf.sh, chat-bench-settle.sh).
# A build keeps a bench's defaults in scratch since 2026-10-25 (Sources/VibeSwitcher/BenchDefaults.swift); an older one
# writes them (window frames, split views, chat font, inspector tab) to the real ~/Library/Preferences/VibeSwitcher.plist,
# whatever the scratch home says, so these scripts don't run one.
#
# bench_defaults_in_scratch BINARY: 0 when BINARY is a build that keeps them in scratch (it holds BenchDefaults' refusal
#   text); else says so and returns 1.
bench_defaults_in_scratch() {
    LC_ALL=C grep -qaF "couldn't give the bench defaults of its own" "$1" && return 0
    echo "$1 predates BenchDefaults (2026-10-25): its benches would write your real ~/Library/Preferences/VibeSwitcher.plist."
    echo "Not run: give a build of a commit that has Sources/VibeSwitcher/BenchDefaults.swift, or rebuild this one."
    return 1
}
