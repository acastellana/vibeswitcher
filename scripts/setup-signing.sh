#!/bin/bash
# Creates a local, self-signed code-signing identity for VibeSwitcher in its own keychain file
# (~/.vibeswitcher/signing), so every rebuild keeps the same code identity and macOS keeps the
# permissions you granted (Accessibility, Automation of Terminal). Ad-hoc signatures change with
# every build, which silently invalidates those grants.
#
# Nothing signs as VibeSwitcher without you: the key can't be exported, only /usr/bin/codesign may use
# it, and its keychain is locked until you unlock it. Its password is one you choose here (`security` asks
# for it; it's never saved or passed on a command line) and type when macOS asks: at the first build after
# you log in or wake the Mac. The keychain then stays unlocked, so later builds don't ask, until the Mac
# sleeps or you log out.
#
# The certificate is then trusted for code signing (for your user only; macOS asks for your Mac login
# password): without that trust, macOS pins each permission to the exact build anyway.
#
# Before each dialog or prompt it says, in one line, what will appear and which password it wants. If a step
# is cancelled or fails (or you press Ctrl-C), it says what was done and what wasn't; running it again is safe
# and continues from there.
#
# A signing keychain made by an earlier version of this script (its password saved in
# ~/.vibeswitcher/signing/password, its key exportable) is replaced, without its password: macOS asks for
# VibeSwitcher's permissions once more. The password file is deleted once the new keychain is made, so
# build-app.sh keeps refusing to build until the replacement is finished.
#
# --no-trust: don't trust the certificate, or untrust a replaced one (scripts/test-signing.sh, on a scratch HOME).
#
# The keychain search list is the list of keychains macOS apps look in for their passwords, and store new ones in (Chrome
# its Safe Storage key, for one); `security list-keychains -d user` shows it. create-keychain adds the new keychain to
# it, and nothing here needs it there, so the list read at the start is put back the moment the keychain is made, and
# again on any exit (an error, Ctrl-C) while it's changed. The login keychain is never removed from it: the script
# stops before changing anything if the list can't be read or doesn't hold ~/Library/Keychains/login.keychain-db, and
# the list it writes back always holds it (an empty list is what makes Chrome say "Keychain Not Found").
#
# Your login keychain is left as it is.
# Undo: security remove-trusted-cert <(security find-certificate -c "VibeSwitcher Local Signing" -p \
#           ~/.vibeswitcher/signing/vibeswitcher.keychain-db)
#       security delete-keychain ~/.vibeswitcher/signing/vibeswitcher.keychain-db
#       rmdir ~/.vibeswitcher/signing
set -euo pipefail
source "$(dirname "$0")/lib/scratch.sh"

DIR="$HOME/.vibeswitcher/signing"
KEYCHAIN="$DIR/vibeswitcher.keychain-db"
NAME="VibeSwitcher Local Signing"
BUNDLE_ID="dev.vibeswitcher.VibeSwitcher"
TRUST=1
[[ "${1:-}" == "--no-trust" ]] && TRUST=0

# What has been done so far, for the summary printed if the script stops before the end (DONE=1).
OLD_UNTRUSTED="not needed (no earlier setup)"
OLD_REMOVED="not needed (no earlier setup)"
NEW_CREATED="no"
NEW_TRUSTED="no"
DONE=0
MADE=0
WORK=""

# --- The keychain search list (this block is the same in setup-signing.sh and build-app.sh; test-signing.sh checks) ---
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
SEARCH_LIST=()
RESTORE_LIST=()
# 1 from just before the script changes the search list until it has put it back: the exit hook restores it then.
SEARCH_LIST_CHANGED=0

# Whether $1 names the login keychain (security names one under /tmp or /var by its /private path).
is_login_keychain() {
    [[ "$1" == "$LOGIN_KEYCHAIN" || "$1" == "$(cd "$HOME/Library/Keychains" 2>/dev/null && pwd -P)/login.keychain-db" ]]
}

