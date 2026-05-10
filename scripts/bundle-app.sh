#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
PRODUCT="$ROOT/.build/$CONFIG/CodexQuotaBar"
APP="$ROOT/.build/CodexQuotaBar.app"
WIDGET_PRODUCT="$ROOT/.build/$CONFIG/CodexQuotaWidget"
WIDGET="$APP/Contents/PlugIns/CodexQuotaWidget.appex"

swift build -c "$CONFIG"
"$ROOT/scripts/generate-icons.swift"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$WIDGET/Contents/MacOS"
cp "$PRODUCT" "$APP/Contents/MacOS/CodexQuotaBar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/StatusIcon.png" "$APP/Contents/Resources/StatusIcon.png"
printf "APPL????" > "$APP/Contents/PkgInfo"
chmod +x "$APP/Contents/MacOS/CodexQuotaBar"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc \
  -target arm64-apple-macos14.0 \
  -sdk "$SDK" \
  -O \
  -parse-as-library \
  -module-name CodexQuotaWidget \
  -framework Foundation \
  -framework SwiftUI \
  -framework WidgetKit \
  "$ROOT/Sources/CodexQuotaWidget/CodexQuotaWidget.swift" \
  -o "$WIDGET_PRODUCT"
cp "$WIDGET_PRODUCT" "$WIDGET/Contents/MacOS/CodexQuotaWidget"
cp "$ROOT/Resources/WidgetInfo.plist" "$WIDGET/Contents/Info.plist"
chmod +x "$WIDGET/Contents/MacOS/CodexQuotaWidget"

xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP" >/dev/null
echo "$APP"
