#!/usr/bin/env bash
#
# Build a double-clickable .pkg installer for wacomd :
#   /Applications/Wacomd Config.app                 ← menu-bar configurator
#   /usr/local/bin/wacomd                            ← daemon binary
#   ~/Library/LaunchAgents/com.local.wacomd.plist   ← per-user LaunchAgent
#
# Also emit a 1024×1024 RGB PNG suitable for App Store Connect.
#
# Usage :
#   ./packaging/build-installer.sh
# Outputs go to `build/`.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_DIR/build"
VERSION="0.8.4"
PKG_ID="com.local.wacomd"
PKG_NAME="wacomd-${VERSION}.pkg"

mkdir -p "$OUT_DIR"

# Pick up signing identities if available.
SIGNING_ENV="$REPO_DIR/packaging/signing.env"
ENTITLEMENTS="$REPO_DIR/packaging/wacomd.entitlements"
if [ -f "$SIGNING_ENV" ]; then
    # shellcheck disable=SC1090
    source "$SIGNING_ENV"
else
    SIGN_APP=""
    SIGN_PKG=""
fi

# ============================================================================
# 1. Build the .app (which also rebuilds the daemon as a side effect)
# ============================================================================
"$REPO_DIR/packaging/build-app.sh"

DAEMON_BIN="$REPO_DIR/.build/release/wacomd"
APP_BUNDLE="$OUT_DIR/Wacomd Config.app"

# Sign the standalone daemon binary that will live at /usr/local/bin/wacomd.
# (The build-app.sh script already signed the copy inside the .app bundle.)
if [ -n "$SIGN_APP" ]; then
    echo "==> Sign daemon binary (Developer ID Application + hardened runtime)"
    codesign --force --options=runtime --timestamp \
             --entitlements "$ENTITLEMENTS" \
             --sign "$SIGN_APP" "$DAEMON_BIN"
    codesign --verify --strict --verbose=2 "$DAEMON_BIN" 2>&1 | tail -2
fi

# ============================================================================
# 2. App Store-ready 1024×1024 RGB PNG (no alpha)
# ============================================================================
echo "==> Emit App Store icon (1024×1024 RGB)"
ICON_SRC="$REPO_DIR/assets/icon.png"
APPSTORE_ICON="$OUT_DIR/AppStoreIcon-1024.png"
if [ -f "$ICON_SRC" ]; then
    # First resize to 1024, then drop alpha by compositing on a dark background
    # matching the icon's bottom area so the rounded-mask look stays clean.
    TMP_RGBA="$OUT_DIR/_icon-1024-rgba.png"
    sips -z 1024 1024 "$ICON_SRC" --out "$TMP_RGBA" >/dev/null 2>&1
    sips -s format png -s formatOptions normal --setProperty hasAlpha false \
         "$TMP_RGBA" --out "$APPSTORE_ICON" >/dev/null 2>&1 || cp "$TMP_RGBA" "$APPSTORE_ICON"
    rm -f "$TMP_RGBA"
    echo "   → $APPSTORE_ICON ($(stat -f '%z' "$APPSTORE_ICON") octets)"
fi

# ============================================================================
# 3. Stage the install payload
# ============================================================================
STAGE="$OUT_DIR/_pkg_root"
SCRIPTS="$OUT_DIR/_pkg_scripts"
echo "==> Stage payload in $STAGE"
rm -rf "$STAGE" "$SCRIPTS"
mkdir -p "$STAGE/Applications"
mkdir -p "$STAGE/usr/local/bin"
mkdir -p "$STAGE/Library/Application Support/wacomd"
mkdir -p "$SCRIPTS"

cp -R "$APP_BUNDLE"  "$STAGE/Applications/"
cp    "$DAEMON_BIN"  "$STAGE/usr/local/bin/wacomd"
chmod +x "$STAGE/usr/local/bin/wacomd"

# LaunchAgent template — postinstall will rewrite the placeholder user path.
cat > "$STAGE/Library/Application Support/wacomd/com.local.wacomd.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>            <string>com.local.wacomd</string>
    <key>ProgramArguments</key> <array><string>/usr/local/bin/wacomd</string></array>
    <key>RunAtLoad</key>        <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key><false/>
        <key>Crashed</key>      <true/>
    </dict>
    <key>ThrottleInterval</key> <integer>5</integer>
    <key>ProcessType</key>      <string>Interactive</string>
    <key>StandardOutPath</key>  <string>/tmp/wacomd.log</string>
    <key>StandardErrorPath</key><string>/tmp/wacomd.log</string>
</dict>
</plist>
EOF

# ============================================================================
# 4. Postinstall script — installs the LaunchAgent into the user's account
# ============================================================================
cat > "$SCRIPTS/postinstall" <<'POST'
#!/bin/bash
set -e

