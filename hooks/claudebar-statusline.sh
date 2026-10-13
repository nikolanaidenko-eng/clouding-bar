#!/bin/bash
# Claude Code status line command. Forwards the status JSON (session limit,
# context window) to ClaudeBar's unix socket, then prints the status line.
# If you had your own status line before installing ClaudeBar, its command
# is saved in ~/.claudebar/statusline-original and runs here unchanged.
SOCKET="$HOME/.claudebar/claudebar.sock"
ORIGINAL="$HOME/.claudebar/statusline-original"

input=$(cat)

if [ -S "$SOCKET" ]; then
  printf '%s' "$input" | /usr/bin/nc -U -w 1 "$SOCKET" >/dev/null 2>&1
fi

if [ -s "$ORIGINAL" ]; then
  printf '%s' "$input" | /bin/bash -c "$(cat "$ORIGINAL")"
else
  # Minimal default line: model and context usage.
  printf '%s' "$input" | /usr/bin/python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("Claude"); sys.exit(0)
line = (d.get("model") or {}).get("display_name") or "Claude"
pct = (d.get("context_window") or {}).get("used_percentage")
if pct is not None:
    line += " · context %d%%" % round(pct)
print(line)
' 2>/dev/null || echo "Claude"
fi

exit 0
