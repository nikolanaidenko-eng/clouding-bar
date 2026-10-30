# Clouding Bar plugin

The link between Claude and [Clouding Bar](https://github.com/wvnikola/clouding-bar),
a Mac menu bar app that shows Claude Code at a glance — on the Touch Bar, in a floating pill
or in the notch — and lets you answer permissions and questions from there.

## Install

- Claude Code: `/plugin install clouding-bar --marketplace wvnikola/clouding-bar`, then `/reload-plugins`
  and `/clouding-bar:install`. (Older Claude Code: `/plugin marketplace add wvnikola/clouding-bar`,
  then `/plugin install clouding-bar@clouding-bar`.)
- Claude Desktop: Customize → Plugins → Add → Add marketplace → `wvnikola/clouding-bar`, then
  install **clouding-bar** (the Chat tab ignores hooks). The Mac app comes separately —
  the .dmg from <https://github.com/wvnikola/clouding-bar/releases/latest>, or `/clouding-bar:install`
  in Claude Code (not from Cowork, which runs in a Linux sandbox). Cowork itself doesn't need the
  plugin: to see Cowork tasks in Clouding Bar, open the app's Settings → General → Claude →
  claude.ai → **Sign In…** and sign in to claude.ai in the window that opens; it closes by itself.
  In Cowork the plugin's guide only helps get the app: it puts the newest .dmg in your Downloads
  (asking for access to it) and tells you what to click.
- Not sure what's next? Ask Claude "walk me through Clouding Bar" (the `guide` skill).

## What it does

- **`/clouding-bar:install`** gets the app: the newest release from GitHub, checked (signed
  with Clouding Bar's Developer ID, notarized by Apple) before it goes into Applications. Run
  it again to update; a build of your own is left alone.
- **In Claude Code on a Mac**, its hooks hand each event to the app's hook program
  (`~/.cloudingbar/cloudingbar-hook`), which waits for your answer to a permission or a
  question and steps aside within two seconds when the app isn't running. A new session opens
  the app if it's closed. If you connected Clouding Bar the older way (its hook in
  `~/.claude/settings.json`), the plugin stays out of the way: no event twice.
- **In Cowork** the plugin does nothing; the app reads Cowork tasks from claude.ai (see above).
- Anywhere else (Windows, a Linux server, Cowork, Claude Code on the web) it does nothing.

The 5-hour limit and the context reach the app through its status line, which a plugin can't
set: the app adds it to `~/.claude/settings.json` when you say Connect (merged, backed up).

Source: <https://github.com/wvnikola/clouding-bar>. License: MIT.

No network, except `/clouding-bar:install` downloading the app from GitHub. (The Mac app's own network use is in [docs/privacy.md](https://github.com/wvnikola/clouding-bar/blob/main/docs/privacy.md).)
