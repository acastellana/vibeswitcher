#!/bin/bash
# Redraws VibeSwitcher's icon from its source, scripts/app-icon.swift: Resources/AppIcon.icns (the Dock, Finder,
# Cmd-Tab and notifications; build-app.sh copies it into the app) and Web/icon-192.png, Web/icon-512.png (the phone web
# app's, served by WebAssets). Run it after changing the drawing, and commit what it writes.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/scratch.sh
# The swift interpreter leaves its temporary folders in TMPDIR, and the .iconset is drawn there too.
scratch_tmpdir vs-app-icon

ICONSET="$tool_scratch/AppIcon.iconset"
swift scripts/app-icon.swift iconset "$ICONSET"
iconutil --convert icns --output Resources/AppIcon.icns "$ICONSET"
swift scripts/app-icon.swift phone 192 Web/icon-192.png
swift scripts/app-icon.swift phone 512 Web/icon-512.png
echo "Wrote Resources/AppIcon.icns, Web/icon-192.png and Web/icon-512.png"
