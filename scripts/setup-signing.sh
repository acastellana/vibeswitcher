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
# Your login keychain and keychain search list are left as they are.
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

finish() {
    if [[ -n "$WORK" ]]; then
        rm -f "$WORK/cert.cnf" "$WORK/key.pem" "$WORK/cert.pem"
        rmdir "$WORK" 2>/dev/null || true
        # Keep the user's keychain search list exactly as it was (create-keychain adds to it).
        security list-keychains -d user -s ${SEARCH_LIST[@]+"${SEARCH_LIST[@]}"}
        if [[ "$MADE" != 1 ]]; then
            # Don't leave a half-made keychain behind (the build script would try to use it).
            if [[ -f "$KEYCHAIN" ]]; then
                security delete-keychain "$KEYCHAIN" 2>/dev/null || true
                NEW_CREATED="no (the half-made one was removed)"
            fi
            rmdir "$DIR" 2>/dev/null || true
        fi
    fi
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
SEARCH_LIST=()
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%\"}"; line="${line#\"}"
    [[ -n "$line" ]] && SEARCH_LIST+=("$line")
done < <(security list-keychains -d user)
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
# argv, where any process can read it with ps, or in a file.
security create-keychain "$KEYCHAIN"
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
