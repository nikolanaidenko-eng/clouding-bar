#!/bin/bash
# A release of Clouding Bar: built for Apple silicon and Intel (most Touch
# Bar Macs are Intel), signed with your Developer ID under the hardened
# runtime, notarized by Apple and stapled — the app, then the .dmg it
# comes in. Out: build/release/Clouding-Bar-<version>.dmg
#
# Once, beforehand:
#   - a "Developer ID Application" certificate in your keychain
#     (Xcode → Settings → Accounts → Manage Certificates → + )
#   - the notary's credentials, kept in your keychain as "clouding-bar":
#     xcrun notarytool store-credentials clouding-bar --apple-id <you> --team-id <team>
#
# DRY=1 skips Apple's notary (checks everything else); DEVELOPER_ID and
# NOTARY_PROFILE pick another certificate or credentials.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" packaging/Info.plist)
OUT=build/release
APP="$OUT/Clouding Bar.app"
DMG="$OUT/Clouding-Bar-$VERSION.dmg"
PROFILE=${NOTARY_PROFILE:-clouding-bar}
IDENTITY=${DEVELOPER_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}
if [ -z "$IDENTITY" ]; then
  echo "No Developer ID Application certificate in the keychain." >&2
  echo "Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application." >&2
  exit 1
fi
echo "Clouding Bar $VERSION, signed by: $IDENTITY"

rm -rf "$OUT"
mkdir -p "$OUT"

# One universal binary from both architectures.
universal() {
  local name=$1; shift
  for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macosx12.0" "$@" -o "$OUT/$name-$arch"
  done
  lipo -create "$OUT/$name-arm64" "$OUT/$name-x86_64" -output "$OUT/$name"
  rm "$OUT/$name-arm64" "$OUT/$name-x86_64"
}
echo "Building (arm64 + x86_64)…"
universal CloudingBar Sources/CloudingBar/*.swift Sources/CloudingBar/*/*.swift
universal cloudingbar-hook Sources/CloudingBarHook/*.swift
universal cloudingbar-tap Sources/CloudingBarTap/*.swift
universal cloudingbar-key Sources/CloudingBarKey/*.swift

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/hooks"
cp packaging/Info.plist "$APP/Contents/"
cp packaging/AppIcon.icns "$APP/Contents/Resources/"
mv "$OUT/CloudingBar" "$OUT/cloudingbar-hook" "$OUT/cloudingbar-tap" "$OUT/cloudingbar-key" "$APP/Contents/MacOS/"
cp hooks/cloudingbar-relay.sh hooks/cloudingbar-statusline.sh hooks/cloudingbar-wrapper.sh "$APP/Contents/Resources/hooks/"

echo "Signing…"
sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }
sign --identifier dev.cloudingbar.hook "$APP/Contents/MacOS/cloudingbar-hook"
sign --identifier dev.cloudingbar.tap "$APP/Contents/MacOS/cloudingbar-tap"
sign --identifier dev.cloudingbar.key "$APP/Contents/MacOS/cloudingbar-key"
sign --entitlements packaging/entitlements.plist "$APP"
codesign --verify --strict --deep --verbose=1 "$APP"

notarize() {
  if [ "${DRY:-}" = 1 ]; then echo "  (DRY: not sent to Apple)"; return; fi
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait
}

echo "Notarizing the app…"
ditto -c -k --keepParent "$APP" "$OUT/app.zip"
notarize "$OUT/app.zip"
rm "$OUT/app.zip"
[ "${DRY:-}" = 1 ] || xcrun stapler staple "$APP"

echo "Making the disk image…"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Clouding Bar" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "Notarizing the disk image…"
notarize "$DMG"
if [ "${DRY:-}" != 1 ]; then
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  spctl --assess --type execute --verbose=2 "$APP"
fi
shasum -a 256 "$DMG"
echo "Done: $DMG"
