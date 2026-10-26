#!/usr/bin/env bash
# CatCursorLock: build local .app, ad-hoc codesign, create release zip.
#
# Usage: bash build.sh [VERSION]
# SIGN_IDENTITY: optional signing identity. Defaults to local ad-hoc (-).
# Build is offline; it neither downloads software nor registers a LaunchAgent.
set -euo pipefail

VERSION="${1:-dev}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# Avoid path traversal and Info.plist XML injection through the version argument.
if [[ ! "$VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "Invalid version: use only letters, digits, dots, underscores or dashes" >&2
    exit 2
fi

APP="CatCursorLock.app"
BIN_DIR="$APP/Contents/MacOS"
BIN="$BIN_DIR/catcursorlock"

echo "==> Build (version=$VERSION)"
rm -rf "$APP"
mkdir -p "$BIN_DIR"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>catcursorlock</string>
    <key>CFBundleIdentifier</key>
    <string>local.catcursorlock</string>
    <key>CFBundleName</key>
    <string>CatCursorLock</string>
    <key>CFBundleDisplayName</key>
    <string>CatCursorLock</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Compile with swiftc"
swiftc main.swift -O -o "$BIN" \
    -framework CoreGraphics -framework Foundation -framework ApplicationServices

echo "==> Codesign (${SIGN_IDENTITY:-ad-hoc})"
codesign -s "${SIGN_IDENTITY:--}" -f --deep "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Authority|Signature" || true

ZIP="CatCursorLock-${VERSION}.zip"
echo "==> Package $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Finished"
shasum -a 256 "$ZIP"
