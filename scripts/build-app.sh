#!/usr/bin/env bash
# Builds "S2A Claude X-Ray.app" from the Swift package (release, ad-hoc signed).
# Usage: ./scripts/build-app.sh            -> build/S2A Claude X-Ray.app
#        VERSION=0.2.0 ./scripts/build-app.sh
set -euo pipefail

APP_NAME="S2A Claude X-Ray"
EXECUTABLE="S2AClaudeXRay"
BUNDLE_ID="${BUNDLE_ID:-com.s2a.claude-xray}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

cd "$(dirname "$0")/.."

swift build -c release --product "$EXECUTABLE"
BIN_DIR="$(swift build -c release --product "$EXECUTABLE" --show-bin-path)"

APP="build/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${EXECUTABLE}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>S2A Claude X-Ray</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so Gatekeeper accepts the local build (right-click > Open on first launch).
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "warning: codesign failed; the app is unsigned"

echo "Built: $APP"
