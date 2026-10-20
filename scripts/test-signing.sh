#!/bin/bash
# Checks that the signing scripts keep VibeSwitcher's signing identity yours (security F-F2): no keychain password on
# a command line anywhere in scripts/ (`create-keychain -p`, `unlock-keychain -p`, `set-keychain-password -o/-p`,
# `set-key-partition-list -k`, `import -P`), where any process can read it with ps; build-app.sh refusing a
# signing folder that still holds the password file an earlier setup-signing.sh saved, and saying so when the
# replacement stopped half way; and setup-signing.sh naming the password macOS's trust dialog wants just before it.
#
# With --build it also runs setup-signing.sh and build-app.sh (to build/, never --install) on a scratch HOME, as the
# user would but with the password on stdin: a Ctrl-C at the new keychain's password prompt says what was done, and
# leaves build-app.sh refusing; run again, setup says what it asks for in order, before each step, and finishes
# replacing the earlier setup's keychain and password file; the new key
# can't be exported and only codesign may use it; no password file is left; the keychain is locked after setup and
# locks on sleep, with no inactivity timeout; and the app and its helpers are signed with the identity. macOS's
# password dialog is stood in for by a codesign on build-app.sh's PATH that counts a prompt when the key is used with
# the keychain locked, and unlocks it as you would: the first build after setup asks once, a second build in the same
# session doesn't ask and the keychain stays unlocked, and after a lock (as on sleep) the next build asks again. The
# 5-minute timeout an earlier setup set is dropped by the first build; a timeout you chose is kept. Your own signing
# keychain, login keychain and keychain search list are never touched (the search list is HOME's).
#
# The keychain search list: both scripts hold the same block for it, and the list its exit hook writes back always
# holds the login keychain, the list read empty or lost too. With --build, on the scratch HOME (its own login keychain
# in its list): a list read as empty, one security fails to read and one without the login keychain each stop
# setup-signing.sh and build-app.sh with nothing changed, saying what they saw; setup puts the list back as soon as
# create-keychain has added to it, and a build adds the signing keychain just before its four codesigns and puts the
# list back right after them, Ctrl-C during signing too; after each, the list is as it was, the login keychain in it.
#
# scripts/test-signing.sh [--build]
# (pipefail: a check reads its pipe to the end, `grep >/dev/null` rather than `grep -q`, or the writer's SIGPIPE fails it.)
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/scratch.sh

work=$(mktemp -d "${TMPDIR:-/tmp}/vs-signing-check.XXXXXX")
cleanup() {
    # Scratch keychains leave the scratch search list with delete-keychain; then the folder goes.
    local kc
    for kc in $(find "$work" -name '*.keychain-db' 2>/dev/null); do
        HOME="$work/home" CFFIXED_USER_HOME="$work/home" security delete-keychain "$kc" 2>/dev/null
    done
    rm -r "$work"
}
on_exit cleanup

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

# build-app.sh refuses an earlier setup's password file, before it builds anything; and, once setup-signing.sh has
# removed that setup's keychain but not yet made the new one (the password file stays until then), says so.
old="$work/old-home"
mkdir -p "$old/.vibeswitcher/signing"
printf 'secret' > "$old/.vibeswitcher/signing/password"
: > "$old/.vibeswitcher/signing/vibeswitcher.keychain-db"
out=$(HOME="$old" CFFIXED_USER_HOME="$old" scripts/build-app.sh </dev/null 2>&1)
status=$?
check "build-app.sh refuses a saved signing password" \
    '[[ $status -ne 0 && $out == *"password is saved"*setup-signing.sh* && $out != *Compiling* ]]'
rm "$old/.vibeswitcher/signing/vibeswitcher.keychain-db"
out=$(HOME="$old" CFFIXED_USER_HOME="$old" scripts/build-app.sh </dev/null 2>&1)
status=$?
check "build-app.sh refuses a replacement setup-signing.sh didn't finish" \
    '[[ $status -ne 0 && $out == *"keychain is missing"*setup-signing.sh* && $out != *Compiling* ]]'

