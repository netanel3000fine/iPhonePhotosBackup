#!/usr/bin/env bash
set -euo pipefail

APP_NAME="iPhonePhotosBackup"
APP_BUNDLE="${APP_NAME}.app"
LAUNCH="${1:-}"

cd "$(dirname "$0")"

echo "=== Stopping previous instance (if any) ==="
pkill -x "$APP_NAME" || true

echo "=== Recreating App Bundle structure ==="
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

echo "=== Compiling Swift files with swiftc ==="
swiftc -parse-as-library \
    -target arm64-apple-macosx15.0 \
    -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
    Sources/iPhonePhotosBackup/*.swift \
    -framework Cocoa \
    -framework SwiftUI \
    -framework ImageCaptureCore \
    -framework QuickLook \
    -framework QuickLookUI \
    -o "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

echo "=== Copying resources & plist ==="
[ -f "Info.plist" ] && cp "Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
[ -f "AppIcon.icns" ] && cp "AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
[ -f "AppIcon-Dark.icns" ] && cp "AppIcon-Dark.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon-Dark.icns"

if which actool >/dev/null 2>&1 && actool --version >/dev/null 2>&1; then
    echo "=== Compiling Asset Catalog with actool ==="
    actool --compile "${APP_BUNDLE}/Contents/Resources" \
           --platform macosx \
           --minimum-deployment-target 15.0 \
           --app-icon AppIcon \
           Assets.xcassets 2>/dev/null || echo "Note: actool compilation skipped"
fi

for lproj in Sources/iPhonePhotosBackup/Resources/*.lproj; do
    [ -d "$lproj" ] && cp -r "$lproj" "${APP_BUNDLE}/Contents/Resources/"
done

echo "=== Codesigning with USB entitlements ==="
codesign --force --options runtime --entitlements app.entitlements -s - "$APP_BUNDLE"

echo "=== Verification ==="
codesign -vv --deep --strict "$APP_BUNDLE"

echo "=========================================="
echo "SUCCESS! $APP_BUNDLE has been built."
echo "=========================================="

if [ "$LAUNCH" != "--no-launch" ]; then
    echo "=== Launching $APP_BUNDLE ==="
    open "$APP_BUNDLE"
    echo "Done."
fi
