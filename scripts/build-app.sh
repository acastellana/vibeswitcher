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
# Ad-hoc signature: enough for local use and for macOS to remember the Automation permission.
codesign --force --sign - "$APP/Contents/MacOS/vibeswitcher-hook"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x VibeSwitcher 2>/dev/null || true
    rm -rf /Applications/VibeSwitcher.app
    cp -R "$APP" /Applications/
    open /Applications/VibeSwitcher.app
    echo "Installed and launched /Applications/VibeSwitcher.app"
fi
