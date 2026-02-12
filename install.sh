#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CodexRunlight"
LABEL="io.github.codex-runlight.agent"

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="$HOME/Library/Application Support/$APP_NAME"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$DEST_DIR"
mkdir -p "$(dirname "$PLIST_PATH")"

echo "Building $APP_NAME..."
/usr/bin/swiftc -O -framework AppKit -framework Foundation \
  -o "$DEST_DIR/$APP_NAME" \
  "$SRC_DIR/$APP_NAME.swift"

chmod +x "$DEST_DIR/$APP_NAME"

cat >"$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$DEST_DIR/$APP_NAME</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/codex-runlight.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/codex-runlight.err.log</string>
</dict>
</plist>
PLIST

echo "Installing LaunchAgent..."
# Use the plist path form for bootout; it's more reliable than the service-target form.
launchctl bootout "gui/$UID" "$PLIST_PATH" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST_PATH"
launchctl enable "gui/$UID/$LABEL" 2>/dev/null || true
launchctl kickstart -k "gui/$UID/$LABEL" 2>/dev/null || true

echo "Installed:"
echo "  Binary: $DEST_DIR/$APP_NAME"
echo "  Plist:  $PLIST_PATH"
