#!/bin/bash
# For the VS Code extension's "claudeCode.claudeProcessWrapper" setting.
# The extension runs: cloudingbar-wrapper.sh <claude binary> <args...>
#
# The extension's panel never runs the status line, so Clouding Bar gets no
# session limit from it. Claude Code does report the limit on stdout
# (rate_limit_event); cloudingbar-tap copies stdout through unchanged and
# forwards those lines to Clouding Bar.
#
# exec keeps Claude itself as the process the extension started, so its
# signals and exit code are untouched. Without the tap it's a plain exec.
# A terminal on stdout means interactive Claude (useTerminal): leave it be,
# it runs the status line itself and needs a real TTY.
#
# With --input the tap sits on Claude's stdin too: the extension's lines go
# through as they come, and between them messages from Clouding Bar's widget
# (typed, dictated, a screenshot) reach Claude without its window.
TAP="$HOME/.cloudingbar/cloudingbar-tap"
if [ -x "$TAP" ] && [ ! -t 1 ]; then
  exec > >(exec "$TAP")
  if [ ! -t 0 ]; then
    exec < <(exec "$TAP" --input)
  fi
fi
exec "$@"
