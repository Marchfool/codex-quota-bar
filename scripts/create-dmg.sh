#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/.build/CodexQuotaBar.app"
DMG_DIR="$ROOT/.build/dmg"
DMG="$ROOT/.build/CodexQuotaBar.dmg"

"$ROOT/scripts/bundle-app.sh" "$CONFIG" >/dev/null

rm -rf "$DMG_DIR" "$DMG"
mkdir -p "$DMG_DIR"
cp -R "$APP" "$DMG_DIR/CodexQuotaBar.app"
ln -s /Applications "$DMG_DIR/Applications"

hdiutil create \
  -volname "CodexQuotaBar" \
  -srcfolder "$DMG_DIR" \
  -ov \
  -format UDZO \
  "$DMG"

echo "$DMG"
