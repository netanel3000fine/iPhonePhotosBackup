#!/bin/bash
# create_dmg.sh — Build iPhonePhotosBackup and package it as a distributable DMG
cd /Applications/iPhonePhotosBackup
set -e

APP_NAME="iPhonePhotosBackup"
APP_BUNDLE="${APP_NAME}.app"
VERSION=$(date +"%Y.%m.%d")
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
VOL_NAME="iPhone Photos Backup"
STAGING_DIR=".dmg_staging"

# ── 1. Build (no auto-launch) ─────────────────────────────────────────────────
echo "=== Step 1/5: Building app ==="
bash Build-iPhonePhotosBackup.sh --no-launch

# ── 2. Stage the app ──────────────────────────────────────────────────────────
echo "=== Step 2/5: Staging ==="
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/"

# Create a symlink to /Applications so users can drag-and-drop
ln -s /Applications "$STAGING_DIR/Applications"

# ── 3. Create the DMG ────────────────────────────────────────────────────────
echo "=== Step 3/5: Creating DMG ==="
rm -f "$DMG_NAME"

hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_NAME"

# ── 4. Verify ─────────────────────────────────────────────────────────────────
echo "=== Step 4/5: Verifying DMG ==="
hdiutil verify "$DMG_NAME"

# ── 5. Clean up staging ───────────────────────────────────────────────────────
echo "=== Step 5/5: Cleaning up ==="
rm -rf "$STAGING_DIR"

echo ""
echo "=========================================="
echo "  DMG READY: $DMG_NAME"
echo "  Size: $(du -sh "$DMG_NAME" | cut -f1)"
echo "  Distribute this file to your users."
echo "  They drag $APP_BUNDLE to /Applications."
echo "=========================================="
