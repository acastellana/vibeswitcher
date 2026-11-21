# shellcheck shell=bash
# The Mac's signing of the node's binaries (docs/process/v2-mac-tasks.md, "before approvalMeasured flips" items 3 and
# 7): each signed ad hoc with the Hardened Runtime, as scripts/build-app.sh signs the app's, so the processes they start
# pass `Platform.CodeIdentity.isHardened` (the voice's caller check asks it of the command line, ServerCheck of the
# server). Sourced; only the Mac's install calls it, on its own copy of each product before that copy is hashed (a
# signature changes the file). Nothing here reads PATH: every tool by its absolute path.
#
# mac_sign_hardened FILE: signs FILE in place (`codesign --force --options runtime --sign -`), then checks it: the
# signature valid for every slice (`codesign --verify --strict`) and the runtime flag in what codesign reads back.
# Returns 0 when both hold; else 1, one line on stderr naming what failed.
mac_sign_hardened() {
    local file=$1 shown
    [[ -f $file && ! -L $file ]] || { printf 'mac-sign: %s is not a regular file\n' "$file" >&2; return 1; }
    /usr/bin/codesign --force --options runtime --sign - -- "$file" 2> /dev/null \
        || { printf 'mac-sign: codesign could not sign %s\n' "$file" >&2; return 1; }
    /usr/bin/codesign --verify --strict --all-architectures -- "$file" 2> /dev/null \
        || { printf 'mac-sign: the signature of %s does not verify\n' "$file" >&2; return 1; }
    # `codesign -d --verbose` prints `CodeDirectory v=… flags=0x10002(adhoc,runtime) …` on stderr.
    shown=$(/usr/bin/codesign -d --verbose=2 -- "$file" 2>&1) \
        || { printf 'mac-sign: codesign could not read %s back\n' "$file" >&2; return 1; }
    [[ $shown =~ flags=0x[0-9a-f]+\(([a-z,-]*)\) && ,${BASH_REMATCH[1]}, == *,runtime,* ]] \
        || { printf 'mac-sign: %s is signed without the Hardened Runtime\n' "$file" >&2; return 1; }
}
