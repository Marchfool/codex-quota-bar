#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP_SRC="$ROOT/.build/CodexQuotaBar.app"
APP_DST="/Applications/CodexQuotaBar.app"
APP_BIN_DST="$APP_DST/Contents/MacOS/CodexQuotaBar"
RESOLVED_CODESIGN_IDENTITY="$("$ROOT/scripts/resolve-codesign-identity.sh")"

echo "[1/5] Bundle app ($CONFIG)"
echo "  using fixed install path: $APP_DST"
echo "  using signing identity: $RESOLVED_CODESIGN_IDENTITY"
"$ROOT/scripts/bundle-app.sh" "$CONFIG"

echo "[2/5] Verify bundled app timestamp"
SRC_TS="$(stat -f '%m' "$APP_SRC")"
echo "  bundled app: $(stat -f '%Sm %N' -t '%Y-%m-%d %H:%M:%S' "$APP_SRC")"

echo "[3/5] Replace installed app"
pkill -9 -f "$APP_BIN_DST" 2>/dev/null || true
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"
xattr -cr "$APP_DST" 2>/dev/null || true

echo "[4/5] Verify installed app timestamp"
DST_TS="$(stat -f '%m' "$APP_DST")"
echo "  installed app: $(stat -f '%Sm %N' -t '%Y-%m-%d %H:%M:%S' "$APP_DST")"
if (( DST_TS < SRC_TS )); then
  echo "ERROR: installed app is older than bundled app" >&2
  exit 1
fi

echo "  installed app identity:"
codesign -dv --verbose=2 "$APP_DST" 2>&1 | rg "Identifier=|Authority=|Signature=" || true

echo "[5/5] Launch installed app"
open "$APP_DST"
sleep 2
ps aux | rg "$APP_BIN_DST" || {
  echo "ERROR: installed app did not launch" >&2
  exit 1
}

echo "Installed and launched: $APP_DST"
