#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
PRODUCT="$ROOT/.build/$CONFIG/CodexQuotaBar"
APP="$ROOT/.build/CodexQuotaBar.app"
WIDGET_PRODUCT="$ROOT/.build/$CONFIG/CodexQuotaWidget"
WIDGET="$APP/Contents/PlugIns/CodexQuotaWidget.appex"
RESOLVED_CODESIGN_IDENTITY="$("$ROOT/scripts/resolve-codesign-identity.sh")"
BUILD_INFO_ENV="$("$ROOT/scripts/generate-build-info.sh")"

# shellcheck source=/dev/null
source "$BUILD_INFO_ENV"
swift build -c "$CONFIG"
"$ROOT/scripts/generate-icons.swift"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$WIDGET/Contents/MacOS" "$WIDGET/Contents/Resources"
cp "$PRODUCT" "$APP/Contents/MacOS/CodexQuotaBar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
APP_INFO="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CodexQuotaBuildID $BUILD_ID" "$APP_INFO" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CodexQuotaBuildID string $BUILD_ID" "$APP_INFO"
/usr/libexec/PlistBuddy -c "Set :CodexQuotaBuildTimestamp $BUILD_TIMESTAMP" "$APP_INFO" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CodexQuotaBuildTimestamp string $BUILD_TIMESTAMP" "$APP_INFO"
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
  -application-extension \
  -Xlinker -e \
  -Xlinker _NSExtensionMain \
  -module-name CodexQuotaWidget \
  -framework Foundation \
  -framework AppKit \
  -framework SwiftUI \
  -framework WidgetKit \
  "$ROOT/Sources/CodexQuotaBarSupport/WidgetQuotaSnapshotLoader.swift" \
  "$ROOT/Sources/CodexQuotaWidget/CodexQuotaWidget.swift" \
  -o "$WIDGET_PRODUCT"
cp "$WIDGET_PRODUCT" "$WIDGET/Contents/MacOS/CodexQuotaWidget"
cp "$ROOT/Resources/WidgetInfo.plist" "$WIDGET/Contents/Info.plist"
cp "$ROOT/Resources/CodexAppIcon.png" "$WIDGET/Contents/Resources/CodexAppIcon.png"
chmod +x "$WIDGET/Contents/MacOS/CodexQuotaWidget"

xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign "$RESOLVED_CODESIGN_IDENTITY" --entitlements "$ROOT/Resources/Widget.entitlements" "$WIDGET" >/dev/null
codesign --force --sign "$RESOLVED_CODESIGN_IDENTITY" --entitlements "$ROOT/Resources/App.entitlements" "$APP" >/dev/null
codesign --verify --deep --strict "$APP" >/dev/null
echo "Signed $APP with identity: $RESOLVED_CODESIGN_IDENTITY" >&2
echo "$APP"
