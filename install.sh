#!/bin/bash
# `make install`: a build from source put in place — the app in
# ~/Applications, then Claude Code connected through the app itself
# (CloudingBar --connect: its helper programs into ~/.cloudingbar, its hooks
# and status line merged into ~/.claude/settings.json, backed up first —
# what a download's Connect button does). Then it opens.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
built="$here/build/CloudingBar.app"
app="$HOME/Applications/Clouding Bar.app"
data="$HOME/.cloudingbar"

[ -d "$built" ] || { echo "Nothing built yet: run make first." >&2; exit 1; }

quit_running() {
  pkill -x CloudingBar 2>/dev/null || true
  pkill -x ClaudeBar 2>/dev/null || true
  sleep 1
}

# Once, after the rename from ClaudeBar: ~/.claudebar becomes ~/.cloudingbar,
# a link left behind for Claude sessions started before.
if [ -d "$HOME/.claudebar" ] && [ ! -L "$HOME/.claudebar" ] && [ ! -e "$data" ]; then
  echo "Moving ~/.claudebar to ~/.cloudingbar"
  quit_running
  mv "$HOME/.claudebar" "$data"
  ln -s "$data" "$HOME/.claudebar"
fi

echo "Installing the app to $app"
quit_running
mkdir -p "$HOME/Applications" "$data"
rm -rf "$app" "$HOME/Applications/ClaudeBar.app"
cp -R "$built" "$app"

echo "Connecting Claude Code"
"$app/Contents/MacOS/CloudingBar" --connect
# The names from before the rename, for sessions that still use them.
for name in hook tap statusline.sh wrapper.sh; do
  ln -sfn "cloudingbar-$name" "$data/claudebar-$name"
done

# VS Code, set up before the rename: its wrapper setting follows.
vscode="$HOME/Library/Application Support/Code/User/settings.json"
if [ -f "$vscode" ] && grep -q "claudebar-wrapper.sh" "$vscode"; then
  mkdir -p "$data/backups"
  cp "$vscode" "$data/backups/vscode-settings-$(date +%Y%m%d-%H%M%S).json"
  sed -i '' 's#/\.claudebar/claudebar-wrapper\.sh#/.cloudingbar/cloudingbar-wrapper.sh#' "$vscode"
  echo "  VS Code now runs Claude through $data/cloudingbar-wrapper.sh"
fi

echo "Opening Clouding Bar"
# Launch Services may say no right after the old copy quit (-600): once more.
open "$app" 2>/dev/null || { sleep 2; open "$app"; }
cat <<'NOTE'

The first time, macOS asks for Accessibility (System Settings → Privacy &
Security): Clouding Bar types your buttons and templates with it. Then start
Claude Code — in a terminal, VS Code or Claude Desktop — and the widget and
the Touch Bar pick it up.
NOTE