# setup-signing.sh says what each dialog or prompt wants just before it: the trust dialogs here, from the script (run,
# they'd change trust), and the new keychain's password below, from a run too. The code line before a command:
before() {
    awk -v cmd="$1" '/^[[:space:]]*#/ { next } index($0, cmd) { print prev } { prev = $0 }' scripts/setup-signing.sh
}
trust_line='macOS now asks for your Mac login password (the one you log in with) to change certificate trust. $1'
check "macOS's trust dialog is named as asking for the Mac login password" \
    'grep -F "echo \"$trust_line\"" scripts/setup-signing.sh >/dev/null'
check "it's announced before the new certificate is trusted, with what Cancel leaves" \
    '[[ $(before "security add-trusted-cert") == *"trust_dialog \"Cancel is safe: the certificate just stays untrusted and macOS asks for permissions again after each rebuild.\"" ]]'
check "and before the old certificate is untrusted" '[[ $(before "security remove-trusted-cert") == *"trust_dialog \"Cancel is safe: "* ]]'
check "a NEW password is asked for just before create-keychain" \
    '[[ $(before "security create-keychain") == *"Choose a NEW password for the signing keychain and type it twice"* ]]'

# The search-list block: the same in both scripts; what its exit hook writes back, run with a stand-in security that
# prints the list it's given, one keychain a line. restored SCRIPT CODE: after CODE, which sets SEARCH_LIST.
search_block() { sed -n '/^# --- The keychain search list/,/^# --- end of the keychain search list ---/p' "$1"; }
check "the search-list block is the same in setup-signing.sh and build-app.sh" \
    '[[ -n $(search_block scripts/setup-signing.sh) && $(search_block scripts/setup-signing.sh) == "$(search_block scripts/build-app.sh)" ]]'
unit_home="$work/unit-home"
mkdir -p "$unit_home/Library/Keychains"
restored() {
    HOME="$unit_home" /bin/bash -c 'set -euo pipefail; eval "$1"
        security() { [[ "$*" == "list-keychains -d user -s "* ]] && shift 4 && printf "%s\n" "$@"; }
        eval "$2"; SEARCH_LIST_CHANGED=1; restore_search_list_on_exit' _ "$(search_block "$1")" "$2"
}
login="$unit_home/Library/Keychains/login.keychain-db"
canonical_login="$(cd "$unit_home/Library/Keychains" && pwd -P)/login.keychain-db"
other=/elsewhere/other.keychain-db
signing_kc="$unit_home/.vibeswitcher/signing/vibeswitcher.keychain-db"
nl=$'\n'
for script in scripts/setup-signing.sh scripts/build-app.sh; do
    check "${script#scripts/}'s exit hook writes the login keychain back when the list read is empty" \
        '[[ $(restored $script "SEARCH_LIST=()") == "$login" ]]'
    check "and when it's lost" '[[ $(restored $script "unset SEARCH_LIST") == "$login" ]]'
    check "and puts it first when the list has others but not it, leaving the signing keychain out" \
        '[[ $(restored $script "SEARCH_LIST=($other /private$signing_kc)") == "$login$nl$other" ]]'
    check "and keeps the list's order and spelling, the login keychain where it was" \
        '[[ $(restored $script "SEARCH_LIST=($other $canonical_login $signing_kc)") == "$other$nl$canonical_login" ]]'
    check "and writes nothing when the list wasn't changed" \
        '[[ -z $(HOME="$unit_home" /bin/bash -c '\''eval "$1"; security() { echo written; }; restore_search_list_on_exit'\'' _ "$(search_block $script)") ]]'
