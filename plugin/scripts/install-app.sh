#!/bin/sh
# /clouding-bar:install — gets the Clouding Bar app from GitHub Releases:
# the newest Mac release, checked (signed with Clouding Bar's Developer ID,
# notarized by Apple) before it goes into Applications. Run it again to
# update; a build of your own (make install) is left alone.
# CLOUDING_BAR_DMG=<a local .dmg> installs that one instead (for testing).
set -eu
REPO=nikolanaidenko-eng/clouding-bar
TEAM=8RFNMA23CG
APP="Clouding Bar.app"
BUNDLE_ID=dev.cloudingbar.app

if [ "$(uname -s)" != Darwin ]; then
  echo "Clouding Bar is a Mac app: nothing to install here."
  exit 0
fi

tmp=$(mktemp -d)
cleanup() {
  [ -d "$tmp/mnt" ] && hdiutil detach -quiet "$tmp/mnt" 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT

if [ -n "${CLOUDING_BAR_DMG:-}" ]; then
  cp "$CLOUDING_BAR_DMG" "$tmp/app.dmg"
else
  # The newest release with a Mac disk image (Clouding-Bar-<x.y.z>.dmg).
  url=$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=30" \
    | grep -Eo '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*/Clouding-Bar-[0-9]+\.[0-9]+\.[0-9]+\.dmg"' \
    | head -1 | sed -E 's/.*"(https[^"]+)"$/\1/') || true
  if [ -z "${url:-}" ]; then
    echo "No Mac release found on github.com/$REPO (no internet, or the repository isn't public)."
    exit 1
  fi
  echo "Downloading $(basename "$url")…"
  curl -fsSL -o "$tmp/app.dmg" "$url"
fi

mkdir "$tmp/mnt"
hdiutil attach -nobrowse -readonly -noautoopen -quiet -mountpoint "$tmp/mnt" "$tmp/app.dmg"
new="$tmp/mnt/$APP"
if [ ! -d "$new" ]; then
  echo "The disk image has no $APP in it: nothing installed."
  exit 1
fi
if ! codesign --verify --deep --strict -R="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\"" "$new" 2>/dev/null; then
  echo "This copy isn't signed with Clouding Bar's Developer ID: not installed."
  exit 1
fi
if ! spctl --assess --type execute "$new" 2>/dev/null; then
  echo "This copy isn't notarized by Apple: not installed."
  exit 1
fi
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$new/Contents/Info.plist")

# In place of the one you have, else in Applications.
dest=""
for d in "/Applications/$APP" "$HOME/Applications/$APP"; do
  if [ -d "$d" ]; then dest=$d; break; fi
done
if [ -n "$dest" ]; then
  team=$(codesign -dv "$dest" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  if [ "$team" != "$TEAM" ]; then
    echo "$dest is a build of your own, not a release: left as it is (Clouding Bar $version not installed)."
    exit 0
  fi
  have=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$dest/Contents/Info.plist" 2>/dev/null || echo)
  if [ "$have" = "$version" ]; then
    open "$dest"
    echo "Clouding Bar $version is already installed ($dest), and open."
    exit 0
  fi
else
  dest="/Applications/$APP"
  [ -w /Applications ] || dest="$HOME/Applications/$APP"
fi

mkdir -p "$(dirname "$dest")"
osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
i=0
while pgrep -qx CloudingBar && [ $i -lt 25 ]; do sleep 0.2; i=$((i + 1)); done
ditto "$new" "$tmp/$APP"
[ -d "$dest" ] && mv "$dest" "$tmp/old.app"
mv "$tmp/$APP" "$dest"
open "$dest"
echo "Clouding Bar $version is installed in $(dirname "$dest") and open."
echo "First time: it asks to connect to Claude Code (its status line), then for Accessibility in System Settings."
