---
name: guide
description: What Clouding Bar can do and how to set it up, in Cowork or in Claude Code. Use when the user asks about the Clouding Bar plugin — "I have the Clouding Bar plugin. Please walk me through what it can do.", how to install or set it up, or why Clouding Bar doesn't show a chat or a Cowork task.
---

# Walking someone through Clouding Bar

Answer in the user's language and keep it short: what it does in a few lines, then the setup
steps for where they are right now. Don't run commands or change files, except putting the installer
in a connected folder in Cowork (below).

## What it is

Clouding Bar is a Mac menu bar app (macOS 12 or later). This plugin is only its link to Claude:
it reports what each Claude Code chat is doing, and the app shows it — on the Touch Bar, in a floating pill
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

The Mac app does the work here; this plugin does nothing in Cowork. What's left happens on the Mac.

Where the folders are: in Cowork on the Mac, under `mnt/` here. In Cowork in the cloud
(`CLAUDE_CODE_ENTRYPOINT` is `remote_cowork`), not here at all — they stay on the user's
computer, under `~/mnt/` for the tool that runs commands there (`device_bash`); do anything with
them through that tool.

**Getting the app.** If Clouding Bar is already on this Mac (from Claude Code or a .dmg), skip to
"See Cowork tasks". Otherwise a folder is needed, for the installer only: check whether a folder
from the user's Mac is connected to this task. If none is, say: connect one (any folder they work
in; **+ → Add folder** in Claude Desktop), because the installer will go into it. Then:

1. **Put the installer in it** — don't wait to be asked; it can't be installed from Cowork
   itself (there's no macOS here, so `/clouding-bar:install` won't work in this chat):
   ```
   url=$(curl -fsSL https://api.github.com/repos/nikolanaidenko-eng/clouding-bar/releases/latest \
     | python3 -c "import json,sys; print([a['browser_download_url'] for a in json.load(sys.stdin)['assets'] if a['name'].startswith('Clouding-Bar-') and a['name'].endswith('.dmg')][0])")
   curl -fL "$url" -o "<the connected folder>/${url##*/}"
   ```
   (In the cloud, run it with `device_bash`, into the folder under `~/mnt/` there.)
   Then tell them: open that `Clouding-Bar-….dmg` in Finder and drag Clouding Bar into
   Applications. Only if the download fails, give the link — the official one, always the newest
   release: <https://github.com/nikolanaidenko-eng/clouding-bar/releases/latest> (the
   `Clouding-Bar-….dmg` under Assets). Don't try to install it yourself by controlling the
   screen: opening the .dmg is quicker.
2. **Open Clouding Bar.** It asks to connect to Claude Code (say **Connect**) and for
   Accessibility, the one permission it needs.

**See Cowork tasks.** In the app: Settings → General → Connections → claude.ai → **Sign In…**.
Sign in to claude.ai in the window that opens; it closes by itself. Cowork tasks (and claude.ai
and Claude Desktop chats) then show up in the chats list, with the account-wide 5-hour limit.
No plugin, no folder, nothing for you to write.

A question Cowork asks in Claude Desktop shows up on the Touch Bar and in the pill, and can be
answered there (Claude Desktop's window has to be on the current desktop).

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
