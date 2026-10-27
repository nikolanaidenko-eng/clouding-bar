#!/bin/sh
# Clouding Bar's plugin for Codex: one script for every hook event ($1).
# The event goes to Clouding Bar's hook program (kept in ~/.cloudingbar by
# the app), marked --codex. No app: it exits quietly and Codex goes on.
event=$1

[ "$(uname -s)" = Darwin ] || exit 0

codex_home=${CODEX_HOME:-$HOME/.codex}

# Strict JSON, as Codex reads it (plutil alone lets a trailing comma through).
json_ok() {
  if [ -x /usr/bin/ruby ]; then
    /usr/bin/ruby -rjson -e 'JSON.parse(File.read(ARGV[0]))' "$1" >/dev/null 2>&1
  elif xcode-select -p >/dev/null 2>&1 && [ -x /usr/bin/python3 ]; then
    /usr/bin/python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1
  else
    plutil -convert xml1 -o /dev/null "$1" >/dev/null 2>&1
  fi
}

# Connected the older way too (Connect in the app: hooks.json): that one answers,
# but only if Codex really loads it (review, 27.10): the file must parse, and our
# hook must not be switched off for this event in config.toml (hooks.state).
hooks_file="$codex_home/hooks.json"
if [ -f "$hooks_file" ] && grep -Eq '(cloudingbar|claudebar)-hook(\\")? --codex' "$hooks_file" \
   && json_ok "$hooks_file"; then
  snake=$(printf '%s' "$event" | sed 's/\([a-z]\)\([A-Z]\)/\1_\2/g' | tr '[:upper:]' '[:lower:]')
  real_file="$(cd -P "$codex_home" 2>/dev/null && pwd)/hooks.json"
  off=
  if [ -f "$codex_home/config.toml" ]; then
    off=$(awk -v a="$hooks_file:$snake:" -v b="$real_file:$snake:" '
      /^[[:space:]]*\[/ { cur = (index($0, "[hooks.state.\"" a) > 0 || index($0, "[hooks.state.\"" b) > 0); next }
      cur && /^[[:space:]]*enabled[[:space:]]*=[[:space:]]*false/ { print "off"; exit }
    ' "$codex_home/config.toml")
  fi
  [ -n "$off" ] || exit 0
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
