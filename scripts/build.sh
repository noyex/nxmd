#!/bin/zsh
# Builds build/nxmd.app (universal binary, ad-hoc signed).
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-1.0.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP=build/nxmd.app
TMP=build/tmp

rm -rf "$APP" "$TMP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$TMP"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 \
    -target "$arch-apple-macos13.0" \
    -module-name nxmd \
    -framework AppKit -framework WebKit -framework JavaScriptCore \
    Sources/*.swift -o "$TMP/nxmd-$arch"
done
lipo -create "$TMP"/nxmd-arm64 "$TMP"/nxmd-x86_64 -output "$APP/Contents/MacOS/nxmd"

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/*.js Resources/*.css "$APP/Contents/Resources/"

# Icon: asset catalog (so macOS masks it to the system shape) plus a legacy .icns
ICONSET="$TMP/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$TMP/icon.png"
cat > "$ICONSET/Contents.json" <<'JSON'
{ "images": [
  { "idiom": "mac", "size": "16x16", "scale": "1x", "filename": "16.png" },
  { "idiom": "mac", "size": "16x16", "scale": "2x", "filename": "32.png" },
  { "idiom": "mac", "size": "32x32", "scale": "1x", "filename": "32.png" },
  { "idiom": "mac", "size": "32x32", "scale": "2x", "filename": "64.png" },
  { "idiom": "mac", "size": "128x128", "scale": "1x", "filename": "128.png" },
  { "idiom": "mac", "size": "128x128", "scale": "2x", "filename": "256.png" },
  { "idiom": "mac", "size": "256x256", "scale": "1x", "filename": "256.png" },
  { "idiom": "mac", "size": "256x256", "scale": "2x", "filename": "512.png" },
  { "idiom": "mac", "size": "512x512", "scale": "1x", "filename": "512.png" },
  { "idiom": "mac", "size": "512x512", "scale": "2x", "filename": "1024.png" }
], "info": { "version": 1, "author": "xcode" } }
JSON
for px in 16 32 64 128 256 512 1024; do
  sips -z $px $px "$TMP/icon.png" --out "$ICONSET/$px.png" >/dev/null
done
xcrun actool "$TMP/Assets.xcassets" --compile "$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 13.0 \
  --app-icon AppIcon --output-partial-info-plist "$TMP/actool.plist" >/dev/null

codesign --force --sign - "$APP" >/dev/null
rm -rf "$TMP"
echo "Built $APP"