done

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

    # A search list of the user's own: the scratch HOME's login keychain and one more, which the scripts must leave as
    # it was.
    printf 'login\nlogin\n' | run no_tty security create-keychain "$home/Library/Keychains/login.keychain-db" >/dev/null 2>&1
    printf 'placeholder\nplaceholder\n' | run no_tty security create-keychain "$work/placeholder.keychain-db" >/dev/null 2>&1
    run security list-keychains -d user -s "$home/Library/Keychains/login.keychain-db" "$work/placeholder.keychain-db"
    search_list=$(run security list-keychains -d user)
    # Whether the scratch search list holds its login keychain (security names it by its real path: no // from a TMPDIR
    # ending in /, /private or not).
    home_login="$(cd "$home/Library/Keychains" && pwd -P)/login.keychain-db"
    has_login() { run security list-keychains -d user | grep -F "${home_login#/private}\"" >/dev/null; }
    check "the scratch search list starts with its login keychain in it" 'has_login'

    # security, first on the scripts' PATH: logs to $SIGNING_CALLS what changes the search list (a write: add, with the
    # signing keychain, restore, without it, no-login, without the login keychain; create-keychain, delete-keychain,
    # import), and with SEARCH_LIST_READ reads the list as empty, fails to read it, or reads one without the login
    # keychain.
    mkdir "$work/bin"
    cat > "$work/bin/security" <<'EOF'
#!/bin/bash
if [[ "$*" == "list-keychains -d user" ]]; then
    case ${SEARCH_LIST_READ:-} in
        empty) exit 0;;
        failed) echo "security: SecKeychainCopyDomainSearchList: stand-in failure" >&2; exit 1;;
        no-login) echo "    \"$SEARCH_LIST_OTHER\""; exit 0;;
    esac
fi
if [[ -n ${SIGNING_CALLS:-} ]]; then
    case ${1:-} in
        list-keychains)
            if [[ " $* " == *" -s "* ]]; then
                if [[ "$*" != */login.keychain-db* ]]; then echo no-login
                elif [[ "$*" == *vibeswitcher.keychain-db* ]]; then echo add
                else echo restore; fi >> "$SIGNING_CALLS"
            fi;;
        create-keychain|delete-keychain|import) echo "$1" >> "$SIGNING_CALLS";;
    esac
