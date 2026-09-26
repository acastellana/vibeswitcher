#!/bin/bash
# Builds build/VibeSwitcher.app. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="build/VibeSwitcher.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/VibeSwitcher" "$BIN/vibeswitcher-hook" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Sign with the stable local identity if it exists (scripts/setup-signing.sh), so macOS keeps granted
# permissions across rebuilds; otherwise ad-hoc, which changes identity on every build.
SIGNING_DIR="$HOME/.vibeswitcher/signing"
if [[ -f "$SIGNING_DIR/vibeswitcher.keychain-db" ]]; then
    KEYCHAIN="$SIGNING_DIR/vibeswitcher.keychain-db"
    security unlock-keychain -p "$(cat "$SIGNING_DIR/password")" "$KEYCHAIN"
    # A self-signed certificate isn't "trusted", so codesign won't find it by name; its hash works.
    HASH="$(security find-identity -p codesigning "$KEYCHAIN" | awk '/VibeSwitcher Local Signing/ {print $2; exit}')"
    IDENTITY=(--sign "$HASH" --keychain "$KEYCHAIN")
    # codesign only finds the key while its keychain is in the search list: add it for the signing
    # step and always put the user's list back.
    ORIGINAL_LIST=()
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%\"}"; line="${line#\"}"
        [[ -n "$line" ]] && ORIGINAL_LIST+=("$line")
    done < <(security list-keychains -d user)
    trap 'security list-keychains -d user -s "${ORIGINAL_LIST[@]}"' EXIT
    security list-keychains -d user -s "${ORIGINAL_LIST[@]}" "$KEYCHAIN"
else
    IDENTITY=(--sign -)
fi
codesign --force "${IDENTITY[@]}" "$APP/Contents/MacOS/vibeswitcher-hook"
codesign --force "${IDENTITY[@]}" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x VibeSwitcher 2>/dev/null || true
    rm -rf /Applications/VibeSwitcher.app
    cp -R "$APP" /Applications/
    open /Applications/VibeSwitcher.app
    echo "Installed and launched /Applications/VibeSwitcher.app"
fi