# Reads the user's search list into SEARCH_LIST. Stops the script, before it has changed anything, when security
# can't read it or the login keychain isn't in it: that list, written back, would leave apps nowhere to keep passwords.
read_search_list() {
    local listed line entry list=() login=0
    if ! listed="$(security list-keychains -d user)"; then
        echo "Couldn't read your keychain search list (security list-keychains -d user failed). Nothing was changed." >&2
        exit 1
    fi
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%\"}"; line="${line#\"}"
        [[ -n "$line" ]] && list+=("$line")
    done <<<"$listed"
    for entry in ${list[@]+"${list[@]}"}; do is_login_keychain "$entry" && login=1; done
    if [[ "$login" != 1 ]]; then
        echo "Your keychain search list doesn't have your login keychain ($LOGIN_KEYCHAIN) in it. Nothing was changed." >&2
        echo "security list-keychains -d user listed:" >&2
        if [[ ${#list[@]} -gt 0 ]]; then printf '    %s\n' "${list[@]}" >&2; else echo "    (nothing)" >&2; fi
        echo "Put it back with: security list-keychains -d user -s ~/Library/Keychains/login.keychain-db, followed by" >&2
        echo "any other keychain listed above you want kept. Then run this again." >&2
        exit 1
    fi
    SEARCH_LIST=("${list[@]}")
}

# RESTORE_LIST: the list read, without the signing keychain (one an interrupted run left goes too), and always with the
# login keychain: first when the list read is empty or lost.
search_list_to_restore() {
    local entry login=0
    RESTORE_LIST=()
    for entry in ${SEARCH_LIST[@]+"${SEARCH_LIST[@]}"}; do
        [[ "$entry" == */.vibeswitcher/signing/vibeswitcher.keychain-db ]] && continue
        is_login_keychain "$entry" && login=1
        RESTORE_LIST+=("$entry")
    done
    [[ "$login" == 1 ]] || RESTORE_LIST=("$LOGIN_KEYCHAIN" ${RESTORE_LIST[@]+"${RESTORE_LIST[@]}"})
}

restore_search_list() {
    search_list_to_restore
    if security list-keychains -d user -s "${RESTORE_LIST[@]}"; then
        SEARCH_LIST_CHANGED=0
    else
        echo "Couldn't put your keychain search list back. Run: security list-keychains -d user -s $(printf "%q " "${RESTORE_LIST[@]}")" >&2
        return 1
    fi
}

# The exit hook (normal exit, error, Ctrl-C): puts the list back if the script changed it and hasn't yet.
restore_search_list_on_exit() {
    [[ "$SEARCH_LIST_CHANGED" != 1 ]] || restore_search_list || true
}
# --- end of the keychain search list ---

read_search_list

finish() {
    if [[ -n "$WORK" ]]; then
        rm -f "$WORK/cert.cnf" "$WORK/key.pem" "$WORK/cert.pem"
        rmdir "$WORK" 2>/dev/null || true
        if [[ "$MADE" != 1 ]]; then
            # Don't leave a half-made keychain behind (the build script would try to use it).
            if [[ -f "$KEYCHAIN" ]]; then
                security delete-keychain "$KEYCHAIN" 2>/dev/null || true
                NEW_CREATED="no (the half-made one was removed)"
            fi
            rmdir "$DIR" 2>/dev/null || true
        fi
    fi
    restore_search_list_on_exit
    [[ "$DONE" == 1 ]] && return
    cat >&2 <<EOF

Setup stopped before it finished. What was done:
    old identity untrusted:  $OLD_UNTRUSTED
    old keychain removed:    $OLD_REMOVED
    new keychain created:    $NEW_CREATED
    certificate trusted:     $NEW_TRUSTED
Running ./scripts/setup-signing.sh again is safe: it continues from there.
EOF
}
on_exit finish

trust_dialog() {
    echo "macOS now asks for your Mac login password (the one you log in with) to change certificate trust. $1"
}

trust_certificate() {
    [[ "$TRUST" == 1 ]] || { NEW_TRUSTED="no (--no-trust)"; echo "Certificate not trusted (--no-trust)"; return; }
    local pem
    pem="$(mktemp)"
    security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$pem"
    if security verify-cert -c "$pem" -p codeSign >/dev/null 2>&1; then
        NEW_TRUSTED="yes (already)"
        echo "Certificate already trusted for code signing"
    else
        trust_dialog "Cancel is safe: the certificate just stays untrusted and macOS asks for permissions again after each rebuild."
        if security add-trusted-cert -r trustRoot -p codeSign "$pem"; then
            NEW_TRUSTED="yes"
            echo "Certificate trusted for code signing"
        else
            NEW_TRUSTED="no (cancelled or failed)"
            echo "Not trusted: the signing identity is set up, but macOS will ask for permissions again after each" >&2
            echo "rebuild. Run ./scripts/setup-signing.sh again to trust it: that's all it does then." >&2
        fi
    fi
    rm -f "$pem"
}

REPLACING=0
if [[ -f "$DIR/password" ]]; then
    # Made by an earlier version: any process running as you could read the password and sign with (or
    # export) the key. A key that may have been copied can't be made safe, so it's replaced.
    REPLACING=1
    echo "Replacing the signing identity an earlier setup made: its password was saved in $DIR/password."
    echo "The old keychain's password is not needed: that file is read by nobody, and is deleted once the new keychain is made."
    if [[ -f "$KEYCHAIN" ]]; then
        OLD_UNTRUSTED="no"
        OLD_REMOVED="no"
        if [[ "$TRUST" == 1 ]]; then
            OLD="$(mktemp)"
            if security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$OLD" 2>/dev/null; then
                # Cancelling only leaves the old certificate trusted: its keychain (and key) is removed either way.
                trust_dialog "Cancel is safe: the old certificate just stays trusted, and its keychain is removed anyway."
                if security remove-trusted-cert "$OLD" 2>/dev/null; then
                    OLD_UNTRUSTED="yes"
                    echo "Old certificate no longer trusted"
                else
                    OLD_UNTRUSTED="no (cancelled or failed; it stays trusted)"
                    echo "Old certificate still trusted (cancelled or failed); its keychain is removed anyway."
                fi
            else
                OLD_UNTRUSTED="not needed (no certificate in it)"
            fi
            rm -f "$OLD"
        else
            OLD_UNTRUSTED="no (--no-trust)"
        fi
        security delete-keychain "$KEYCHAIN"
        OLD_REMOVED="yes"
        echo "Old keychain removed"
    else
        OLD_UNTRUSTED="not known (an earlier run removed its keychain)"
        OLD_REMOVED="yes (by an earlier run)"
    fi
    cat <<EOF
macOS still holds the permissions you gave builds signed with the old identity. To drop them, and allow
the next build again when it asks:
    tccutil reset Accessibility $BUNDLE_ID
    tccutil reset AppleEvents $BUNDLE_ID
EOF
fi

if [[ -f "$KEYCHAIN" ]]; then
    NEW_CREATED="yes (already set up)"
    echo "Signing identity already set up in $KEYCHAIN"
    trust_certificate
    DONE=1
    exit 0
fi

mkdir -p "$DIR"
chmod 700 "$DIR"
WORK="$(mktemp -d)"

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" </dev/null 2>/dev/null

echo "Choose a NEW password for the signing keychain and type it twice; it is never saved; each build after login or wake asks for it once."
# No -p: security asks for it (on the terminal; read from stdin when there's none), so it never sits in
# argv, where any process can read it with ps, or in a file. It adds the keychain to the search list, which is put
# back at once: the steps below name the keychain.
SEARCH_LIST_CHANGED=1
security create-keychain "$KEYCHAIN"
restore_search_list
# Lock on sleep (and at logout), with no inactivity timeout: once you've unlocked it at a build, later
# builds sign without asking until the Mac sleeps.
security set-keychain-settings -l "$KEYCHAIN"
# The new keychain is unlocked. -x: the key can never be exported; -T: only codesign uses it without
# asking you (anything else that tries gets a prompt, even while the keychain is unlocked).
security import "$WORK/key.pem" -k "$KEYCHAIN" -x -T /usr/bin/codesign >/dev/null
security import "$WORK/cert.pem" -k "$KEYCHAIN" >/dev/null
security lock-keychain "$KEYCHAIN"
MADE=1
NEW_CREATED="yes"
[[ "$REPLACING" == 1 ]] && rm -f "$DIR/password"
echo "Created '$NAME' in $KEYCHAIN"
trust_certificate
DONE=1
