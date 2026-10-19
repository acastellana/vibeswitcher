#!/bin/bash
# Creates a local, self-signed code-signing identity for VibeSwitcher in its own keychain file
# (~/.vibeswitcher/signing), so every rebuild keeps the same code identity and macOS keeps the
# permissions you granted (Accessibility, Automation of Terminal). Ad-hoc signatures change with
# every build, which silently invalidates those grants.
#
# Nothing signs as VibeSwitcher without you: the key can't be exported, only /usr/bin/codesign may use
# it, and its keychain stays locked except while build-app.sh signs. Its password is one you choose here
# (`security` asks for it; it's never saved or passed on a command line) and type when a build asks.
#
# The certificate is then trusted for code signing (for your user only; macOS asks for your password):
# without that trust, macOS pins each permission to the exact build anyway.
#
# A signing keychain made by an earlier version of this script (its password saved in
# ~/.vibeswitcher/signing/password, its key exportable) is replaced: macOS asks for VibeSwitcher's
# permissions once more.
#
# --no-trust: don't trust the certificate, or untrust a replaced one (scripts/test-signing.sh, on a scratch HOME).
#
# Your login keychain and keychain search list are left as they are.
# Undo: security remove-trusted-cert <(security find-certificate -c "VibeSwitcher Local Signing" -p \
#           ~/.vibeswitcher/signing/vibeswitcher.keychain-db)
#       security delete-keychain ~/.vibeswitcher/signing/vibeswitcher.keychain-db
#       rmdir ~/.vibeswitcher/signing
set -euo pipefail

DIR="$HOME/.vibeswitcher/signing"
KEYCHAIN="$DIR/vibeswitcher.keychain-db"
NAME="VibeSwitcher Local Signing"
BUNDLE_ID="dev.vibeswitcher.VibeSwitcher"
TRUST=1
[[ "${1:-}" == "--no-trust" ]] && TRUST=0

trust_certificate() {
    [[ "$TRUST" == 1 ]] || { echo "Certificate not trusted (--no-trust)"; return; }
    local pem
    pem="$(mktemp)"
    security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$pem"
    if security verify-cert -c "$pem" -p codeSign >/dev/null 2>&1; then
        echo "Certificate already trusted for code signing"
    elif security add-trusted-cert -r trustRoot -p codeSign "$pem"; then
        echo "Certificate trusted for code signing"
    else
        echo "Not trusted: macOS will ask for permissions again after each rebuild." >&2
    fi
    rm -f "$pem"
}

if [[ -f "$DIR/password" ]]; then
    # Made by an earlier version: any process running as you could read the password and sign with (or
    # export) the key. A key that may have been copied can't be made safe, so it's replaced.
    echo "Replacing the signing identity in $KEYCHAIN: its password was saved in $DIR/password."
    if [[ -f "$KEYCHAIN" ]]; then
        if [[ "$TRUST" == 1 ]]; then
            OLD="$(mktemp)"
            if security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$OLD" 2>/dev/null; then
                security remove-trusted-cert "$OLD" 2>/dev/null && echo "Old certificate no longer trusted"
            fi
            rm -f "$OLD"
        fi
        security delete-keychain "$KEYCHAIN"
    fi
    rm -f "$DIR/password"
    cat <<EOF
macOS still holds the permissions you gave builds signed with the old identity. To drop them, and allow
the next build again when it asks:
    tccutil reset Accessibility $BUNDLE_ID
    tccutil reset AppleEvents $BUNDLE_ID
EOF
fi

if [[ -f "$KEYCHAIN" ]]; then
    echo "Signing identity already set up in $KEYCHAIN"
    trust_certificate
    exit 0
fi

mkdir -p "$DIR"
chmod 700 "$DIR"
WORK="$(mktemp -d)"
DONE=0
SEARCH_LIST=()
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%\"}"; line="${line#\"}"
    [[ -n "$line" ]] && SEARCH_LIST+=("$line")
done < <(security list-keychains -d user)

cleanup() {
    rm -f "$WORK/cert.cnf" "$WORK/key.pem" "$WORK/cert.pem"
    rmdir "$WORK" 2>/dev/null || true
    # Keep the user's keychain search list exactly as it was (create-keychain adds to it).
    security list-keychains -d user -s ${SEARCH_LIST[@]+"${SEARCH_LIST[@]}"}
    if [[ "$DONE" != 1 ]]; then
        # Don't leave a half-made keychain behind (the build script would try to use it).
        security delete-keychain "$KEYCHAIN" 2>/dev/null || true
        rmdir "$DIR" 2>/dev/null || true
        echo "Setup failed; nothing was left behind." >&2
    fi
}
trap cleanup EXIT

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

echo "Choose a password for the signing keychain. Each build asks for it, in a dialog, before it signs."
# No -p: security asks for it (on the terminal; read from stdin when there's none), so it never sits in
# argv, where any process can read it with ps, or in a file.
security create-keychain "$KEYCHAIN"
# Lock on sleep and after 5 minutes, in case a build ends without locking it.
security set-keychain-settings -l -u -t 300 "$KEYCHAIN"
# The new keychain is unlocked. -x: the key can never be exported; -T: only codesign uses it without
# asking you (anything else that tries gets a prompt, even while the keychain is unlocked).
security import "$WORK/key.pem" -k "$KEYCHAIN" -x -T /usr/bin/codesign >/dev/null
security import "$WORK/cert.pem" -k "$KEYCHAIN" >/dev/null
security lock-keychain "$KEYCHAIN"
DONE=1
echo "Created '$NAME' in $KEYCHAIN"
trust_certificate
