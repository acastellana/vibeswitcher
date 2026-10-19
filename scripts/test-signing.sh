#!/bin/bash
# Checks that the signing scripts keep VibeSwitcher's signing identity yours (security F-F2): no keychain password on
# a command line anywhere in scripts/ (`create-keychain -p`, `unlock-keychain -p`, `set-keychain-password -o/-p`,
# `set-key-partition-list -k`, `import -P`), where any process can read it with ps; and build-app.sh refusing a
# signing folder that still holds the password file an earlier setup-signing.sh saved.
#
# With --build it also runs setup-signing.sh and build-app.sh (to build/, never --install) on a scratch HOME, as the
# user would but with the password on stdin: an earlier setup's keychain and password file are replaced; the new key
# can't be exported and only codesign may use it; no password file is left; the keychain is locked after setup and
# locks on sleep, with no inactivity timeout; and the app and its helpers are signed with the identity. macOS's
# password dialog is stood in for by a codesign on build-app.sh's PATH that counts a prompt when the key is used with
# the keychain locked, and unlocks it as you would: the first build after setup asks once, a second build in the same
# session doesn't ask and the keychain stays unlocked, and after a lock (as on sleep) the next build asks again. The
# 5-minute timeout an earlier setup set is dropped by the first build; a timeout you chose is kept. Your own signing
# keychain, login keychain and keychain search list are never touched (the search list is HOME's).
#
# scripts/test-signing.sh [--build]
# (pipefail: a check reads its pipe to the end, `grep >/dev/null` rather than `grep -q`, or the writer's SIGPIPE fails it.)
set -uo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d "${TMPDIR:-/tmp}/vs-signing-check.XXXXXX")
cleanup() {
    # Scratch keychains leave the scratch search list with delete-keychain; then the folder goes.
    local kc
    for kc in $(find "$work" -name '*.keychain-db' 2>/dev/null); do
        HOME="$work/home" CFFIXED_USER_HOME="$work/home" security delete-keychain "$kc" 2>/dev/null
    done
    rm -r "$work"
}
trap cleanup EXIT

failures=0
check() {
    if eval "$2"; then echo "ok    $1"; else echo "FAIL  $1"; failures=$((failures + 1)); fi
}

# The lines of the given files that pass a keychain password as an argument, continuation lines joined (comments,
# which may name the forms, aren't commands).
password_arguments() {
    awk '/^[[:space:]]*#/ { next } { if (sub(/\\$/, "")) { line = line $0 " "; next } print FILENAME ":" FNR ": " line $0; line = "" }' "$@" |
        grep -E '(create|unlock)-keychain.*[[:space:]]-p|set-keychain-password.*[[:space:]]-[op]|set-key-partition-list.*[[:space:]]-k|security[[:space:]]+import.*[[:space:]]-P'
}

# The lint catches each form (built here, so this file doesn't hold them), and passes what's allowed.
fixture="$work/fixture.sh"
for verb in create unlock; do
    printf 'security %s-keychain -p "$PASSWORD" "$KEYCHAIN"\n' "$verb" > "$fixture"
    check "lint catches $verb-keychain -p" 'password_arguments "$fixture" >/dev/null'
done
printf 'security %s-keychain \\\n    -%s secret "$KEYCHAIN"\n' unlock p > "$fixture"
check "lint catches -p on a continuation line" 'password_arguments "$fixture" >/dev/null'
printf 'security set-key-partition-%s -S apple-tool: -s -%s secret k\nsecurity %s id.p12 -k k -%s secret\n' list k import P \
    > "$fixture"
check "lint catches the partition list's -k and import's -P" '[[ $(password_arguments "$fixture" | wc -l) -eq 2 ]]'
printf 'security %s "$KEYCHAIN"\nsecurity find-identity -p codesigning "$KEYCHAIN"\n' create-keychain > "$fixture"
check "lint passes a keychain made at a prompt, and find-identity's -p" '! password_arguments "$fixture" >/dev/null'

found=$(password_arguments $(find scripts -type f) || true)
check "no keychain password in argv anywhere in scripts/" '[[ -z $found ]]'
[[ -n $found ]] && echo "$found"
check "nothing in scripts/ reads a saved signing password" \
    '! grep -nE "cat[^|]*signing/password|cat[^|]*SIGNING_DIR/password" $(find scripts -type f)'

