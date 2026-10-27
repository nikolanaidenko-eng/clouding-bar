#!/bin/sh
# Clouding Bar's plugin for Codex: one script for every hook event ($1).
# The event goes to Clouding Bar's hook program (kept in ~/.cloudingbar by
# the app), marked --codex. No app: it exits quietly and Codex goes on.
event=$1

[ "$(uname -s)" = Darwin ] || exit 0

codex_home=${CODEX_HOME:-$HOME/.codex}
# Connected the older way too (Connect in the app: hooks.json): that one answers.
hooks_file="$codex_home/hooks.json"
if [ -f "$hooks_file" ] && grep -Eq '(cloudingbar|claudebar)-hook(\\")? --codex' "$hooks_file"; then
  exit 0
fi

hook="$HOME/.cloudingbar/cloudingbar-hook"
if [ "$event" = SessionStart ] && ! pgrep -qx CloudingBar; then
  config="$HOME/.cloudingbar/config.json"
  if [ -f "$config" ] && grep -Eq '"openWithClaude"[[:space:]]*:[[:space:]]*false' "$config"; then
    :
  elif ! open -g -b dev.cloudingbar.app 2>/dev/null && [ ! -x "$hook" ]; then
    echo '{"systemMessage": "Clouding Bar: the app is not on this Mac yet. Ask Codex to install it (the install-app skill of the Clouding Bar plugin)."}'
    exit 0
  fi
fi
[ -x "$hook" ] && exec "$hook" --codex
exit 0
