# Sourced by scripts/build-app.sh. copy_resource_bundles BIN RESOURCES: copies SwiftPM's resource bundles in BIN (the
# app's: SwiftTerm_SwiftTerm.bundle, SwiftTerm's Metal shaders, and any other) into the app's RESOURCES, where
# Bundle.main.resourceURL finds them. Never a test target's (*Tests.bundle): 2026-11-07 every $BIN/*.bundle went in,
# VibeSwitcher_VibeHostTests.bundle and its fixtures too, and the --install copy failed on one of those fixtures.
copy_resource_bundles() {
    local bundle
    for bundle in "$1"/*.bundle; do
        [[ -e $bundle ]] || continue
        [[ $(basename "$bundle") == *Tests.bundle ]] && continue
        cp -R "$bundle" "$2/" || return 1
    done
}
