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
    <key>CFBundleShortVersionString</key>    <string>0.8.2</string>
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

# Ad-hoc sign so macOS Gatekeeper accepts the bundle locally.
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "✓ Built : $APP_DIR"
echo
echo "Launch :     open \"$APP_DIR\""
echo "Install :    cp -R \"$APP_DIR\" /Applications/"
