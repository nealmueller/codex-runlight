#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"

APP_NAME="Codex Runlight"
BIN_NAME="CodexRunlight"
BUNDLE_ID="io.github.codex-runlight"
VERSION="${VERSION:-0.1.0}"

APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
DMG_STAGING="$DIST_DIR/dmg"
DMG_PATH="$DIST_DIR/CodexRunlight-macos.dmg"
ZIP_PATH="$DIST_DIR/CodexRunlight-macos.zip"

rm -rf "$DIST_DIR"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$DMG_STAGING"

echo "Building binary..."
/usr/bin/swiftc -O \
  -framework AppKit \
  -framework Foundation \
  -framework ApplicationServices \
  -o "$APP_MACOS/$BIN_NAME" \
  "$ROOT_DIR/$BIN_NAME.swift"

chmod +x "$APP_MACOS/$BIN_NAME"

if [[ -f "$ROOT_DIR/assets/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/assets/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
fi

cat >"$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$BIN_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Needed to open the Codex app from the menu bar.</string>
</dict>
</plist>
PLIST

echo -n "APPL????" >"$APP_CONTENTS/PkgInfo"

# Optional local signing: export CODESIGN_IDENTITY to use.
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  echo "Signing app bundle..."
  /usr/bin/codesign --force --deep --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"
fi

echo "Packaging ZIP..."
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "Packaging DMG..."
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
/usr/bin/hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null

# Optional notarization flow if credentials are provided.
if [[ -n "${NOTARY_PROFILE:-}" && -n "${CODESIGN_IDENTITY:-}" ]]; then
  if /usr/bin/xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "Submitting DMG for notarization..."
    /usr/bin/xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    /usr/bin/xcrun stapler staple "$DMG_PATH"
  else
    echo "Skipping notarization: notary profile '$NOTARY_PROFILE' not configured on this runner."
  fi
fi

echo "Artifacts created:"
echo "  $APP_BUNDLE"
echo "  $ZIP_PATH"
echo "  $DMG_PATH"
