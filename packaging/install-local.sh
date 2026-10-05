#!/usr/bin/env bash
#
# Build, sign and (re)install wacomd for the current user :
#   - daemon  → ~/Library/Application Support/wacomd/wacomd  (LaunchAgent com.local.wacomd)
#   - config  → ~/Applications/Wacomd Config.app
#
# macOS ties Accessibility / Input Monitoring grants to the code signature.
# An ad-hoc signature changes on every build, so the grants would be lost
# each time : the daemon is signed with a real identity instead, taken from
# $WACOMD_SIGN_ID, else from the currently installed binary, else the first
# "Apple Development" certificate of the keychain.
#
# Usage : ./packaging/install-local.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="$HOME/Library/Application Support/wacomd"
DEST_BIN="$DEST_DIR/wacomd"
PLIST="$HOME/Library/LaunchAgents/com.local.wacomd.plist"
LABEL="com.local.wacomd"
DOMAIN="gui/$(id -u)"

echo "==> Build release"
swift build -c release --package-path "$REPO_DIR" 2>&1 | grep -v "ld: warning" | grep -v "not found$" || true
[ -x "$REPO_DIR/.build/release/wacomd" ] || { echo "✗ build failed"; exit 1; }

# ---- Signing identity -------------------------------------------------------
SIGN_ID="${WACOMD_SIGN_ID:-}"
if [ -z "$SIGN_ID" ] && [ -f "$DEST_BIN" ]; then
    SIGN_ID="$(codesign -dvv "$DEST_BIN" 2>&1 | sed -n 's/^Authority=\(Apple Development: .*\)$/\1/p' | head -1)"
fi
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)"
fi

echo "==> Install daemon to $DEST_BIN"
mkdir -p "$DEST_DIR"
cp "$REPO_DIR/.build/release/wacomd" "$DEST_BIN.new"
if [ -n "$SIGN_ID" ]; then
    echo "    signing with « $SIGN_ID »"
    codesign --force --sign "$SIGN_ID" --identifier "$LABEL" --options runtime "$DEST_BIN.new"
else
    echo "    ⚠ no Apple Development certificate : ad-hoc signature,"
    echo "      permissions will have to be granted again after each install"
    codesign --force --sign - --identifier "$LABEL" "$DEST_BIN.new"
fi
mv -f "$DEST_BIN.new" "$DEST_BIN"

# ---- LaunchAgent --------------------------------------------------------------
if [ ! -f "$PLIST" ]; then
    echo "==> Create LaunchAgent $PLIST"
    mkdir -p "$(dirname "$PLIST")"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>             <string>$LABEL</string>
    <key>ProgramArguments</key>  <array><string>$DEST_BIN</string></array>
    <key>RunAtLoad</key>         <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key> <false/>
        <key>Crashed</key>        <true/>
    </dict>
    <key>ThrottleInterval</key>  <integer>5</integer>
    <key>ProcessType</key>       <string>Interactive</string>
    <key>StandardOutPath</key>   <string>/tmp/wacomd.log</string>
    <key>StandardErrorPath</key> <string>/tmp/wacomd.log</string>
</dict>
</plist>
EOF
fi

echo "==> (Re)start $LABEL"
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    launchctl kickstart -k "$DOMAIN/$LABEL"
else
    launchctl bootstrap "$DOMAIN" "$PLIST"
    launchctl enable "$DOMAIN/$LABEL"
fi

# ---- Config app -----------------------------------------------------------------
echo "==> Build Wacomd Config.app"
"$REPO_DIR/packaging/build-app.sh" >/dev/null
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Wacomd Config.app"
cp -R "$REPO_DIR/build/Wacomd Config.app" "$HOME/Applications/"

sleep 2
echo
grep -E "Accessibilit|Surveillance" /tmp/wacomd.log | tail -2 || true
echo "✓ Installed. Settings : open \"$HOME/Applications/Wacomd Config.app\""
