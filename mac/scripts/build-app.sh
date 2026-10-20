#!/bin/bash
# Builds build/MacSecondMonitor.app (and optionally a DMG).
#
#   scripts/build-app.sh            release build, signed with the first "Apple Development"
#                                   or "Developer ID Application" identity (ad-hoc otherwise)
#   SIGN_IDENTITY="-" scripts/build-app.sh      force ad-hoc signing
#   DMG=1 scripts/build-app.sh                   also create build/MacSecondMonitor.dmg
#   VERSION=0.2.0 BUILD=5 scripts/build-app.sh   set the version
#
# The web client (web/dist) and the Android APK (android/app/build/outputs/apk) are bundled
# when they have been built.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(cd .. && pwd)"
CONFIG="${CONFIG:-release}"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"
APP="build/MacSecondMonitor.app"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --product MacSecondMonitor
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MacSecondMonitor" "$APP/Contents/MacOS/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# SwiftPM copies the String Catalog verbatim; compile it into .lproj tables.
BUNDLE="$APP/Contents/Resources/MacSecondMonitor_MSMHost.bundle"
cp -R "$BIN/MacSecondMonitor_MSMHost.bundle" "$BUNDLE"
xcrun xcstringstool compile "$BUNDLE/Localizable.xcstrings" --output-directory "$BUNDLE"
rm "$BUNDLE/Localizable.xcstrings"
# Main-bundle localizations tell macOS which languages the app supports.
for language in en tr de es fr it pt-BR ru zh-Hans ja ko ar; do
    mkdir -p "$APP/Contents/Resources/$language.lproj"
done

if [ -f "$ROOT/web/dist/index.html" ]; then
    echo "==> Bundling web client"
    cp -R "$ROOT/web/dist" "$APP/Contents/Resources/web"
else
    echo "    (web client not built; run 'npm run build' in web/ to bundle it)"
fi

# Prefer a release APK; fall back to the newest debug build.
APK="$(ls -t "$ROOT"/android/app/build/outputs/apk/release/*.apk 2>/dev/null | head -1 || true)"
if [ -z "$APK" ]; then
    APK="$(ls -t "$ROOT"/android/app/build/outputs/apk/debug/*.apk 2>/dev/null | head -1 || true)"
fi
if [ -n "$APK" ]; then
    echo "==> Bundling Android client ($(basename "$APK"))"
    mkdir -p "$APP/Contents/Resources/android"
    cp "$APK" "$APP/Contents/Resources/android/MacSecondMonitor.apk"
else
    echo "    (Android client not built; run './gradlew assembleRelease' in android/ to bundle it)"
fi

if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -E '"(Developer ID Application|Apple Development):' | grep -v REVOKED | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
    SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
echo "==> Signing with: $SIGN_IDENTITY"
# A stable identity keeps Screen Recording / Accessibility grants across rebuilds.
codesign --force --deep --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"

if [ "${DMG:-0}" = "1" ]; then
    echo "==> Creating DMG"
    STAGING="$(mktemp -d)"
    cp -R "$APP" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    hdiutil create -volname "Mac Second Monitor" -srcfolder "$STAGING" -ov -format UDZO "build/MacSecondMonitor-$VERSION.dmg" >/dev/null
    rm -rf "$STAGING"
    echo "    build/MacSecondMonitor-$VERSION.dmg"
fi

echo "==> Done: $APP"
