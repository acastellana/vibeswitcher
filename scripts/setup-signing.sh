#!/bin/bash
# Creates a local, self-signed code-signing identity for VibeSwitcher in its own keychain file
# (~/.vibeswitcher/signing), so every rebuild keeps the same code identity and macOS keeps the
# permissions you granted (Accessibility, Automation of Terminal). Ad-hoc signatures change with
# every build, which silently invalidates those grants.
#
# Your login keychain and keychain search list are left as they are.
# Undo: security delete-keychain ~/.vibeswitcher/signing/vibeswitcher.keychain-db
#       rm -f ~/.vibeswitcher/signing/password && rmdir ~/.vibeswitcher/signing
set -euo pipefail

DIR="$HOME/.vibeswitcher/signing"
KEYCHAIN="$DIR/vibeswitcher.keychain-db"
NAME="VibeSwitcher Local Signing"

if [[ -f "$KEYCHAIN" ]]; then
    echo "Signing identity already set up in $KEYCHAIN"
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
    rm -f "$WORK/cert.cnf" "$WORK/key.pem" "$WORK/cert.pem" "$WORK/identity.p12"
    rmdir "$WORK" 2>/dev/null || true
    # Keep the user's keychain search list exactly as it was.
    security list-keychains -d user -s "${SEARCH_LIST[@]}"
    if [[ "$DONE" != 1 ]]; then
        # Don't leave a half-made keychain behind (the build script would try to use it).
        security delete-keychain "$KEYCHAIN" 2>/dev/null || true
        rm -f "$DIR/password"
        rmdir "$DIR" 2>/dev/null || true
        echo "Setup failed; nothing was left behind." >&2
    fi
}
trap cleanup EXIT

PASSWORD="$(openssl rand -hex 24)"
printf '%s' "$PASSWORD" > "$DIR/password"
chmod 600 "$DIR/password"

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
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
# macOS's importer only reads the older PKCS#12 encryption; OpenSSL 3 needs -legacy for that.
LEGACY=()
if openssl version | grep -q '^OpenSSL 3'; then LEGACY=(-legacy); fi
openssl pkcs12 -export "${LEGACY[@]}" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$WORK/identity.p12" -passout pass:"$PASSWORD"

security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"            # no auto-lock timeout
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
# Let codesign use the key without a GUI prompt.
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
DONE=1
echo "Created '$NAME' in $KEYCHAIN"
