#!/usr/bin/env bash
# Builds the release app without a certificate (ad-hoc signature) and packages it:
#   dist/S-Display-<version>.dmg     (app + Applications shortcut + install notes)
#   dist/S-Display-<version>.zip
#   dist/S-Display-<version>.sha256  (checksums of both)
#
# The version is VERSION=1.2.3 when set (the release workflow sets it from the tag it is
# about to create); otherwise the latest v* tag plus "-dev", for local test builds. The
# build number is the commit count, so it always grows.
set -euo pipefail
cd "$(dirname "$0")/.."

LATEST_TAG=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo v0.0.0)
VERSION="${VERSION:-${LATEST_TAG#v}-dev}"
BUILD=$(git rev-list --count HEAD)
NAME="S-Display"

command -v xcodegen >/dev/null || { echo "XcodeGen is required: brew install xcodegen" >&2; exit 1; }

echo "==> Tests"
xcodegen generate --quiet
xcodebuild -project "$NAME.xcodeproj" -scheme "$NAME" -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData test -quiet

echo "==> Release build $VERSION (build $BUILD, Apple Silicon, ad-hoc signed)"
rm -rf build/DerivedData/Build/Products/Release dist
xcodebuild -project "$NAME.xcodeproj" -scheme "$NAME" -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" build -quiet

APP="build/DerivedData/Build/Products/Release/$NAME.app"
codesign --verify --strict "$APP"
BUILT=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
[ "$BUILT" = "$VERSION" ] || { echo "App reports version $BUILT, expected $VERSION" >&2; exit 1; }
BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")
[ "$BUNDLE_ID" = "com.huyly.sdisplay" ] || { echo "Unexpected bundle id $BUNDLE_ID" >&2; exit 1; }
# Debug-only automation must never ship.
if strings "$APP/Contents/MacOS/$NAME" | grep -q "debug-command"; then
  echo "Release binary contains the debug command hook" >&2; exit 1
fi

mkdir -p dist
ditto -c -k --keepParent "$APP" "dist/$NAME-$VERSION.zip"

echo "==> DMG"
STAGE="build/dmg"
rm -rf "$STAGE" && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me First.txt" <<'NOTES'
INSTALLING S-DISPLAY

1. Drag S-Display.app into the Applications folder (the shortcut next to it).
2. Open S-Display from Applications. macOS will say "S-Display" Not Opened:
   Apple could not verify "S-Display" is free of malware... This is normal for
   every app that is not notarized by Apple; it does not mean malware was found.
   - Click "Done" (not "Move to Trash").
   - Open System Settings → Privacy & Security, scroll to Security and click
     "Open Anyway", then confirm with your password or Touch ID.
   - Or run in Terminal:
       xattr -dr com.apple.quarantine /Applications/S-Display.app
   To check the download really comes from the source repository:
       gh attestation verify S-Display-x.y.z.dmg -R SLyHuy/S-Display
3. S-Display lives in the menu bar (the display icon). Requires an Apple
   Silicon Mac and macOS 14 or later.

If a display stays dark: press Control-Option-Command-0, or open S-Display and
click Turn On, or unplug and replug that display's cable.

Source code and the latest version: https://github.com/SLyHuy/S-Display
MIT License © 2026 Huy Ly
NOTES

# Volume icon: build read-write, give the mounted volume the app's icon, then compress.
RW="build/$NAME-rw.dmg"
rm -f "$RW" "dist/$NAME-$VERSION.dmg"
hdiutil create -quiet -volname "$NAME $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
MOUNT=$(hdiutil attach -nobrowse -noautoopen -readwrite "$RW" 2>/dev/null | awk -F'\t' '/\/Volumes\// {print $NF}')
if [ -n "$MOUNT" ]; then
  if SETFILE=$(xcrun -f SetFile 2>/dev/null); then
    cp "$APP/Contents/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
    "$SETFILE" -a C "$MOUNT"
  fi
  hdiutil detach -quiet "$MOUNT"
fi
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "dist/$NAME-$VERSION.dmg"
rm -f "$RW"

(cd dist && shasum -a 256 "$NAME-$VERSION.dmg" "$NAME-$VERSION.zip" > "$NAME-$VERSION.sha256")

echo "==> Done"
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/$NAME")"
codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|Signature)='
cat "dist/$NAME-$VERSION.sha256"
