#!/bin/bash
# Clouding Bar installer:
#   1. copies the app to ~/Applications
#   2. copies the hook relay script to ~/.cloudingbar
#   3. registers the relay in ~/.claude/settings.json (merged, never clobbered)
#   4. writes a starter config if you don't have one
set -euo pipefail
cd "$(dirname "$0")"

APP_SRC="build/CloudingBar.app"
APP_DEST="$HOME/Applications/Clouding Bar.app"
OLD_APP="$HOME/Applications/ClaudeBar.app" # before the rename
CLOUDINGBAR_DIR="$HOME/.cloudingbar"
SETTINGS="$HOME/.claude/settings.json"

if [ ! -d "$APP_SRC" ]; then
  echo "No build found — run 'make' first." >&2
  exit 1
fi

# Renamed from ClaudeBar: move ~/.claudebar over once and leave a link, so
# Claude sessions started earlier (their hooks, wrapper and tap still use
# the old paths) keep working.
OLD_DIR="$HOME/.claudebar"
if [ -d "$OLD_DIR" ] && [ ! -L "$OLD_DIR" ] && [ ! -e "$CLOUDINGBAR_DIR" ]; then
  echo "Moving $OLD_DIR to $CLOUDINGBAR_DIR"
  { pkill -x CloudingBar; pkill -x ClaudeBar; } 2>/dev/null && sleep 1 || true
  mv "$OLD_DIR" "$CLOUDINGBAR_DIR"
  ln -s "$CLOUDINGBAR_DIR" "$OLD_DIR"
fi

echo "Installing app to $APP_DEST"
mkdir -p "$HOME/Applications" "$CLOUDINGBAR_DIR" "$HOME/.claude"
{ pkill -x CloudingBar; pkill -x ClaudeBar; } 2>/dev/null && sleep 1 || true
rm -rf "$APP_DEST" "$OLD_APP"
cp -R "$APP_SRC" "$APP_DEST"

echo "Installing hook scripts to $CLOUDINGBAR_DIR"
cp hooks/cloudingbar-relay.sh hooks/cloudingbar-statusline.sh "$CLOUDINGBAR_DIR/"
chmod +x "$CLOUDINGBAR_DIR/cloudingbar-relay.sh" "$CLOUDINGBAR_DIR/cloudingbar-statusline.sh"

# VS Code extension wrapper + tap. Running Claude sessions may be using
# them right now, so replace by rename instead of overwriting in place.
replace() {
  cp "$1" "$2.new" && chmod +x "$2.new" && mv -f "$2.new" "$2"
}
replace hooks/cloudingbar-wrapper.sh "$CLOUDINGBAR_DIR/cloudingbar-wrapper.sh"
if [ -f build/cloudingbar-tap ]; then
  replace build/cloudingbar-tap "$CLOUDINGBAR_DIR/cloudingbar-tap"
fi
# The hook command (sessions started earlier may still call the old relay,
# which stays installed for them).
replace build/cloudingbar-hook "$CLOUDINGBAR_DIR/cloudingbar-hook"
# The old names, for sessions that started before the rename.
for n in hook tap relay.sh statusline.sh wrapper.sh; do
  ln -sfn "cloudingbar-$n" "$CLOUDINGBAR_DIR/claudebar-$n"
done
rm -f "$CLOUDINGBAR_DIR"/*.sh.new "$CLOUDINGBAR_DIR/claudebar-relay.sh.new" 2>/dev/null || true

# VS Code: point claudeCode.claudeProcessWrapper at the renamed wrapper.
VSCODE_SETTINGS="$HOME/Library/Application Support/Code/User/settings.json"
if [ -f "$VSCODE_SETTINGS" ] && grep -q "claudebar-wrapper.sh" "$VSCODE_SETTINGS"; then
  cp "$VSCODE_SETTINGS" "$CLOUDINGBAR_DIR/backups/vscode-settings-$(date +%Y%m%d-%H%M%S).json" 2>/dev/null \
    || { mkdir -p "$CLOUDINGBAR_DIR/backups"; cp "$VSCODE_SETTINGS" "$CLOUDINGBAR_DIR/backups/vscode-settings-$(date +%Y%m%d-%H%M%S).json"; }
  sed -i '' 's#/\.claudebar/claudebar-wrapper\.sh#/.cloudingbar/cloudingbar-wrapper.sh#' "$VSCODE_SETTINGS"
  echo "  VS Code now runs Claude through $CLOUDINGBAR_DIR/cloudingbar-wrapper.sh"
fi

if [ ! -f "$CLOUDINGBAR_DIR/config.json" ]; then
  echo "Writing starter config to $CLOUDINGBAR_DIR/config.json"
  cat > "$CLOUDINGBAR_DIR/config.json" <<'EOF'
{
  "touchBar": "auto"
}
EOF
fi

echo "Registering Claude Code hooks in $SETTINGS"
python3 - "$SETTINGS" "$CLOUDINGBAR_DIR" <<'PYEOF'
import json, os, sys, time

settings_path, cbdir = sys.argv[1:3]
old_dir = os.path.join(os.path.dirname(cbdir), ".claudebar")
ours_before = {os.path.join(old_dir, n) for n in ("claudebar-relay.sh", "claudebar-hook")}
relay = os.path.join(cbdir, "cloudingbar-relay.sh")
hook = os.path.join(cbdir, "cloudingbar-hook")
statusline = os.path.join(cbdir, "cloudingbar-statusline.sh")
original_path = os.path.join(cbdir, "statusline-original")

settings = {}
before = None
if os.path.exists(settings_path):
    with open(settings_path) as f:
        before = f.read()
    settings = json.loads(before) if before.strip() else {}

hooks = settings.setdefault("hooks", {})

# Seconds Claude Code gives the hook before cancelling it. cloudingbar-hook
# gives up on its own well before that (docs/protocol.md).
timeouts = {"PermissionRequest": 960, "PreToolUse": 330}
events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "Notification",
          "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest",
          "SubagentStart", "SubagentStop"]

for event in events:
    entries = hooks.setdefault(event, [])
    found = False
    for entry in entries:
        for h in entry.get("hooks", []):
            # Ours from an older install: point it at the new command.
            if h.get("command") in ({relay, hook} | ours_before):
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
if current_cmd == os.path.join(old_dir, "claudebar-statusline.sh"):
    current_cmd = statusline  # ours, from before the rename
    current["command"] = statusline
if current_cmd != statusline:
    if current_cmd:
        with open(original_path, "w") as f:
            f.write(current_cmd)
        print("  existing status line kept (chained through Clouding Bar)")
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
    backups = os.path.join(cbdir, "backups")
    os.makedirs(backups, exist_ok=True)
    backup = os.path.join(backups, time.strftime("settings-%Y%m%d-%H%M%S.json"))
    with open(backup, "w") as f:
        f.write(before)
    print("  backup: " + backup)

tmp = settings_path + ".cloudingbar-new"
with open(tmp, "w") as f:
    f.write(after)
os.replace(tmp, settings_path)
print("  hooks and status line registered")
PYEOF

echo
echo "Done! Launching Clouding Bar…"
# Right after the old one quit, Launch Services sometimes says no (-600): once more.
open "$APP_DEST" 2>/dev/null || { sleep 2; open "$APP_DEST"; }
echo
echo "First-run checklist:"
echo "  • macOS will ask for Accessibility access (needed to press keys"
echo "    in your terminal) — approve it in System Settings."
echo "  • Start a 'claude' session in your terminal; the Touch Bar"
echo "    switches to Claude mode automatically."
