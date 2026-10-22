#!/bin/sh
# Clouding Bar's plugin: one script for every hook event ($1), wherever
# Claude runs.
#   On a Mac: the event goes to Clouding Bar's hook program, which the app
#   keeps in ~/.cloudingbar. It waits for your answer to a permission or a
#   question, and steps aside within two seconds when the app isn't there.
#   A new session also opens the app if it's closed — or, with no app yet,
#   says how to get it.
#   In Cowork (Linux): cowork.py notes the task's context for the app.
#   Anywhere else: nothing.
event=$1
here=$(dirname "$0")

case "$(uname -s)" in
Darwin)
  settings="$HOME/.claude/settings.json"
  # Connected the older way too, the hook in settings.json: that one answers.
  if [ -f "$settings" ] && grep -Eq '(cloudingbar|claudebar)-(hook|relay\.sh)"' "$settings"; then
    exit 0
  fi
  # The copy that comes with your account (installed in Claude Desktop)
  # steps aside for one installed in Claude Code itself: one answer per event.
  case "$CLAUDE_PLUGIN_ROOT" in
  */plugins/synced/*)
    if [ -f "$settings" ] && grep -Eq '"clouding-bar@clouding-bar"[[:space:]]*:[[:space:]]*true' "$settings"; then
      exit 0
    fi ;;
  esac

  hook="$HOME/.cloudingbar/cloudingbar-hook"
  if [ "$event" = SessionStart ] && ! pgrep -qx CloudingBar; then
    config="$HOME/.cloudingbar/config.json"
    if [ -f "$config" ] && grep -Eq '"openWithClaude"[[:space:]]*:[[:space:]]*false' "$config"; then
      :
    elif ! open -g -b dev.cloudingbar.app 2>/dev/null && [ ! -x "$hook" ]; then
      echo '{"systemMessage": "Clouding Bar: the app is not on this Mac yet. Run /clouding-bar:install to get it."}'
      exit 0
    fi
  fi
  [ -x "$hook" ] && exec "$hook"
  exit 0
  ;;
Linux)
  case "$event" in
  UserPromptSubmit|Stop) ;;
  *) exit 0 ;;
  esac
  command -v python3 >/dev/null 2>&1 || exit 0
  exec python3 "$here/cowork.py"
  ;;
*)
  exit 0
  ;;
esac