fi
exec /usr/bin/security "$@"
EOF
    chmod +x "$work/bin/security"
    calls() { tr '\n' ' ' < "$work/calls" | sed 's/ $//'; }
    export SEARCH_LIST_OTHER="$work/placeholder.keychain-db"
    # What a script stopped on its search list says: that nothing changed, and what it read.
    said() {
        case $2 in
            empty) [[ $(cat "$1") == *"doesn't have your login keychain"*"Nothing was changed."*"(nothing)"* ]];;
            failed) [[ $(cat "$1") == *"Couldn't read your keychain search list"*"Nothing was changed."* ]];;
            no-login) [[ $(cat "$1") == *"doesn't have your login keychain"*"Nothing was changed."*"    $SEARCH_LIST_OTHER"* ]];;
        esac
    }

    # An earlier setup: its keychain and the password file beside it.
    mkdir -p "$signing"
    printf 'old-password\nold-password\n' | run no_tty security create-keychain "$keychain" >/dev/null 2>&1
    printf 'old-password' > "$signing/password"

    # A search list read as empty, one that can't be read and one without the login keychain: setup stops before it
    # changes anything (the earlier setup's keychain and password file stay, and the list).
    for read in empty failed no-login; do
        before=$(run security list-keychains -d user)
        : > "$work/calls"
        printf 'test-password\ntest-password\n' | PATH="$work/bin:$PATH" SEARCH_LIST_READ=$read SIGNING_CALLS="$work/calls" \
            run no_tty scripts/setup-signing.sh --no-trust > "$work/refused.log" 2>&1
        status=$?
        check "a search list read $read stops setup-signing.sh, changing nothing" \
            '[[ $status -ne 0 && ! -s $work/calls && -f $keychain && -f $signing/password ]] &&
             [[ $(run security list-keychains -d user) == "$before" ]] && ! grep Replacing "$work/refused.log" >/dev/null'
        check "and it says what it saw" 'said "$work/refused.log" $read'
    done

    # Ctrl-C at the new keychain's password prompt: a security first on the script's PATH sends SIGINT to its process
    # group, as Terminal would, when asked to create the keychain; anything else goes to the real one.
    mkdir "$work/ctrl-c"
    printf '#!/bin/bash\n[[ "${1:-}" == create-keychain ]] && kill -INT 0\nexec /usr/bin/security "$@"\n' > "$work/ctrl-c/security"
    chmod +x "$work/ctrl-c/security"
    printf 'test-password\ntest-password\n' |
        run env PATH="$work/ctrl-c:$PATH" python3 -I -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
            scripts/setup-signing.sh --no-trust > "$work/stopped.log" 2>&1
    status=$?
    summary() { grep -E "^ +$1: +$2\$" "$work/stopped.log" >/dev/null; }
    check "a setup stopped at the password prompt exits with an error" '[[ $status -ne 0 ]]'
    check "it says the old keychain was removed and the new one not made" \
        'grep -x "Setup stopped before it finished. What was done:" "$work/stopped.log" >/dev/null &&
         summary "old identity untrusted" "no \(--no-trust\)" && summary "old keychain removed" yes &&
         summary "new keychain created" "no.*" && summary "certificate trusted" no'
    check "and that running it again is safe" \
        'grep -x "Running ./scripts/setup-signing.sh again is safe: it continues from there." "$work/stopped.log" >/dev/null'
    check "it leaves no keychain, and keeps the password file" '[[ ! -e $keychain && -f $signing/password ]]'
    check "the search list is as it was after a stopped setup" '[[ $(run security list-keychains -d user) == "$search_list" ]]'
    check "with the login keychain in it" 'has_login'
    out=$(run scripts/build-app.sh </dev/null 2>&1)
    status=$?
    check "build-app.sh then refuses, naming setup-signing.sh" \
        '[[ $status -ne 0 && $out == *"keychain is missing"*setup-signing.sh* && $out != *Compiling* ]]'

    : > "$work/calls"
    printf 'test-password\ntest-password\n' | PATH="$work/bin:$PATH" SIGNING_CALLS="$work/calls" \
        run no_tty scripts/setup-signing.sh --no-trust > "$work/setup.log" 2>&1
    status=$?
    check "setup-signing.sh, run again, finishes replacing an earlier setup" \
        '[[ $status -eq 0 ]] && grep "Created .VibeSwitcher Local Signing. in" "$work/setup.log" >/dev/null'
    # Whether the setup's output has each text, in turn, each after the one before (security's prompts end no line).
    in_order() {
        awk 'BEGIN { n = ARGC - 1; for (i = 1; i <= n; i++) want[i] = ARGV[i]; ARGC = 1 } { text = text $0 "\n" }
             END { for (i = 1; i <= n; i++) { at = index(text, want[i]); if (!at) exit 1; text = substr(text, at + length(want[i])) } }' \
            "$@" < "$work/setup.log"
    }
    check "it announces the old password, the new one and trust in order, each before its step" \
        'in_order "The old keychain'"'"'s password is not needed: that file is read by nobody, and is deleted" \
            "Choose a NEW password for the signing keychain and type it twice; it is never saved; each build after login or wake asks for it once." \
            "password for new keychain:" "Created '"'"'VibeSwitcher Local Signing'"'"' in" "Certificate not trusted (--no-trust)"'
    check "a finished setup prints no summary" '! grep "Setup stopped" "$work/setup.log" >/dev/null'
    check "no password file is left" '[[ ! -e $signing/password && $(ls "$signing") == vibeswitcher.keychain-db ]]'
    check "the keychain is locked after setup" '[[ $(lockstate) == locked ]]'
    check "the search list is as it was" '[[ $(run security list-keychains -d user) == "$search_list" ]] && has_login'
    check "setup puts the search list back as soon as create-keychain has added to it, before the imports" \
        '[[ $(calls) == "create-keychain restore import import" ]]'

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

    # Its lock settings, read only while it's unlocked (reading them from a locked keychain asks you).
    keychain_info() { [[ $(lockstate) == unlocked ]] && run security show-keychain-info "$keychain" 2>&1; }
    check "the keychain locks on sleep, with no inactivity timeout" '[[ $(keychain_info) == *"lock-on-sleep no-timeout" ]]'
    # As an earlier setup-signing.sh left it, locking after 5 minutes too: the first build makes it lock on sleep only.
    run security set-keychain-settings -l -u -t 300 "$keychain"
    run security lock-keychain "$keychain"

    # macOS's dialog, stood in for. codesign makes macOS ask for the password when it uses the key while the keychain
    # is locked; this codesign, first on build-app.sh's PATH, counts that prompt and answers it as you would (unlocks
    # the keychain, the password on stdin), then runs the real one. If the keychain stays locked it stops there, so no
    # dialog is ever put in front of you.
    # It logs each signing to $SIGNING_CALLS, and with SIGNING_INTERRUPT_AT=N stands in for a Ctrl-C at the Nth: SIGINT
    # to its process group, as Terminal would.
    cat > "$work/bin/codesign" <<'EOF'
