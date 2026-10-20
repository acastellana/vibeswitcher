#!/bin/bash
# Builds build/VibeSwitcher.app. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/scratch.sh

SIGNING_DIR="$HOME/.vibeswitcher/signing"
# Made by an earlier setup-signing.sh: don't sign with a key any process running as you could use.
# Its password file stays until setup-signing.sh has made the new keychain, so a replacement that stopped
# half way (the old keychain removed, the new one not made) is refused too, rather than built ad-hoc.
if [[ -f "$SIGNING_DIR/password" ]]; then
    if [[ -f "$SIGNING_DIR/vibeswitcher.keychain-db" ]]; then
        echo "The signing keychain's password is saved in $SIGNING_DIR/password, where any process running as you" >&2
        echo "can read it and sign as VibeSwitcher. Run ./scripts/setup-signing.sh in Terminal to replace it." >&2
    else
        echo "The signing keychain is missing: ./scripts/setup-signing.sh stopped while replacing it (the old one is" >&2
        echo "removed, the new one isn't made). Run ./scripts/setup-signing.sh in Terminal again to finish it." >&2
    fi
    exit 1
fi

scratch_tmpdir vs-build
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="build/VibeSwitcher.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/VibeSwitcher" "$BIN/vibeswitcher-hook" "$BIN/vibeswitcher-host" "$BIN/vibeswitcher-mcp" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The phone web app (Phone Access), served by the app itself.
mkdir -p "$APP/Contents/Resources"
cp -R Web "$APP/Contents/Resources/Web"
# SwiftPM resource bundles (SwiftTerm's Metal shaders); found through Bundle.main.resourceURL.
for bundle in "$BIN"/*.bundle; do [[ -e "$bundle" ]] && cp -R "$bundle" "$APP/Contents/Resources/"; done
# Sign with the stable local identity if it exists (scripts/setup-signing.sh), so macOS keeps granted
# permissions across rebuilds; otherwise ad-hoc, which changes identity on every build.
if [[ -f "$SIGNING_DIR/vibeswitcher.keychain-db" ]]; then
    KEYCHAIN="$SIGNING_DIR/vibeswitcher.keychain-db"
    # A self-signed certificate isn't "trusted", so codesign won't find it by name; its hash works.
    # (Certificates are readable while the keychain is locked.)
    HASH="$(security find-identity -p codesigning "$KEYCHAIN" | awk '/VibeSwitcher Local Signing/ {print $2; exit}')"
    IDENTITY=(--sign "$HASH" --keychain "$KEYCHAIN")
    # codesign only finds the key while its keychain is in the search list: add it for the signing
    # step and always put the user's list back.
    ORIGINAL_LIST=()
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%\"}"; line="${line#\"}"
        [[ -n "$line" ]] && ORIGINAL_LIST+=("$line")
    done < <(security list-keychains -d user)
    on_exit 'security list-keychains -d user -s ${ORIGINAL_LIST[@]+"${ORIGINAL_LIST[@]}"}'
    security list-keychains -d user -s ${ORIGINAL_LIST[@]+"${ORIGINAL_LIST[@]}"} "$KEYCHAIN"
    # The keychain locks when the Mac sleeps and when you log out, and stays unlocked otherwise. While it's
    # locked, codesign's first use of the key makes macOS ask you for its password (the one you chose in
    # setup-signing.sh), so nothing signs as VibeSwitcher without you having unlocked it this session.
    echo "Signing: at the first build since you logged in or woke the Mac, macOS asks for the signing keychain's password."
else
    IDENTITY=(--sign -)
fi
codesign --force "${IDENTITY[@]}" "$APP/Contents/MacOS/vibeswitcher-hook"
codesign --force "${IDENTITY[@]}" "$APP/Contents/MacOS/vibeswitcher-host"
codesign --force "${IDENTITY[@]}" "$APP/Contents/MacOS/vibeswitcher-mcp"
codesign --force "${IDENTITY[@]}" "$APP"
# A keychain made by setup-signing.sh before it kept the keychain unlocked between builds locks after 5
# minutes: let it lock on sleep only. It's unlocked now (codesign just used it), so this asks nothing.
if [[ -n "${KEYCHAIN:-}" ]] && security show-keychain-info "$KEYCHAIN" 2>&1 | grep -E 'timeout=300s$' >/dev/null; then
    security set-keychain-settings -l "$KEYCHAIN"
    echo "The signing keychain now stays unlocked until the Mac sleeps or you log out (it locked after 5 minutes)."
fi
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x VibeSwitcher 2>/dev/null || true
    # Wait for it to finish quitting: `open` on an app that's still quitting is silently dropped.
    for _ in $(seq 1 50); do pgrep -x VibeSwitcher >/dev/null || break; sleep 0.2; done
    rm -rf /Applications/VibeSwitcher.app
    cp -R "$APP" /Applications/
    open /Applications/VibeSwitcher.app
    echo "Installed and launched /Applications/VibeSwitcher.app"
fi
