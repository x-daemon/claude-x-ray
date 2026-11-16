#!/usr/bin/env bash
# Builds "S2A Claude X-Ray.app" from the Swift package (release, ad-hoc signed).
# Usage: ./scripts/build-app.sh                       -> build/S2A Claude X-Ray.app
#        VERSION=0.6.0 UNIVERSAL=1 ./scripts/build-app.sh   (Apple Silicon + Intel)
set -euo pipefail

APP_NAME="S2A Claude X-Ray"
EXECUTABLE="S2AClaudeXRay"
BUNDLE_ID="${BUNDLE_ID:-com.s2a.claude-xray}"
VERSION="${VERSION:-0.6.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

cd "$(dirname "$0")/.."

# Universal binary when asked; falls back to this Mac's architecture if that build fails.
ARCH_FLAGS=""
if [ "${UNIVERSAL:-0}" = "1" ]; then
    ARCH_FLAGS="--arch arm64 --arch x86_64"
fi
# shellcheck disable=SC2086
if ! swift build -c release --product "$EXECUTABLE" $ARCH_FLAGS; then
    if [ -n "$ARCH_FLAGS" ]; then
        echo "warning: universal build failed, building for this Mac only"
        ARCH_FLAGS=""
        swift build -c release --product "$EXECUTABLE"
    else
        exit 1
    fi
fi
# shellcheck disable=SC2086
BIN_DIR="$(swift build -c release --product "$EXECUTABLE" $ARCH_FLAGS --show-bin-path)"

APP="build/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
lipo -info "$APP/Contents/MacOS/$EXECUTABLE" || true

# App icon from Resources/AppIcon.png (1024x1024), see scripts/make-icon.py.
ICON_ENTRY=""
if [ -f Resources/AppIcon.png ] && command -v iconutil >/dev/null; then
    ICONSET="build/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z "$double" "$double" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    ICON_ENTRY="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

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
    ${ICON_ENTRY}
</dict>
</plist>
PLIST

# Ad-hoc signature (no Apple Developer ID): macOS asks to confirm the first launch.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "warning: codesign failed; the app is unsigned"

echo "Built: $APP (version $VERSION, build $BUILD_NUMBER)"
