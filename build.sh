#!/bin/bash
# Builds Whittle.app (no Xcode required — uses swiftc directly).
set -euo pipefail
cd "$(dirname "$0")"
source ./clt-workaround.sh

APP=".build/Whittle.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo "Compiling…"
swiftc "${SWIFT_EXTRA_FLAGS[@]}" \
    -O -parse-as-library \
    -target arm64-apple-macosx14.0 \
    -o "$APP/Contents/MacOS/Whittle" \
    Sources/WhittleCore/*.swift Sources/Whittle/*.swift

mkdir -p "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "Signing (ad-hoc)…"
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Run with: open $APP"
