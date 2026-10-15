#!/bin/bash
# ClaudeBar installer:
#   1. copies the app to ~/Applications
#   2. copies the hook relay script to ~/.claudebar
#   3. registers the relay in ~/.claude/settings.json (merged, never clobbered)
#   4. writes a starter config if you don't have one
set -euo pipefail
cd "$(dirname "$0")"

APP_SRC="build/ClaudeBar.app"
APP_DEST="$HOME/Applications/ClaudeBar.app"
CLAUDEBAR_DIR="$HOME/.claudebar"
SETTINGS="$HOME/.claude/settings.json"

if [ ! -d "$APP_SRC" ]; then
  echo "No build found — run 'make' first." >&2
  exit 1
fi

echo "Installing app to $APP_DEST"
mkdir -p "$HOME/Applications" "$CLAUDEBAR_DIR" "$HOME/.claude"
pkill -x ClaudeBar 2>/dev/null && sleep 1 || true
rm -rf "$APP_DEST"
cp -R "$APP_SRC" "$APP_DEST"

echo "Installing hook scripts to $CLAUDEBAR_DIR"
cp hooks/claudebar-relay.sh hooks/claudebar-statusline.sh "$CLAUDEBAR_DIR/"
chmod +x "$CLAUDEBAR_DIR/claudebar-relay.sh" "$CLAUDEBAR_DIR/claudebar-statusline.sh"

# VS Code extension wrapper + tap. Running Claude sessions may be using
# them right now, so replace by rename instead of overwriting in place.
replace() {
  cp "$1" "$2.new" && chmod +x "$2.new" && mv -f "$2.new" "$2"
}
replace hooks/claudebar-wrapper.sh "$CLAUDEBAR_DIR/claudebar-wrapper.sh"
if [ -f build/claudebar-tap ]; then
  replace build/claudebar-tap "$CLAUDEBAR_DIR/claudebar-tap"
fi
# The hook command (sessions started earlier may still call the old relay,
# which stays installed for them).
replace build/claudebar-hook "$CLAUDEBAR_DIR/claudebar-hook"

if [ ! -f "$CLAUDEBAR_DIR/config.json" ]; then
  echo "Writing starter config to $CLAUDEBAR_DIR/config.json"
  cat > "$CLAUDEBAR_DIR/config.json" <<'EOF'
{
  "touchBar": "auto"
}
EOF
fi

echo "Registering Claude Code hooks in $SETTINGS"
python3 - "$SETTINGS" "$CLAUDEBAR_DIR" <<'PYEOF'
import json, os, sys, time

settings_path, claudebar_dir = sys.argv[1:3]
relay = os.path.join(claudebar_dir, "claudebar-relay.sh")
hook = os.path.join(claudebar_dir, "claudebar-hook")
statusline = os.path.join(claudebar_dir, "claudebar-statusline.sh")
original_path = os.path.join(claudebar_dir, "statusline-original")

settings = {}
before = None
if os.path.exists(settings_path):
    with open(settings_path) as f:
        before = f.read()
    settings = json.loads(before) if before.strip() else {}

hooks = settings.setdefault("hooks", {})

# Seconds Claude Code gives the hook before cancelling it. claudebar-hook
# gives up on its own well before that (docs/protocol.md).
timeouts = {"PermissionRequest": 960, "PreToolUse": 330}
events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "Notification",
          "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"]

for event in events:
    entries = hooks.setdefault(event, [])
    found = False
    for entry in entries:
        for h in entry.get("hooks", []):
            # Ours from an older install: point it at the new command.
            if h.get("command") in (relay, hook):
                h["command"] = hook
                if event in timeouts:
                    h["timeout"] = timeouts[event]
                found = True
    if not found:
        h = {"type": "command", "command": hook}
        if event in timeouts:
            h["timeout"] = timeouts[event]
        entries.append({"hooks": [h]})

# Status line: feeds session limit + context data. An existing custom
# status line is kept and chained, so what you see doesn't change.
current = settings.get("statusLine") or {}
current_cmd = current.get("command") if isinstance(current, dict) else None
if current_cmd != statusline:
    if current_cmd:
        with open(original_path, "w") as f:
            f.write(current_cmd)
        print("  existing status line kept (chained through ClaudeBar)")
    current = dict(current) if isinstance(current, dict) else {}
    current.update({"type": "command", "command": statusline})
# Refresh every 5 s, so the bar keeps up without waiting for a message.
current["refreshInterval"] = 5
settings["statusLine"] = current

after = json.dumps(settings, indent=2) + "\n"
if after == before:
    print("  hooks and status line already up to date")
    sys.exit(0)

if before is not None:
    backups = os.path.join(claudebar_dir, "backups")
    os.makedirs(backups, exist_ok=True)
    backup = os.path.join(backups, time.strftime("settings-%Y%m%d-%H%M%S.json"))
    with open(backup, "w") as f:
        f.write(before)
    print("  backup: " + backup)

tmp = settings_path + ".claudebar-new"
with open(tmp, "w") as f:
    f.write(after)
os.replace(tmp, settings_path)
print("  hooks and status line registered")
PYEOF

echo
echo "Done! Launching Clouding Bar…"
open "$APP_DEST"
echo
echo "First-run checklist:"
echo "  • macOS will ask for Accessibility access (needed to press keys"
echo "    in your terminal) — approve it in System Settings."
echo "  • Start a 'claude' session in your terminal; the Touch Bar"
echo "    switches to Claude mode automatically."
