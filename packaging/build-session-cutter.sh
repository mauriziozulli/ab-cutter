#!/usr/bin/env bash
#
# Builds "Session Cutter.app" (and a .dmg) from the SwiftPM package. Run this on a
# Mac with the Xcode command line tools installed:
#
#   packaging/build-app.sh
#   packaging/build-app.sh --no-dmg
#
# The build output lands in build/ and is git-ignored.

set -euo pipefail

APP_NAME="Session Cutter"
BUNDLE_ID="com.mauriziozulli.sessioncutter"
EXEC="SessionCutter"
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

VERSION="$(grep -Eo 'string = "[0-9]+\.[0-9]+\.[0-9]+"' Sources/SessionCutter/App/SessionCutterApp.swift | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[ -n "$VERSION" ] || { echo "✗ could not read the version from AppVersion.swift"; exit 1; }

echo "▸ Session Cutter v${VERSION}"

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

# SwiftPM resource bundles: a release build looks for them in
# Bundle.main.resourceURL, i.e. Contents/Resources — next to the executable
# it would crash at launch ("unable to find bundle named …").
shopt -s nullglob
for bundle in "$BINPATH"/*.bundle; do cp -R "$bundle" "$APP/Contents/Resources/"; done
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
  <key>NSMicrophoneUsageDescription</key><string>Session Cutter nimmt Original und Final Mix aus Pro Tools auf.</string>
</dict>
</plist>
PLIST

strip -rSTx "$APP/Contents/MacOS/$EXEC" 2>/dev/null || true
# macOS ties the screen-recording and microphone permissions to the app's
# signature. An ad-hoc signature changes with every build, so every build
# asks again — and sometimes ignores the answer. Sign with your own
# certificate (Xcode → Settings → Accounts gives you a free "Apple
# Development" one) and the permissions stick:
#
#   SIGN_ID="Apple Development: Your Name (TEAMID)" packaging/build-session-cutter.sh
#
# `security find-identity -v -p codesigning` lists the names.
SIGN_ID="${SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -Eo '"Apple Development: [^"]+"' | tr -d '"' || true)"
fi
if [ -n "$SIGN_ID" ]; then
  echo "▸ Signing as $SIGN_ID…"
  codesign --force --deep --sign "$SIGN_ID" "$APP"
else
  echo "▸ Ad-hoc code-signing (permissions will be asked again after each build)…"
  codesign --force --deep --sign - "$APP"
fi

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
