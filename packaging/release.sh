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
#     /Applications/Xcode.app/Contents/Developer/usr/bin/notarytool store-credentials clouding-bar \
#         --apple-id <you> --team-id <team>
# With the Xcode license not accepted (after a macOS update) make refuses
# too: run this script directly, it finds Xcode's tools itself.
#
# DRY=1 skips Apple's notary (checks everything else); DEVELOPER_ID and
# NOTARY_PROFILE pick another certificate or credentials.
set -euo pipefail
cd "$(dirname "$0")/.."

# The Xcode license not accepted again after a macOS update (xcrun, make and
# swiftc in /usr/bin refuse): Xcode's own compiler, SDK and tools directly.
# (The Command Line Tools alone lack SwiftUI's macros in the macOS 27 SDK.)
if ! xcrun --find swiftc >/dev/null 2>&1 && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  export SDKROOT="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
  export PATH="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH"
  echo "Xcode license not accepted: building with Xcode's toolchain directly"
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" packaging/Info.plist)
OUT=build/release
APP="$OUT/Clouding Bar.app"
DMG="$OUT/Clouding-Bar-$VERSION.dmg"
PROFILE=${NOTARY_PROFILE:-clouding-bar}
# The notary and the stapler straight from Xcode: xcrun refuses to run them
# until the Xcode license is accepted again after a macOS update.
XCODE_DEV=/Applications/Xcode.app/Contents/Developer
NOTARYTOOL="$XCODE_DEV/usr/bin/notarytool"
STAPLER="$XCODE_DEV/usr/bin/stapler"
[ -x "$NOTARYTOOL" ] || NOTARYTOOL="xcrun notarytool"
[ -x "$STAPLER" ] || STAPLER="xcrun stapler"
LOCAL_KEYCHAIN="$HOME/.cloudingbar/signing.keychain-db"
# The Developer ID key, if it lives in its own keychain (made without Xcode:
# a key and request with openssl, the certificate from developer.apple.com,
# Apple's G2 CA beside it; on the search list, empty password).
# Outside ~/.cloudingbar (the app's data, which an uninstall removes);
# the old place still works.
RELEASE_KEYCHAIN="$HOME/.clouding-bar-release/release.keychain-db"
[ -f "$RELEASE_KEYCHAIN" ] || RELEASE_KEYCHAIN="$HOME/.cloudingbar/devid/release.keychain-db"
[ -f "$RELEASE_KEYCHAIN" ] && security unlock-keychain -p "" "$RELEASE_KEYCHAIN" 2>/dev/null || true
KEYCHAIN=()
IDENTITY=${DEVELOPER_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}
if [ -z "$IDENTITY" ]; then
  if [ "${DRY:-}" = 1 ]; then
    # A test build without the certificate: the self-signed identity from
    # `make signing-identity` if there is one (macOS then keeps a tester's
    # permissions from one build to the next), else ad-hoc.
    if [ -f "$LOCAL_KEYCHAIN" ]; then IDENTITY="ClaudeBar Local Signing"; KEYCHAIN=(--keychain "$LOCAL_KEYCHAIN")
    else IDENTITY="-"; fi
  else
    echo "No Developer ID Application certificate in the keychain." >&2
    echo "Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application." >&2
    exit 1
  fi
fi
# Apple's timestamp server, which the notary wants (not for ad-hoc).
TIMESTAMP=--timestamp
[ "${DRY:-}" = 1 ] && TIMESTAMP=--timestamp=none
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
# Apple's on-device model (macOS 26) linked weakly: macOS 12-25 start without it.
universal CloudingBar Sources/CloudingBar/*.swift Sources/CloudingBar/*/*.swift -Xlinker -weak_framework -Xlinker FoundationModels
universal cloudingbar-hook Sources/CloudingBarHook/*.swift Sources/CloudingBar/Core/Git.swift Sources/CloudingBar/Core/SessionTitle.swift
universal cloudingbar-tap Sources/CloudingBarTap/*.swift
universal cloudingbar-key Sources/CloudingBarKey/*.swift

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/hooks"
cp packaging/Info.plist "$APP/Contents/"
cp packaging/AppIcon.icns "$APP/Contents/Resources/"
mv "$OUT/CloudingBar" "$OUT/cloudingbar-hook" "$OUT/cloudingbar-tap" "$OUT/cloudingbar-key" "$APP/Contents/MacOS/"
cp hooks/cloudingbar-statusline.sh hooks/cloudingbar-wrapper.sh "$APP/Contents/Resources/hooks/"

echo "Signing…"
sign() { codesign --force --options runtime $TIMESTAMP ${KEYCHAIN[@]+"${KEYCHAIN[@]}"} --sign "$IDENTITY" "$@"; }
sign --identifier dev.cloudingbar.hook "$APP/Contents/MacOS/cloudingbar-hook"
sign --identifier dev.cloudingbar.tap "$APP/Contents/MacOS/cloudingbar-tap"
sign --identifier dev.cloudingbar.key "$APP/Contents/MacOS/cloudingbar-key"
sign --entitlements packaging/entitlements.plist "$APP"
codesign --verify --strict --deep --verbose=1 "$APP"

notarize() {
  if [ "${DRY:-}" = 1 ]; then echo "  (DRY: not sent to Apple)"; return; fi
  $NOTARYTOOL submit "$1" --keychain-profile "$PROFILE" --wait
}

echo "Notarizing the app…"
ditto -c -k --keepParent "$APP" "$OUT/app.zip"
notarize "$OUT/app.zip"
rm "$OUT/app.zip"
[ "${DRY:-}" = 1 ] || $STAPLER staple "$APP"

echo "Making the disk image…"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Clouding Bar" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force $TIMESTAMP ${KEYCHAIN[@]+"${KEYCHAIN[@]}"} --sign "$IDENTITY" "$DMG"

echo "Notarizing the disk image…"
notarize "$DMG"
if [ "${DRY:-}" != 1 ]; then
  $STAPLER staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  spctl --assess --type execute --verbose=2 "$APP"
fi
shasum -a 256 "$DMG"
echo "Done: $DMG"
