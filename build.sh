#!/bin/zsh
# Build Pendrix.app into ./dist.
#   ./build.sh            release build for this Mac
#   ./build.sh --install  …and copy to /Applications, relaunch
#   ./build.sh --dmg      universal (arm64 + x86_64) build → dist/Pendrix-<version>.dmg + .dmg.sha256
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
APP=dist/Pendrix.app

if [[ "$MODE" == "--dmg" ]]; then
  swift build -c release --arch arm64 --arch x86_64 2>&1 | tail -1
  BIN=.build/apple/Products/Release/Pendrix
else
  swift build -c release 2>&1 | tail -1
  BIN=.build/release/Pendrix
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
ICON_OUT=$(mktemp -d)
xcrun actool Assets/AppIcon.xcassets --compile "$ICON_OUT" --platform macosx \
  --minimum-deployment-target 15.0 --app-icon AppIcon \
  --output-partial-info-plist "$ICON_OUT/partial.plist" >/dev/null 2>&1
cp "$ICON_OUT/Assets.car" "$ICON_OUT/AppIcon.icns" "$APP/Contents/Resources/" 2>/dev/null || true
rm -rf "$ICON_OUT"
# Stable identity keeps Keychain ACLs valid across rebuilds and in-app updates; ad-hoc changes identity every build.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Pendrix Dev"; then
  codesign --force --deep --sign "Pendrix Dev" "$APP" && echo "signed: Pendrix Dev"
else
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
  echo "signed: ad-hoc (Keychain will prompt on each rebuild; see README)"
fi
echo "built $APP ($(lipo -archs "$APP/Contents/MacOS/Pendrix")) v$VERSION"

if [[ "$MODE" == "--install" ]]; then
  pkill -x Pendrix 2>/dev/null || true
  rm -rf /Applications/Pendrix.app
  cp -R "$APP" /Applications/
  sleep 1
  open /Applications/Pendrix.app
  echo "installed → /Applications/Pendrix.app"
fi

if [[ "$MODE" == "--dmg" ]]; then
  DMG="dist/Pendrix-${VERSION}.dmg"
  STAGE=$(mktemp -d)
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  cat > "$STAGE/README.txt" <<TXT
Pendrix ${VERSION}
Drag Pendrix.app to Applications.

This build is signed with a local certificate, not notarized. If macOS says the
app is from an unidentified developer: right-click → Open, or System Settings →
Privacy & Security → "Open Anyway". Updates install from inside the app afterwards.
TXT
  rm -f "$DMG" "$DMG.sha256"
  hdiutil create -volname "Pendrix" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
  shasum -a 256 "$DMG" | awk '{print $1}' > "$DMG.sha256"
  echo "dmg → $DMG ($(du -h "$DMG" | cut -f1))  sha256 → $DMG.sha256"
fi
