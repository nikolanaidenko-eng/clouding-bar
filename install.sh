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

echo "Installing hook relay to $CLAUDEBAR_DIR"
cp hooks/claudebar-relay.sh hooks/claudebar-statusline.sh "$CLAUDEBAR_DIR/"
chmod +x "$CLAUDEBAR_DIR/claudebar-relay.sh" "$CLAUDEBAR_DIR/claudebar-statusline.sh"

if [ ! -f "$CLAUDEBAR_DIR/config.json" ]; then
  echo "Writing starter config to $CLAUDEBAR_DIR/config.json"
  cat > "$CLAUDEBAR_DIR/config.json" <<'EOF'
{
  "showUsage": true
}
EOF
fi

echo "Registering Claude Code hooks in $SETTINGS"
python3 - "$SETTINGS" "$CLAUDEBAR_DIR/claudebar-relay.sh" "$CLAUDEBAR_DIR/claudebar-statusline.sh" "$CLAUDEBAR_DIR/statusline-original" <<'PYEOF'
import json, os, sys

settings_path, relay, statusline, original_path = sys.argv[1:5]
settings = {}
if os.path.exists(settings_path):
    with open(settings_path) as f:
        settings = json.load(f)

hooks = settings.setdefault("hooks", {})
relay_hook = {"type": "command", "command": relay}

for event in ["SessionStart", "SessionEnd", "Notification", "Stop", "UserPromptSubmit"]:
    entries = hooks.setdefault(event, [])
    already = any(
        h.get("command") == relay
        for entry in entries
        for h in entry.get("hooks", [])
    )
    if not already:
        entries.append({"hooks": [relay_hook]})

# Make sure an already-installed ClaudeBar status line also refreshes on a
# timer, so the bar fills in without waiting for the next message.
existing = settings.get("statusLine")
if isinstance(existing, dict) and existing.get("command") == statusline:
    existing.setdefault("refreshInterval", 30)

# Status line: feeds session limit + context data to ClaudeBar. An existing
# custom status line is kept and chained, so what you see doesn't change.
current = settings.get("statusLine") or {}
current_cmd = current.get("command") if isinstance(current, dict) else None
if current_cmd != statusline:
    if current_cmd:
        with open(original_path, "w") as f:
            f.write(current_cmd)
        print("  existing status line kept (chained through ClaudeBar)")
    new_status = dict(current) if isinstance(current, dict) else {}
    new_status.update({"type": "command", "command": statusline})
    new_status.setdefault("refreshInterval", 30)
    settings["statusLine"] = new_status

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
print("  hooks and status line registered")
PYEOF

echo
echo "Done! Launching ClaudeBar…"
open "$APP_DEST"
echo
echo "First-run checklist:"
echo "  • macOS will ask for Accessibility access (needed to press keys"
echo "    in your terminal) — approve it in System Settings."
echo "  • Start a 'claude' session in your terminal; the Touch Bar"
echo "    switches to Claude mode automatically."
