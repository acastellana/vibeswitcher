# Sourced by scripts/test-under-load.sh, which starts the test bundles itself (swiftpm-testing-helper) rather than
# through `swift test`, and so must tell dyld where Testing.framework is, as `swift test` does. Where it is depends on
# the developer folder: an Xcode keeps it in its macOS platform (Contents/Developer/Platforms/MacOSX.platform/
# Developer/Library/Frameworks), the Command Line Tools in Library/Developer/Frameworks, with no platform at all
# (`xcrun --show-sdk-platform-path` fails there). Until 2026-10-31 the harness knew only the platform: on a Mac whose
# xcode-select points at the Command Line Tools, where scripts/test.sh's `swift test` passes, it stopped with "no
# macOS platform", and workers had to set DEVELOPER_DIR by hand.
#
# pick_developer_dir [XCODE_APP...] sets developer_dir, test_frameworks (DYLD_FRAMEWORK_PATH) and test_libraries (to
# go after the build folder in DYLD_LIBRARY_PATH), from, in turn:
#   - the caller's DEVELOPER_DIR, as it is: one without Testing.framework is an error, never passed over;
#   - the folder xcode-select names (xcode-select -p, only read): the toolchain test.sh's swift build and swift test use,
#     so the harness builds and runs what they would;
#   - else the first XCODE_APP (default /Applications/Xcode.app, then /Applications/Xcode*.app) with a macOS platform,
#     exported as DEVELOPER_DIR so the build and the runs both use it.
# None: one line saying so, and it returns 1. It never changes xcode-select's choice.

# Sets test_frameworks and test_libraries for the developer folder $1, if it holds Testing.framework.
developer_frameworks() {
    local platform=$1/Platforms/MacOSX.platform/Developer
    if [[ -d $platform/Library/Frameworks/Testing.framework ]]; then
        test_frameworks="$platform/Library/Frameworks:$platform/Library/PrivateFrameworks"
        test_libraries="$platform/usr/lib"
    elif [[ -d $1/Library/Developer/Frameworks/Testing.framework ]]; then
        test_frameworks="$1/Library/Developer/Frameworks"
        test_libraries="$1/Library/Developer/usr/lib"
    else
        return 1
    fi
}

pick_developer_dir() {
    local selected app
    developer_dir="" test_frameworks="" test_libraries=""
    if [[ -n ${DEVELOPER_DIR:-} ]]; then
        if developer_frameworks "$DEVELOPER_DIR"; then
            developer_dir=$DEVELOPER_DIR
            return 0
        fi
        # An Xcode.app itself, as xcrun and swift take it too: its Contents/Developer.
        if developer_frameworks "$DEVELOPER_DIR/Contents/Developer"; then
            developer_dir=$DEVELOPER_DIR/Contents/Developer
            return 0
        fi
        echo "DEVELOPER_DIR is $DEVELOPER_DIR, which holds no Testing.framework (neither an Xcode's" \
            "Platforms/MacOSX.platform nor the Command Line Tools' Library/Developer/Frameworks): unset it, or point it" \
            "at an Xcode's Contents/Developer"
        return 1
    fi
    selected=$(xcode-select -p 2> /dev/null)
    if [[ -n $selected ]] && developer_frameworks "$selected"; then
        developer_dir=$selected
        return 0
    fi
    (( $# > 0 )) || set -- /Applications/Xcode.app /Applications/Xcode*.app
    for app in "$@"; do
        if developer_frameworks "$app/Contents/Developer"; then
            developer_dir=$app/Contents/Developer
            export DEVELOPER_DIR=$developer_dir
            return 0
        fi
    done
    echo "no Xcode found with Swift Testing (looked in $*), and xcode-select's ${selected:-(none)} holds no" \
        "Testing.framework: install Xcode, or set DEVELOPER_DIR to an Xcode's Contents/Developer"
    return 1
}