# The pkg runs as root via `installer`. $USER / $HOME point to the installing
# admin user but we actually want the *console* user (the person sitting at
# the Mac). stat the console device to find them.
CONSOLE_USER=$(stat -f '%Su' /dev/console)
CONSOLE_HOME=$(eval echo "~$CONSOLE_USER")

LAUNCH_AGENTS_DIR="$CONSOLE_HOME/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENTS_DIR/com.local.wacomd.plist"

mkdir -p "$LAUNCH_AGENTS_DIR"
cp "/Library/Application Support/wacomd/com.local.wacomd.plist" "$PLIST_PATH"
chown "$CONSOLE_USER" "$PLIST_PATH"
chmod 644 "$PLIST_PATH"

# Try to bootstrap the agent in the console user's GUI session. Best-effort —
# if no GUI session is active (running over SSH for example), this is a no-op
# and the agent will pick up at next login.
USER_UID=$(id -u "$CONSOLE_USER")
sudo -u "$CONSOLE_USER" launchctl bootout    "gui/$USER_UID/com.local.wacomd" 2>/dev/null || true
sudo -u "$CONSOLE_USER" launchctl bootstrap  "gui/$USER_UID" "$PLIST_PATH"   2>/dev/null || true
sudo -u "$CONSOLE_USER" launchctl enable     "gui/$USER_UID/com.local.wacomd" 2>/dev/null || true
sudo -u "$CONSOLE_USER" launchctl kickstart -k "gui/$USER_UID/com.local.wacomd" 2>/dev/null || true

exit 0
POST
chmod +x "$SCRIPTS/postinstall"

# ============================================================================
# 5. Build the component .pkg with productbuild
# ============================================================================
echo "==> pkgbuild → component"
COMPONENT="$OUT_DIR/_component.pkg"
pkgbuild \
    --root      "$STAGE" \
    --scripts   "$SCRIPTS" \
    --identifier "$PKG_ID" \
    --version    "$VERSION" \
    --install-location "/" \
    "$COMPONENT" >/dev/null

echo "==> productbuild → final .pkg"
DISTRIBUTION_XML="$OUT_DIR/_distribution.xml"
cat > "$DISTRIBUTION_XML" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>wacomd</title>
    <organization>com.local</organization>
    <domains enable_localSystem="true" enable_currentUserHome="true"/>
    <pkg-ref id="$PKG_ID"/>
    <choices-outline>
        <line choice="default">
            <line choice="$PKG_ID"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="$PKG_ID" visible="false">
        <pkg-ref id="$PKG_ID"/>
    </choice>
    <pkg-ref id="$PKG_ID" version="$VERSION" onConclusion="none">_component.pkg</pkg-ref>
</installer-gui-script>
EOF

PRODUCTBUILD_ARGS=(
    --distribution "$DISTRIBUTION_XML"
    --package-path "$OUT_DIR"
)
if [ -n "$SIGN_PKG" ]; then
    PRODUCTBUILD_ARGS+=( --sign "$SIGN_PKG" --timestamp )
    echo "==> Sign .pkg with Developer ID Installer"
fi
productbuild "${PRODUCTBUILD_ARGS[@]}" "$OUT_DIR/$PKG_NAME" >/dev/null

if [ -n "$SIGN_PKG" ]; then
    # Confirm the .pkg signature with the system tool used by macOS itself.
    pkgutil --check-signature "$OUT_DIR/$PKG_NAME" | sed -n '1,6p'
fi

# ============================================================================
# 6. Apply the ghost icon to the .pkg file itself (Finder thumbnail)
# ============================================================================
if [ -f "$ICON_SRC" ] && [ -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns" ]; then
    # Build a tiny helper that copies the .icns into the .pkg's resource fork.
    # `Rez` would be the proper tool but is unavailable on modern macOS — use
    # SetFile + sips via a sidecar instead. As a fallback we just leave the
    # default Installer icon ; the bundled .app still has the ghost.
    cp "$APP_BUNDLE/Contents/Resources/AppIcon.icns" "$OUT_DIR/${PKG_NAME%.pkg}.icns"
fi

# ============================================================================
# 7. Cleanup intermediate artefacts
# ============================================================================
rm -rf "$STAGE" "$SCRIPTS" "$COMPONENT" "$DISTRIBUTION_XML"

echo
echo "✓ Installer : $OUT_DIR/$PKG_NAME ($(stat -f '%z' "$OUT_DIR/$PKG_NAME") octets)"
[ -f "$APPSTORE_ICON" ] && echo "✓ App Store : $APPSTORE_ICON"
echo
echo "Distribuer :   open \"$OUT_DIR/$PKG_NAME\""
