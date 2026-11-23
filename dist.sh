#!/bin/bash
# Package ClaudeUsageBar.app as a shareable zip: universal binary (arm64 + x86_64),
# ad-hoc signed, with install notes. Leaves the local build and running app alone.
set -euo pipefail

cd "$(dirname "$0")"
OUT="dist"
APP="$OUT/ClaudeUsageBar.app"

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library -target arm64-apple-macos13 menubar.swift -o "$OUT/bin-arm64"
swiftc -O -parse-as-library -target x86_64-apple-macos13 menubar.swift -o "$OUT/bin-x86_64"
lipo -create "$OUT/bin-arm64" "$OUT/bin-x86_64" -output "$APP/Contents/MacOS/ClaudeUsageBar"
rm "$OUT"/bin-*

cp usage.py pricing.json "$APP/Contents/Resources/"
# Same Info.plist as build.sh.
sed -n "/<<'PLIST'/,/^PLIST$/p" build.sh | sed '1d;$d' > "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

cat > "$OUT/LEEME.txt" <<'TXT'
Claude Usage — menu bar widget for Claude Code

Shows the rolling 5h block, the last 7 days and spend per skill, read locally
from ~/.claude/projects. Nothing leaves your machine. Dollars are API list-price
EQUIVALENT, not a charge.

Install
  1. Move ClaudeUsageBar.app to /Applications.
  2. The app isn't notarized, so clear the download quarantine once:
       xattr -dr com.apple.quarantine /Applications/ClaudeUsageBar.app
  3. Open it. It lives in the menu bar only (no Dock icon).

Needs python3 at /usr/bin/python3 (macOS Command Line Tools:
xcode-select --install).

Icon not showing? macOS 26 hides new menu bar items when the bar is full:
System Settings → Control Center → enable "ClaudeUsageBar" (app running).

Start at login: System Settings → General → Login Items → add the app.

Your plan: the week is compared against a $100/month plan. Edit
"plan.usd_per_month" in ClaudeUsageBar.app/Contents/Resources/pricing.json
(e.g. 200 for Max 20x), re-sign and restart the app:
  codesign --force --sign - /Applications/ClaudeUsageBar.app
TXT

(cd "$OUT" && zip -qry ClaudeUsageBar.zip ClaudeUsageBar.app LEEME.txt)
echo "listo: $(pwd)/$OUT/ClaudeUsageBar.zip"
