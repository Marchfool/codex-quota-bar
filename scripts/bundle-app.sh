#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
PRODUCT="$ROOT/.build/$CONFIG/CodexQuotaBar"
APP="$ROOT/.build/CodexQuotaBar.app"

swift build -c "$CONFIG"
"$ROOT/scripts/generate-icons.swift"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCT" "$APP/Contents/MacOS/CodexQuotaBar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/StatusIcon.png" "$APP/Contents/Resources/StatusIcon.png"
printf "APPL????" > "$APP/Contents/PkgInfo"
chmod +x "$APP/Contents/MacOS/CodexQuotaBar"
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP" >/dev/null
echo "$APP"
