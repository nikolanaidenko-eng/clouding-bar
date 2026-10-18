#!/bin/sh
# Signs $1 (an app bundle or a binary) with the steadiest identity there is:
# an "Apple Development" certificate from your keychain, then the
# self-signed one from `make signing-identity`, then ad-hoc. $2, if given,
# is the code identifier (for bare helper binaries).
# --timestamp=none: signing never talks to Apple's timestamp server.
set -e
target="$1"
ident=""
[ -n "$2" ] && ident="--identifier $2"
keychain="$HOME/.cloudingbar/signing.keychain-db"
dev=$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: /{print $2; exit}')
if [ -n "$dev" ]; then
  codesign --force --timestamp=none $ident --sign "$dev" "$target"
  echo "Signed $target with Apple Development ($dev)"
elif [ -f "$keychain" ]; then
  security unlock-keychain -p "" "$keychain"
  codesign --force --timestamp=none $ident --keychain "$keychain" --sign "ClaudeBar Local Signing" "$target"
  echo "Signed $target with ClaudeBar Local Signing"
else
  codesign --force $ident --sign - "$target" 2>/dev/null || true
  echo "Signed $target ad-hoc (run 'make signing-identity' to keep permissions across rebuilds)"
fi
