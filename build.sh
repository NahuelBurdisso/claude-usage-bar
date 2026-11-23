#!/bin/bash
# Build ClaudeUsageBar.app from menubar.swift. Re-run after editing the Swift or
# the Python; usage.py and pricing.json are copied into the bundle's Resources.
set -euo pipefail

cd "$(dirname "$0")"
APP="ClaudeUsageBar.app"

# La app puede estar corriendo desde este mismo bundle: bajarla antes de borrarlo.
AGENT="ar.nb.claude-usage-bar"
WAS_RUNNING=0
if pgrep -x ClaudeUsageBar >/dev/null; then WAS_RUNNING=1; fi
launchctl bootout "gui/$(id -u)/$AGENT" 2>/dev/null || true
pkill -x ClaudeUsageBar 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library menubar.swift -o "$APP/Contents/MacOS/ClaudeUsageBar"
cp usage.py pricing.json "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ClaudeUsageBar</string>
  <key>CFBundleDisplayName</key><string>Claude Usage</string>
  <key>CFBundleIdentifier</key><string>ar.nb.claude-usage-bar</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>ClaudeUsageBar</string>
  <!-- Menu bar only: no Dock icon, no app switcher entry. -->
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST

# Ad-hoc signature. Built locally, so there is no quarantine attribute and no
# Gatekeeper prompt - the thing that stopped SwiftBar from ever starting.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

PLIST="$HOME/Library/LaunchAgents/$AGENT.plist"
if [ -f "$PLIST" ]; then
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null && echo "relanzada por launchd"
elif [ "$WAS_RUNNING" = 1 ]; then
  open "$APP"; echo "relanzada"
fi

echo "listo: $(pwd)/$APP"
