---
name: install-app
description: Install or update the Clouding Bar app on this Mac (the newest release from GitHub, signature and Apple notarization checked before it goes into Applications). Use when the user asks to install, get or update Clouding Bar.
---

Install the Clouding Bar Mac app. Run exactly this, nothing else (the path is the `scripts` folder next to this skill's `skills` folder, i.e. `../../scripts/install-app.sh` from this file):

```
sh "<plugin root>/scripts/install-app.sh"
```

`<plugin root>` is the folder of this plugin (`PLUGIN_ROOT`; the one that holds `.codex-plugin`).

The script needs the network (it downloads the release from GitHub) and write access to /Applications. Codex's sandbox has no network, so run it outside the sandbox: ask for that escalation (the user approves it). If the command fails with "no internet", a download error or a permission error, do not give up and do not report that as the final answer: ask to run it again outside the sandbox.

Then tell the user, in one or two short sentences and in their language, what it printed. If it installed the app, add that Clouding Bar opens with a question to connect (for Codex nothing more is needed: this plugin already brings its hooks), that Codex runs hooks only after they are trusted (start Codex and choose Trust all, or `/hooks`), and that macOS asks for Accessibility, the one permission it needs. If it failed, say why in plain words. Don't run anything else.
