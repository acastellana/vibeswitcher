# Sourced by scripts that build in a worker's worktree (test.sh, test-under-load.sh). A new worktree's first build takes
# about 2 minutes and 700 MB, and a third of the CPU and 300 MB of it is the SDK's modules (Foundation, AppKit,
# SwiftShims…), compiled into .build/…/debug/ModuleCache, the same in every worktree. In a worktree the lead made
# (<main checkout>/.vibeswitcher/worktrees/<slug>), shared_module_cache has the compiler keep them in one folder
# instead, <main checkout>/.vibeswitcher/module-cache, which every such worktree builds against: from then on the
# script's swift build, swift test and swift run pass `-Xswiftc -module-cache-path -Xswiftc <that folder>` (a function
# named swift, exported for a bash the script runs them in). Clang and Swift share a module cache between builds that run at once (Xcode keeps one for every
# project) and check each module against the SDK's headers.
#
# Nothing else is shared: the package's own modules and SwiftTerm still compile in each worktree. SwiftPM writes
# absolute paths into them, so a copy of another checkout's .build (cp -c) recompiles all of it, and a ModuleCache
# copied or linked from elsewhere fails to compile. SWIFTPM_MODULECACHE_OVERRIDE moves only the manifest's and
# plugins' cache, not the targets'. The main checkout, and merge's and an audit's own worktrees (under
# ~/.vibeswitcher/lead/scratch), keep a ModuleCache of their own: they build as before, from nothing.
#
# A plain swift build in the same worktree works too, and builds its own ModuleCache for what it compiles: the module
# cache's path doesn't count as a change of arguments, so switching between the two recompiles only the package's
# plugins, not the code.

module_cache=""

shared_module_cache() {
    local common main
    common=$(git rev-parse --path-format=absolute --git-common-dir 2> /dev/null) || return 0
    main=$(dirname "$common")
    [[ $(dirname "$(pwd -P)") == "$main/.vibeswitcher/worktrees" ]] || return 0
    mkdir -p "$main/.vibeswitcher/module-cache" || return 0
    module_cache=$main/.vibeswitcher/module-cache
    # For a bash the script runs them in (test.sh's under vs-heavy), which takes both from its environment.
    export module_cache
    export -f swift
    echo "SDK modules: the worktrees' shared cache, $module_cache (scripts/lib/module-cache.sh)"
}

# A module the compiler wrote is never half there (each is written beside and renamed into place), and one whose SDK
# headers changed is rebuilt. A damaged one (a disk error, a file cut short by hand) is not: clang names it in an error
# ("file '…/module-cache/…/Foundation-….pcm' is not a valid precompiled module file") and every worktree's build fails
# on it. An error naming a file in the cache can only be that, never the code's own: the cache is moved aside and
# removed, and the command runs once more on a new one.
swift() {
    case ${1:-} in
        build | test | run) [[ -n $module_cache ]] || { command swift "$@"; return; } ;;
        *) command swift "$@"; return ;;
    esac
    local log status
    # Not on to SwiftPM and the tests it runs: they see the environment a clean run has.
    export -n module_cache
    export -n -f swift
    log=$(mktemp "${TMPDIR:-/tmp}/swift-output.XXXXXX") || return 1
    command swift "$1" -Xswiftc -module-cache-path -Xswiftc "$module_cache" "${@:2}" 2>&1 | tee "$log"
    status=${PIPESTATUS[0]}
    if (( status != 0 )) && grep -aF "$module_cache/" "$log" | grep -aq "error:"; then
        echo "The worktrees' shared module cache is damaged (an error above names a file in it): starting it again and" \
            "running swift $1 once more. (scripts/lib/module-cache.sh)"
        if mv "$module_cache" "$module_cache.damaged.$$" 2> /dev/null; then rm -rf "$module_cache.damaged.$$"; fi
        mkdir -p "$module_cache"
        command swift "$1" -Xswiftc -module-cache-path -Xswiftc "$module_cache" "${@:2}"
        status=$?
    fi
    rm -f "$log"
    return $status
}
