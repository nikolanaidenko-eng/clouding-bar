---
description: Install or update the Clouding Bar app on this Mac (the newest release from GitHub, checked before it's installed)
allowed-tools: Bash(sh "${CLAUDE_PLUGIN_ROOT}/scripts/install-app.sh")
---

Install the Clouding Bar Mac app. Run exactly this with the Bash tool, nothing else:

```
sh "${CLAUDE_PLUGIN_ROOT}/scripts/install-app.sh"
```

Then tell the user, in one or two short sentences and in their language, what it printed. If it installed the app, add that Clouding Bar opens with a question to connect to Claude Code (say Connect), that macOS then asks for Accessibility — the one permission it needs — and that other Claude chats that were already open show up after `/reload-plugins` in them (or in a new chat). If it failed, say why in plain words. Don't run anything else.
