#!/bin/bash
# Relays a Claude Code hook payload (JSON on stdin) to the ClaudeBar app's
# unix socket. Exits 0 no matter what — a missing or stopped ClaudeBar
# should never break your Claude Code session.
SOCKET="$HOME/.claudebar/claudebar.sock"

if [ -S "$SOCKET" ]; then
  /usr/bin/nc -U -w 1 "$SOCKET" 2>/dev/null
else
  cat > /dev/null
fi

exit 0