#!/bin/bash
echo codesign >> "$SIGNING_CALLS"
[[ $(grep -c codesign "$SIGNING_CALLS") -eq ${SIGNING_INTERRUPT_AT:-0} ]] && kill -INT 0
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
    # build N [stops]: runs build-app.sh (which replaces build/VibeSwitcher.app) in a session of its own, its output in
    # $work/buildN.log, what changes the search list and each signing in $work/calls; sets $status and $prompts, the
    # passwords macOS would have asked for. A build that fails, unless it's meant to stop, shows its output's end.
    build() {
        : > "$work/prompts"
        : > "$work/calls"
        run env PATH="$work/bin:$PATH" SIGNING_LOCKSTATE="$work/lockstate" SIGNING_KEYCHAIN="$keychain" \
            SIGNING_PROMPTS="$work/prompts" SIGNING_CALLS="$work/calls" \
            python3 -I -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
            scripts/build-app.sh </dev/null > "$work/build$1.log" 2>&1
        status=$?
        prompts=$(wc -l < "$work/prompts" | tr -d ' ')
        [[ $status -ne 0 && ${2:-} != stops ]] && tail -20 "$work/build$1.log"
    }
    signed() { codesign -dvv "$1" 2>&1 | grep -x "Authority=VibeSwitcher Local Signing" >/dev/null; }

    # A search list read as empty, one that can't be read and one without the login keychain: build-app.sh stops
    # before signing, with nothing changed (codesign never runs, so the keychain stays locked).
    for read in empty failed no-login; do
        before=$(run security list-keychains -d user)
        SEARCH_LIST_READ=$read build "-$read" stops
        check "a search list read $read stops build-app.sh before signing, changing nothing" \
            '[[ $status -ne 0 && ! -s $work/calls && $prompts -eq 0 && $(lockstate) == locked ]] &&
             [[ $(run security list-keychains -d user) == "$before" ]] && ! grep "^Built" "$work/build-$read.log" >/dev/null'
        check "and it says what it saw" 'said "$work/build-$read.log" $read'
    done

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
    check "the search list is put back" '[[ $(run security list-keychains -d user) == "$search_list" ]] && has_login'
    check "the signing keychain is in the search list for the four codesigns alone" \
        '[[ $(calls) == "add codesign codesign codesign codesign restore" ]]'

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
    check "the search list is still as it was" '[[ $(run security list-keychains -d user) == "$search_list" ]] && has_login'

    # Ctrl-C at the second codesign: the exit hook puts the list back.
    SIGNING_INTERRUPT_AT=2 build 4 stops
    check "a Ctrl-C while signing stops the build" \
        '[[ $status -ne 0 && $(calls) == "add codesign codesign restore" ]] && ! grep "^Built" "$work/build4.log" >/dev/null'
    check "and the search list is put back, the login keychain in it" \
        '[[ $(run security list-keychains -d user) == "$search_list" ]] && has_login'
fi

if [[ $failures -gt 0 ]]; then echo "$failures check(s) failed"; exit 1; fi
echo "All signing checks passed"
