#!/usr/bin/env bash
# Builds the universal app and packages it for download:
#   dist/S2A-Claude-X-Ray-<version>.dmg   (drag to Applications)
#   dist/S2A-Claude-X-Ray-<version>.zip
#   dist/SHA256SUMS.txt
# Usage: VERSION=0.2.0 ./scripts/package.sh
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.2.0}"
NAME="S2A-Claude-X-Ray-${VERSION}"
APP="build/S2A Claude X-Ray.app"

UNIVERSAL="${UNIVERSAL:-1}" VERSION="$VERSION" ./scripts/build-app.sh

rm -rf dist
mkdir -p dist
ditto -c -k --keepParent "$APP" "dist/${NAME}.zip"

STAGE="build/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "S2A Claude X-Ray" -srcfolder "$STAGE" -ov -format UDZO "dist/${NAME}.dmg" >/dev/null

(cd dist && shasum -a 256 ./*.dmg ./*.zip > SHA256SUMS.txt)
ls -la dist
cat dist/SHA256SUMS.txt
