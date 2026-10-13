#!/bin/bash
# For the VS Code extension's "claudeCode.claudeProcessWrapper" setting.
# The extension runs: claudebar-wrapper.sh <claude binary> <args...>
#
# The extension's panel never runs the status line, so ClaudeBar gets no
# session limit from it. Claude Code does report the limit on stdout
# (rate_limit_event); claudebar-tap copies stdout through unchanged and
# forwards those lines to ClaudeBar.
#
# exec keeps Claude itself as the process the extension started, so its
# signals and exit code are untouched. Without the tap it's a plain exec.
# A terminal on stdout means interactive Claude (useTerminal): leave it be,
# it runs the status line itself and needs a real TTY.
TAP="$HOME/.claudebar/claudebar-tap"
if [ -x "$TAP" ] && [ ! -t 1 ]; then
  exec > >(exec "$TAP")
fi
exec "$@"
