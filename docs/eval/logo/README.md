# App logo concepts

Drawn by `scripts/app-icon.swift` (CoreGraphics, nothing installed): `swift scripts/app-icon.swift concepts docs/eval/logo`
redraws every file here. `overview.png` puts the concepts side by side; for each one, `*-1024.png` is the master,
`*-sizes.png` the same concept drawn at 256, 64, 32 and 16 (on light and dark, and 32/16 enlarged), and
`*-dock-light.png` / `*-dock-dark.png` a mock of it in the Dock among macOS's own apps.

- **A · Stack**: stacked sessions; the front one needs you, behind it one works and one is done.
- **B · Team**: a lead, ringed like the session you're viewing in the menu bar, linked to its team of three.
- **C · Dial**: a rotary switch whose knob points at the session that needs you.
- **D · Prompt**: a terminal prompt whose cursor is the "needs you" mark.

The status marks and colours are the app's own (`StatusMark`, `StatusPalette` in Sources/VibeCore/MenuBarDots.swift).

Picked: **A · Stack** (2026-10-27). It is the app's icon now: `bash scripts/app-icon.sh` redraws Resources/AppIcon.icns
and the phone's Web/icon-192.png and Web/icon-512.png from the same code.
