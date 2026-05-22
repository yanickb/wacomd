#!/usr/bin/env bash
#
# Build "Wacomd Config.app" — a proper macOS .app bundle wrapping the
# SwiftPM wacomd-config binary. The bundle is:
#   - LSUIElement (no Dock icon, menu-bar only)
#   - ad-hoc signed (works for personal use ; for distribution sign with
#     a Developer ID and notarise)
#   - placed at build/Wacomd Config.app
#
# Usage:
#   ./packaging/build-app.sh
#   open "build/Wacomd Config.app"      # to launch
#   cp -R "build/Wacomd Config.app" /Applications/   # to install

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Wacomd Config"
BUNDLE_ID="com.local.wacomd-config"
OUT_DIR="$REPO_DIR/build"
APP_DIR="$OUT_DIR/${APP_NAME}.app"

echo "==> Build release"
swift build -c release --package-path "$REPO_DIR"

BIN="$REPO_DIR/.build/release/wacomd-config"
if [ ! -x "$BIN" ]; then
    echo "✗ Binary not found at $BIN"
    exit 1
fi

echo "==> Assemble bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN" "$APP_DIR/Contents/MacOS/wacomd-config"
chmod +x "$APP_DIR/Contents/MacOS/wacomd-config"

# ---- Icon (.icns) ----------------------------------------------------------
ICON_SRC="$REPO_DIR/assets/icon.png"
if [ -f "$ICON_SRC" ]; then
    echo "==> Bake .icns from assets/icon.png"
    ICONSET="$OUT_DIR/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    # Standard macOS app icon sizes (Apple wants every variant).
    for spec in \
        "16:icon_16x16.png" \
        "32:icon_16x16@2x.png" \
        "32:icon_32x32.png" \
        "64:icon_32x32@2x.png" \
        "128:icon_128x128.png" \
        "256:icon_128x128@2x.png" \
        "256:icon_256x256.png" \
        "512:icon_256x256@2x.png" \
        "512:icon_512x512.png" \
        "1024:icon_512x512@2x.png"
    do
        size="${spec%%:*}"
        name="${spec##*:}"
        sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET/$name" >/dev/null 2>&1
    done
    iconutil --convert icns "$ICONSET" --output "$APP_DIR/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
    ICON_KEY="    <key>CFBundleIconFile</key>            <string>AppIcon</string>"
else
    echo "(no assets/icon.png — bundle will use the generic icon)"
    ICON_KEY=""
fi

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>     <string>fr</string>
    <key>CFBundleExecutable</key>            <string>wacomd-config</string>
    <key>CFBundleIdentifier</key>            <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>CFBundleName</key>                  <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>           <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
${ICON_KEY}
    <key>CFBundleShortVersionString</key>    <string>0.8.4</string>
    <key>CFBundleVersion</key>               <string>1</string>
    <key>LSMinimumSystemVersion</key>        <string>13.0</string>
    <!-- Menu-bar agent : no Dock icon, no main window. -->
    <key>LSUIElement</key>                   <true/>
    <key>NSHumanReadableCopyright</key>      <string>MIT licence</string>
    <key>NSPrincipalClass</key>              <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>       <true/>
</dict>
</plist>
EOF

# ---- Sign with Developer ID Application -----------------------------------
# When packaging/signing.env is present, use the real Developer ID identity
# + hardened runtime so the result is notarisable. Otherwise fall back to
# ad-hoc signing for purely local development.
SIGNING_ENV="$REPO_DIR/packaging/signing.env"
ENTITLEMENTS="$REPO_DIR/packaging/wacomd.entitlements"
if [ -f "$SIGNING_ENV" ]; then
    # shellcheck disable=SC1090
    source "$SIGNING_ENV"
    echo "==> Sign with Developer ID Application (hardened runtime)"
    # The daemon binary inside the bundle (if any) must be signed before the
    # outer bundle. Sign every Mach-O found in the bundle.
    find "$APP_DIR/Contents" -type f -perm -u+x | while read -r exe; do
        codesign --force --options=runtime --timestamp \
                 --entitlements "$ENTITLEMENTS" \
                 --sign "$SIGN_APP" "$exe" 2>/dev/null || true
    done
    # Finally sign the bundle itself (--deep wraps any remaining unsigned
    # nested code).
    codesign --force --deep --options=runtime --timestamp \
             --entitlements "$ENTITLEMENTS" \
             --sign "$SIGN_APP" "$APP_DIR"
    # Verify
    codesign --verify --deep --strict --verbose=2 "$APP_DIR" 2>&1 | tail -3
else
    echo "==> Ad-hoc sign (no signing.env — local build only, not notarisable)"
    codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "✓ Built : $APP_DIR"
echo
echo "Launch :     open \"$APP_DIR\""
echo "Install :    cp -R \"$APP_DIR\" /Applications/"