# build-app.sh refuses an earlier setup's password file, before it builds anything.
old="$work/old-home"
mkdir -p "$old/.vibeswitcher/signing"
printf 'secret' > "$old/.vibeswitcher/signing/password"
out=$(HOME="$old" CFFIXED_USER_HOME="$old" scripts/build-app.sh </dev/null 2>&1)
status=$?
check "build-app.sh refuses a saved signing password" '[[ $status -ne 0 && $out == *setup-signing.sh* && $out != *Compiling* ]]'

if [[ "${1:-}" == "--build" ]]; then
    home="$work/home"
    signing="$home/.vibeswitcher/signing"
    keychain="$signing/vibeswitcher.keychain-db"
    mkdir -p "$home/Library/Preferences" "$home/Library/Keychains"
    run() { HOME="$home" CFFIXED_USER_HOME="$home" "$@"; }
    # security reads a password from the terminal when there is one: run without one, so it reads stdin.
    no_tty() { python3 -I -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@"; }

    # Whether a keychain is locked, asked without a dialog (anything that reads a locked keychain asks you).
    cat > "$work/lockstate.swift" <<'EOF'
import Security
var keychain: SecKeychain?
var status: SecKeychainStatus = 0
guard SecKeychainOpen(CommandLine.arguments[1], &keychain) == errSecSuccess, let keychain,
      SecKeychainGetStatus(keychain, &status) == errSecSuccess else { print("unknown"); exit(1) }
print(status & SecKeychainStatus(kSecUnlockStateStatus) != 0 ? "unlocked" : "locked")
EOF
    swiftc -O "$work/lockstate.swift" -o "$work/lockstate" 2>/dev/null || { echo "FAIL  can't build the lock check"; exit 1; }
    lockstate() { run "$work/lockstate" "$keychain"; }

    # A search list of the user's own (a login keychain's place), which the scripts must leave as it was.
    printf 'placeholder\nplaceholder\n' | run no_tty security create-keychain "$work/placeholder.keychain-db" >/dev/null 2>&1
    run security list-keychains -d user -s "$work/placeholder.keychain-db"
    search_list=$(run security list-keychains -d user)

    # An earlier setup: its keychain and the password file beside it.
    mkdir -p "$signing"
    printf 'old-password\nold-password\n' | run no_tty security create-keychain "$keychain" >/dev/null 2>&1
    printf 'old-password' > "$signing/password"

    printf 'test-password\ntest-password\n' | run no_tty scripts/setup-signing.sh --no-trust > "$work/setup.log" 2>&1
    status=$?
    check "setup-signing.sh replaces an earlier setup" '[[ $status -eq 0 ]] && grep "Created .VibeSwitcher Local Signing. in" "$work/setup.log" >/dev/null'
    check "no password file is left" '[[ ! -e $signing/password && $(ls "$signing") == vibeswitcher.keychain-db ]]'
    check "the keychain is locked after setup" '[[ $(lockstate) == locked ]]'
    check "the search list is as it was" '[[ $(run security list-keychains -d user) == "$search_list" ]]'

    unlock() { printf 'test-password\n' | run no_tty security unlock-keychain "$keychain" 2>/dev/null; }
    unlock
    run security dump-keychain -a "$keychain" > "$work/dump.txt"
    # The private key's record: its attributes (0x10 Extractable, 0x11 NeverExtractable) and its access list.
    key=$(awk '/^keychain:/ { if (inkey) exit; inkey = 0 } /^class: 0x00000010/ { inkey = 1 } inkey' "$work/dump.txt")
    check "the key can't be exported" \
        '[[ $key == *"0x00000010 <uint32>=0x00000000"* && $key == *"0x00000011 <uint32>=0x00000001"* ]]'
    apps=$(grep -E '^ +[0-9]+: /' <<<"$key" | sed -E 's/^ +[0-9]+: ([^ ]+).*/\1/' | sort -u)
    check "only codesign may use the key without asking" '[[ $apps == /usr/bin/codesign ]]'
    check "the key's sign entry trusts codesign alone" \
        'grep -A6 "authorizations.*sign" <<<"$key" | grep "applications (1):" >/dev/null'

    keychain_info() { run security show-keychain-info "$keychain" 2>&1; }
    check "the keychain locks on sleep, with no inactivity timeout" '[[ $(keychain_info) == *"lock-on-sleep no-timeout" ]]'
    # As an earlier setup-signing.sh left it, locking after 5 minutes too: the first build makes it lock on sleep only.
    run security set-keychain-settings -l -u -t 300 "$keychain"
    run security lock-keychain "$keychain"

    # macOS's dialog, stood in for. codesign makes macOS ask for the password when it uses the key while the keychain
    # is locked; this codesign, first on build-app.sh's PATH, counts that prompt and answers it as you would (unlocks
    # the keychain, the password on stdin), then runs the real one. If the keychain stays locked it stops there, so no
    # dialog is ever put in front of you.
    mkdir "$work/bin"
    cat > "$work/bin/codesign" <<'EOF'
#!/bin/bash
if [[ $("$SIGNING_LOCKSTATE" "$SIGNING_KEYCHAIN") == locked ]]; then
    echo prompt >> "$SIGNING_PROMPTS"
    printf 'test-password\n' | python3 -I -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
        security unlock-keychain "$SIGNING_KEYCHAIN" 2>/dev/null
    [[ $("$SIGNING_LOCKSTATE" "$SIGNING_KEYCHAIN") == unlocked ]] || { echo "the scratch keychain didn't unlock" >&2; exit 1; }
fi
exec /usr/bin/codesign "$@"
EOF
    chmod +x "$work/bin/codesign"
    app=build/VibeSwitcher.app
    # build N: runs build-app.sh (which replaces build/VibeSwitcher.app), its output in $work/buildN.log; sets $status
    # and $prompts, the passwords macOS would have asked for.
    build() {
        : > "$work/prompts"
        run env PATH="$work/bin:$PATH" SIGNING_LOCKSTATE="$work/lockstate" SIGNING_KEYCHAIN="$keychain" \
            SIGNING_PROMPTS="$work/prompts" scripts/build-app.sh </dev/null > "$work/build$1.log" 2>&1
        status=$?
        prompts=$(wc -l < "$work/prompts" | tr -d ' ')
        [[ $status -ne 0 ]] && tail -20 "$work/build$1.log"
    }
    signed() { codesign -dvv "$1" 2>&1 | grep -x "Authority=VibeSwitcher Local Signing" >/dev/null; }

    # The first build after setup, as after login or wake: the keychain is locked.
    build 1
    check "build-app.sh builds to build/" '[[ $status -eq 0 && -d $app ]]'
    check "the first build asks for the password, once" '[[ $prompts -eq 1 ]]'
    for code in "$app" "$app/Contents/MacOS/vibeswitcher-hook" "$app/Contents/MacOS/vibeswitcher-host" \
                "$app/Contents/MacOS/vibeswitcher-mcp"; do
        check "${code#build/} signed by VibeSwitcher Local Signing" 'signed "$code"'
    done
    check "the app's signature is valid" 'codesign --verify --strict "$app"'
    check "the keychain stays unlocked after the build" '[[ $(lockstate) == unlocked ]]'
    check "the build drops an earlier setup's 5-minute timeout" '[[ $(keychain_info) == *"lock-on-sleep no-timeout" ]]'
    check "the search list is put back" '[[ $(run security list-keychains -d user) == "$search_list" ]]'

    # A second build in the same session, with no unlock step.
    build 2
    check "a second build signs without asking" \
        '[[ $status -eq 0 && $prompts -eq 0 ]] && signed "$app" && codesign --verify --strict "$app"'
    check "the keychain is still unlocked" '[[ $(lockstate) == unlocked ]]'

    # A timeout you chose yourself is kept. Then the Mac sleeps: the keychain locks, and the next build asks again.
    run security set-keychain-settings -l -u -t 3600 "$keychain"
    run security lock-keychain "$keychain"
    build 3
    check "after a lock the next build asks again, once" \
        '[[ $status -eq 0 && $prompts -eq 1 ]] && signed "$app" && codesign --verify --strict "$app"'
    check "a timeout you chose is kept" '[[ $(keychain_info) == *"lock-on-sleep timeout=3600s" ]]'
    check "the search list is still as it was" '[[ $(run security list-keychains -d user) == "$search_list" ]]'
fi

if [[ $failures -gt 0 ]]; then echo "$failures check(s) failed"; exit 1; fi
echo "All signing checks passed"
