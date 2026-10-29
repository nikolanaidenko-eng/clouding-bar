#!/bin/sh
# /clouding-bar:install — gets the Clouding Bar app from GitHub Releases:
# the newest Mac release, checked (signed with Clouding Bar's Developer ID,
# notarized by Apple) before it goes into Applications. Run it again to
# update; a build of your own (make install) is left alone.
# CLOUDING_BAR_DMG=<a local .dmg> installs that one instead (for testing).
set -eu
REPO=wvnikola/clouding-bar
TEAM=8RFNMA23CG
APP="Clouding Bar.app"
BUNDLE_ID=dev.cloudingbar.app

if [ "$(uname -s)" != Darwin ]; then
  echo "Clouding Bar is a Mac app: nothing to install here."
  exit 0
fi

tmp=$(mktemp -d)
stage=""
cleanup() {
  [ -n "$stage" ] && rm -rf "$stage"
  [ -d "$tmp/mnt" ] && hdiutil detach -quiet "$tmp/mnt" 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT

REQ="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\" and identifier \"$BUNDLE_ID\""
CURL="curl -fsSL --proto =https --proto-redir =https --connect-timeout 15 --max-time 600 --max-filesize 200000000"

if [ -n "${CLOUDING_BAR_DMG:-}" ]; then
  cp "$CLOUDING_BAR_DMG" "$tmp/app.dmg"
else
  # The newest final (not pre-release) release with a Mac disk image
  # (Clouding-Bar-<x.y.z>.dmg). The API lists newest first.
  $CURL -o "$tmp/releases.json" "https://api.github.com/repos/$REPO/releases?per_page=30" || true
  url=""
  i=0
  while [ $i -lt 30 ] && [ -z "$url" ]; do
    pre=$(plutil -extract "$i.prerelease" raw -o - "$tmp/releases.json" 2>/dev/null) || break
    draft=$(plutil -extract "$i.draft" raw -o - "$tmp/releases.json" 2>/dev/null || echo false)
    if [ "$pre" = false ] && [ "$draft" = false ]; then
      j=0
      while [ $j -lt 20 ]; do
        u=$(plutil -extract "$i.assets.$j.browser_download_url" raw -o - "$tmp/releases.json" 2>/dev/null) || break
        if printf '%s' "$u" | grep -Eq '^https://[^[:space:]]*/Clouding-Bar-[0-9]+\.[0-9]+\.[0-9]+\.dmg$'; then
          url=$u
          break
        fi
        j=$((j + 1))
      done
    fi
    i=$((i + 1))
  done
  if [ -z "${url:-}" ]; then
    echo "No Mac release found on github.com/$REPO (no internet, or the repository isn't public)."
    exit 1
  fi
  echo "Downloading $(basename "$url")…"
  $CURL -o "$tmp/app.dmg" "$url"
fi

# The disk image itself is signed in the release (packaging/release.sh): its
# identifier is not the app's, so here the Team ID alone.
if [ -z "${CLOUDING_BAR_DMG:-}" ] && ! codesign --verify -R="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\"" "$tmp/app.dmg" 2>/dev/null; then
  echo "This disk image isn't signed with Clouding Bar's Developer ID: not opened."
  exit 1
fi

mkdir "$tmp/mnt"
hdiutil attach -nobrowse -readonly -noautoopen -quiet -mountpoint "$tmp/mnt" "$tmp/app.dmg"
new="$tmp/mnt/$APP"
if [ ! -d "$new" ]; then
  echo "The disk image has no $APP in it: nothing installed."
  exit 1
fi
if ! codesign --verify --deep --strict -R="$REQ" "$new" 2>/dev/null; then
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

dir=$(dirname "$dest")
mkdir -p "$dir"
ditto "$new" "$tmp/$APP"
# The copy that will be installed is the one checked, not the mounted one.
if ! codesign --verify --deep --strict -R="$REQ" "$tmp/$APP" 2>/dev/null; then
  echo "The copy isn't signed with Clouding Bar's Developer ID: not installed."
  exit 1
fi
# Same volume as the target, so the swap is a rename and can be undone.
stage="$dir/.Clouding Bar.new.$$"
old="$dir/.Clouding Bar.old.$$"
ditto "$tmp/$APP" "$stage"

# Everything that can fail is done: only now close the app and swap.
was_open=0
pgrep -qx CloudingBar && was_open=1
osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
i=0
while pgrep -qx CloudingBar && [ $i -lt 25 ]; do sleep 0.2; i=$((i + 1)); done
if [ -d "$dest" ] && ! mv "$dest" "$old"; then
  echo "Could not move the old Clouding Bar aside: left as it is."
  [ $was_open = 1 ] && open "$dest"
  exit 1
fi
if ! mv "$stage" "$dest"; then
  if [ -d "$old" ]; then mv "$old" "$dest" && [ $was_open = 1 ] && open "$dest"; fi
  echo "Could not put Clouding Bar $version in place: the old one is back."
  exit 1
fi
stage=""
rm -rf "$old"
open "$dest"
echo "Clouding Bar $version is installed in $dir and open."
echo "First time: it asks to connect to Claude Code (its status line), then for Accessibility in System Settings."
