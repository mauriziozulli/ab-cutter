#!/usr/bin/env bash
#
# Builds "AB Cutter.app" (and a .dmg) from the SwiftPM package. Run this on a
# Mac with the Xcode command line tools installed:
#
#   packaging/build-app.sh
#   packaging/build-app.sh --no-dmg
#
# The build output lands in build/ and is git-ignored.

set -euo pipefail

APP_NAME="AB Cutter"
BUNDLE_ID="com.mauriziozulli.abcutter"
EXEC="ABCutter"
MAKE_DMG=1

while [ $# -gt 0 ]; do
  case "$1" in
    --name) APP_NAME="$2"; shift 2;;
    --id) BUNDLE_ID="$2"; shift 2;;
    --no-dmg) MAKE_DMG=0; shift;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(grep -Eo 'string = "[0-9]+\.[0-9]+\.[0-9]+"' Sources/ABCutter/App/AppVersion.swift | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[ -n "$VERSION" ] || { echo "✗ could not read the version from AppVersion.swift"; exit 1; }

echo "▸ AB Cutter v${VERSION}"

# Build — try universal, fall back to native.
ARCHFLAGS=(--arch arm64 --arch x86_64)
echo "▸ Building Release (universal)…"
if ! swift build -c release "${ARCHFLAGS[@]}" >/dev/null 2>&1; then
  echo "  universal build unavailable — building native"
  ARCHFLAGS=()
  swift build -c release
fi
BINPATH="$(swift build -c release "${ARCHFLAGS[@]}" --show-bin-path)"
[ -x "$BINPATH/$EXEC" ] || { echo "✗ built binary not found at $BINPATH/$EXEC"; exit 1; }

APP="build/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINPATH/$EXEC" "$APP/Contents/MacOS/$EXEC"

# SwiftPM resource bundles must sit next to the executable.
shopt -s nullglob
for bundle in "$BINPATH"/*.bundle; do cp -R "$bundle" "$APP/Contents/MacOS/"; done
shopt -u nullglob

# App icon: use a committed AppIcon.icns, otherwise build one from a PNG.
ICON_LINE=""
ICNS_SRC=""
if [ -f packaging/AppIcon.icns ]; then
  ICNS_SRC="packaging/AppIcon.icns"
elif [ -f packaging/AppIcon.png ] && command -v iconutil >/dev/null 2>&1 && command -v sips >/dev/null 2>&1; then
  echo "▸ Generating AppIcon.icns from AppIcon.png…"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" packaging/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" packaging/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  mkdir -p build
  ICNS_SRC="build/AppIcon.icns"
  iconutil -c icns "$ICONSET" -o "$ICNS_SRC"
fi
if [ -n "$ICNS_SRC" ] && [ -f "$ICNS_SRC" ]; then
  cp "$ICNS_SRC" "$APP/Contents/Resources/AppIcon.icns"
  ICON_LINE="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleExecutable</key><string>${EXEC}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  ${ICON_LINE}
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>${BUNDLE_ID}.project</string>
      <key>UTTypeDescription</key><string>AB Cutter Project</string>
      <key>UTTypeConformsTo</key>
      <array><string>public.json</string></array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array><string>abcut</string></array>
      </dict>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>AB Cutter Project</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key>
      <array><string>${BUNDLE_ID}.project</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

strip -rSTx "$APP/Contents/MacOS/$EXEC" 2>/dev/null || true
echo "▸ Ad-hoc code-signing…"
codesign --force --deep --sign - "$APP"

echo "✓ Built $APP"

if [ "$MAKE_DMG" = 1 ]; then
  DMG="build/${APP_NAME// /-}-v${VERSION}.dmg"
  STAGING="$(mktemp -d)"
  cp -R "$APP" "$STAGING/"
  ln -s /Applications "$STAGING/Applications"
  rm -f "$DMG"
  echo "▸ Building disk image…"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGING"
  echo "✓ Built $DMG"
fi

echo
echo "The app is unsigned, so open it the first time via right-click → Open."
