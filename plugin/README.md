# Clouding Bar plugin

The link between Claude and [Clouding Bar](https://github.com/nikolanaidenko-eng/clouding-bar),
a Mac menu bar app that shows Claude Code at a glance — on the Touch Bar, in a floating pill
or in the notch — and lets you answer permissions and questions from there.

## Install

- Claude Code: `/plugin install clouding-bar --marketplace nikolanaidenko-eng/clouding-bar`, then `/reload-plugins`
  and `/clouding-bar:install`. (Older Claude Code: `/plugin marketplace add nikolanaidenko-eng/clouding-bar`,
  then `/plugin install clouding-bar@clouding-bar`.)
- Claude Desktop: Customize → Plugins → Add → Add marketplace → `nikolanaidenko-eng/clouding-bar`, then
  install **clouding-bar** (it works in Cowork; the Chat tab ignores hooks).

## What it does

- **`/clouding-bar:install`** gets the app: the newest release from GitHub, checked (signed
  with Clouding Bar's Developer ID, notarized by Apple) before it goes into Applications. Run
  it again to update; a build of your own is left alone.
- **In Claude Code on a Mac**, its hooks hand each event to the app's hook program
  (`~/.cloudingbar/cloudingbar-hook`), which waits for your answer to a permission or a
  question and steps aside within two seconds when the app isn't running. A new session opens
  the app if it's closed. If you connected Clouding Bar the older way (its hook in
  `~/.claude/settings.json`), the plugin stays out of the way: no event twice.
- **In Cowork**, on every message and reply it writes one line of JSON — the task's context
  use, working or done — to `.clouding-bar/` in a folder connected to the task, where the app
  reads it. With Cowork in the cloud it asks Claude to write it (how often: Clouding Bar →
  Settings → Cowork). Nothing at all when Cowork is off there.
- Anywhere else (Windows, a Linux server, Claude Code on the web) it does nothing.

The 5-hour limit and the context reach the app through its status line, which a plugin can't
set: the app adds it to `~/.claude/settings.json` when you say Connect (merged, backed up).

Source: <https://github.com/nikolanaidenko-eng/clouding-bar>. License: PolyForm Shield 1.0.0.

No network, except `/clouding-bar:install` downloading the app from GitHub.
