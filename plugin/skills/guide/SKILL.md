---
name: guide
description: What Clouding Bar can do and how to set it up, in Cowork or in Claude Code. Use when the user asks about the Clouding Bar plugin — "I have the Clouding Bar plugin. Please walk me through what it can do.", how to install or set it up, or why Clouding Bar doesn't show a chat or a Cowork task.
---

# Walking someone through Clouding Bar

Answer in the user's language and keep it short: what it does in a few lines, then the setup
steps for where they are right now. Don't run commands or change files, except downloading the
installer in Cowork when the user wants it (below).

## What it is

Clouding Bar is a Mac menu bar app (macOS 12 or later). This plugin is only its link to Claude:
it reports what each chat is doing, and the app shows it — on the Touch Bar, in a floating pill
or in the notch — and lets you answer from there.

- Every chat with its own colour, its own Cloud and a short name: working, waiting for you, done.
- The 5-hour limit, the context window, the model, the subagents at work.
- Claude's permission requests and questions, answered from the bar or the pill without going
  back to the chat.
- A screenshot of an area of the screen, or a file dropped on the pill, goes straight into the
  chat; dictation too.
- A heads-up when another chat finishes; stats of how much you used.

## Where are you?

- **Cowork** — this chat runs in Cowork's Linux sandbox, with the task's folders under `mnt/`.
  Follow "In Cowork".
- **Claude Code on a Mac** — the terminal, VS Code or Claude Desktop's Code tab. Follow
  "In Claude Code".

## In Cowork

The plugin already does its part here. What's left happens on the Mac:

1. **Get the Mac app.** It can't be installed from Cowork — there's no macOS here, so
   `/clouding-bar:install` won't work in this chat. Offer to put the installer in a folder
   connected to this task, so all the user does is open it on the Mac:
   ```
   url=$(curl -fsSL https://api.github.com/repos/nikolanaidenko-eng/clouding-bar/releases/latest \
     | python3 -c "import json,sys; print([a['browser_download_url'] for a in json.load(sys.stdin)['assets'] if a['name'].startswith('Clouding-Bar-') and a['name'].endswith('.dmg')][0])")
   curl -fL "$url" -o "<the connected folder>/${url##*/}"
   ```
   Then tell them: open that `Clouding-Bar-….dmg` in Finder and drag Clouding Bar into
   Applications. If the download is blocked here, give the link instead — it's the official one
   and always has the newest release: <https://github.com/nikolanaidenko-eng/clouding-bar/releases/latest>
   (the `Clouding-Bar-….dmg` under Assets). Or, in Claude Code on the Mac: `/clouding-bar:install`.
   Don't try to install it yourself by controlling the screen: opening the .dmg is quicker.
2. **Open Clouding Bar.** It asks to connect to Claude Code (say **Connect**) and for
   Accessibility, the one permission it needs.
3. **Connect a folder to this task**, if none is. The plugin writes the task's status — context
   use, working or done — into `.clouding-bar/` in that folder, and the app reads it there.
   macOS asks once to let Clouding Bar read the folder.
4. Clouding Bar switches its Cowork status on by itself. How often it reports: Clouding Bar →
   Settings → Cowork (off, thresholds, every reply).
5. A question Cowork asks in Claude Desktop shows up on the Touch Bar and in the pill, and can be
   answered there (Claude Desktop's window has to be on the current desktop).

If a hook asks you to write a line to `.clouding-bar/cowork-….json` in a connected folder, that's
this plugin with Cowork in the cloud (its folders are copies): write exactly that line and
nothing else.

## In Claude Code

1. `/reload-plugins`, so the chat that's open reports too, then `/clouding-bar:install` — it gets
   the newest release from GitHub, checks it (Clouding Bar's Developer ID, notarized by Apple)
   and puts it in Applications.
2. When the app opens: **Connect** (it adds its status line — the 5-hour limit and the context —
   to `~/.claude/settings.json`, and in VS Code a small wrapper), then allow Accessibility.
3. Chats that were already open show up after `/reload-plugins` in them, or in a new chat.

## Good to know

- No account, no analytics, no server of its own. The plugin itself uses no network, except
  `/clouding-bar:install` downloading the app from GitHub.
- The app checks GitHub for updates once a day (menu bar icon → Check for Updates).
- Everything else: <https://github.com/nikolanaidenko-eng/clouding-bar>.
