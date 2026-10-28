---
description: Install or update the Clouding Bar app on this Mac (the newest release from GitHub, checked before it's installed)
allowed-tools: Bash(sh "${CLAUDE_PLUGIN_ROOT}/scripts/install-app.sh")
---

Install the Clouding Bar Mac app.

First: if this chat isn't running on the Mac itself — Cowork (in the cloud or in its Linux sandbox), or any Linux — don't run the install script. In Cowork, follow the plugin's `guide` skill, In Cowork → Getting the app: download the installer into the Mac's Downloads with `device_bash` (never in your own sandbox: it can't reach GitHub), then tell the user what to click, step by step. Don't lead with a download link or Claude Code.

On a Mac, run exactly this with the Bash tool, nothing else:

```
sh "${CLAUDE_PLUGIN_ROOT}/scripts/install-app.sh"
```

Then tell the user, in one or two short sentences and in their language, what it printed. If it installed the app, add that Clouding Bar opens with a question to connect to Claude Code (say Connect), that macOS then asks for Accessibility — the one permission it needs — and that other Claude chats that were already open show up after `/reload-plugins` in them (or in a new chat). If it failed, say why in plain words. Don't run anything else.
