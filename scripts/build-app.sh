#!/bin/bash
# Builds build/VibeSwitcher.app. Pass --install to copy it to /Applications and launch it.
#
# The keychain search list is the list of keychains macOS apps look in for their passwords, and store new ones in (Chrome
# its Safe Storage key, for one); `security list-keychains -d user` shows it. codesign finds the signing key only while
# its keychain is in the list, so the list is read just before signing, the signing keychain added, and the list read
# put back right after the last codesign (on an error or Ctrl-C while signing, by the exit hook): the signing keychain
# is in it for those seconds alone. The login keychain is never removed from it: the build stops before signing if the
# list can't be read or doesn't hold ~/Library/Keychains/login.keychain-db, and every list it writes holds it (an empty
# list is what makes Chrome say "Keychain Not Found").
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/scratch.sh

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
# One build or test run at a time on this Mac, every project's included (Resources/bin/vs-heavy): the build waits while
# another holds the lock, saying for whom.
Resources/bin/vs-heavy --as scripts/build-app.sh swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="build/VibeSwitcher.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/VibeSwitcher" "$BIN/vibeswitcher-hook" "$BIN/vibeswitcher-host" "$BIN/vibeswitcher-mcp" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The phone web app (Phone Access), served by the app itself.
mkdir -p "$APP/Contents/Resources"
cp -R Web "$APP/Contents/Resources/Web"
# The app's icon (CFBundleIconFile in Info.plist), drawn by scripts/app-icon.sh.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# vs-heavy, on PATH in every session the app starts (the session host puts this folder first).
mkdir -p "$APP/Contents/Resources/bin"
cp Resources/bin/vs-heavy "$APP/Contents/Resources/bin/vs-heavy"
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
    # The keychain locks when the Mac sleeps and when you log out, and stays unlocked otherwise. While it's
    # locked, codesign's first use of the key makes macOS ask you for its password (the one you chose in
    # setup-signing.sh), so nothing signs as VibeSwitcher without you having unlocked it this session.
    echo "Signing: at the first build since you logged in or woke the Mac, macOS asks for the signing keychain's password."
else
    IDENTITY=(--sign -)
fi
sign() {
    # Keep DYLD environment injection and foreign libraries disabled for the app and every helper.
    codesign --force --options runtime "${IDENTITY[@]}" "$APP/Contents/MacOS/vibeswitcher-hook"
    # The host may hold the microphone for its sessions' Claude Code (Resources/VibeSwitcherHost.entitlements).
    codesign --force --options runtime --entitlements Resources/VibeSwitcherHost.entitlements "${IDENTITY[@]}" "$APP/Contents/MacOS/vibeswitcher-host"
    codesign --force --options runtime "${IDENTITY[@]}" "$APP/Contents/MacOS/vibeswitcher-mcp"
    # The app alone sends Apple Events (Terminal, Chrome): the hardened runtime refuses them without the entitlement.
    codesign --force --options runtime --entitlements Resources/VibeSwitcher.entitlements "${IDENTITY[@]}" "$APP"
}
if [[ -n "${KEYCHAIN:-}" ]]; then
    # codesign only finds the key while its keychain is in the search list: it's there for the four codesigns alone.
    read_search_list
    on_exit restore_search_list_on_exit
    search_list_to_restore
    SEARCH_LIST_CHANGED=1
    security list-keychains -d user -s "${RESTORE_LIST[@]}" "$KEYCHAIN"
    sign
    restore_search_list
else
    sign
fi
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
